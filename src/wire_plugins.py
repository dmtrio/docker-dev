#!/usr/bin/env python3
"""Agent-config wiring for up.sh — both sides of one docker exec.

up.sh runs this file twice per `up`, so the payload schema lives in exactly
one place and both halves are unit-testable:

  host side:      python3 src/wire_plugins.py --build-payload
                  reads env vars (see build_payload) and prints the JSON
                  payload; booleans use the same strict string comparison the
                  old bash used ([ "$X" = "true" ]), so a manifest value like
                  `gateway: yes` stays OFF instead of leaking into the JSON.
  container side: python3 /usr/local/lib/dev-agent/wire_plugins.py
                  reads that payload on stdin and wires MCP servers into every
                  installed agent's config files — the work that used to live
                  in up.sh as jq/sed programs inside triple-quoted
                  `docker exec bash -c` strings.

Payload:

    {
      "wire":         {"cursor": bool, "gemini": bool, "pi": bool, "codex": bool},
      "capabilities": {"obsidian": bool},
      "plugin_mcp_entries": [{"<name>": <local or remote spec>}, ...],
      "identities":   [{"agent": "cursor-agent", "key_env": "IDENTITY_KEY_0"}, ...]
    }

- plugin_mcp_entries carries one object per enabled plugin (host-side
  manifest.py extracts them from plugins/<name>.yml). A spec is LOCAL
  ({command, args} — stdio, wired into every agent) or REMOTE ({url, headers}
  — http, wired into Claude's .mcp.json only in Phase 1). Cross-plugin
  duplicate server names hard-fail here as well as host-side: both merges are
  last-wins, so a collision must never silently replace an entry.
- capabilities carries only obsidian now (agent-scoped, migrates to a plugin in
  Phase 2). gateway/proxyman/browser were capability flags before Phase 1 and
  are plugin data now — they arrive via plugin_mcp_entries like any plugin.
- Identity keys never ride in the payload: each identities[] element names an
  environment variable (set on the docker exec) that holds the key, so the
  payload itself is secret-free. Only cursor-agent/gemini/pi keys are shipped
  at all — claude's rides in its shim env, codex's is pending (warning only).
- Version skew between the two halves cannot happen in the up.sh flow: the
  payload is built from the repo checkout and the consumer is baked from the
  same checkout by the `docker compose up --build` that just ran.

Stdlib only — dev-Mac CLT and the image both guarantee python3 but nothing
else, and the TOML we emit (bare validated keys, JSON-escaped strings/arrays,
which are a TOML subset) doesn't need a writer library. Every config write is
atomic (tmp + rename) with the final mode set before the rename, except
~/.claude.json which is written through in place (it predates us and may be a
symlink into someone's dotfiles — the old `cat >` behavior).
"""

import json
import os
import sys
from pathlib import Path

OBSIDIAN_URL = "https://mcp-obsidian.dmetr.io/mcp"

# Names of servers up.sh still GENERATES into Claude's .mcp.json (as opposed to
# taking from a plugin file). A plugin adopting one would silently
# last-wins-shadow the identity-bearing entry, so it is reserved. Only
# obsidian-annotated remains generated; gateway/proxyman/browser became plugin
# data in Plugins v2 Phase 1 (their server names — coding/proxyman/browser — are
# now defined by plugins/*.yml and validated by the generic collision check).
# obsidian-annotated retires from this set in Phase 2.
RESERVED_SERVER_NAMES = frozenset({"obsidian-annotated"})

# The codex managed block. Detection matches on the PREFIX (like the old sed
# ranges did), so a stale block written by an older up.sh with different
# trailing text is still stripped.
CODEX_OPEN_PREFIX = "# >>> dev-agent plugin MCP"
CODEX_CLOSE_PREFIX = "# <<< dev-agent plugin MCP"
CODEX_OPEN_MARKER = "# >>> dev-agent plugin MCP (managed by up.sh; edits inside are overwritten) >>>"
CODEX_CLOSE_MARKER = "# <<< dev-agent plugin MCP <<<"


class WireError(Exception):
    """Fatal wiring error; main() prints it as 'Error: …' and exits 1."""


def _write_atomic(path, text, mode=None, errors=None):
    """Write text to path via tmp + rename; chmod the tmp BEFORE the rename so
    the final path never exists with looser permissions. mode=None keeps the
    umask default (e.g. the repo's .mcp.json, which holds ${VAR} refs, not
    secrets)."""
    tmp = path.parent / (path.name + ".tmp")
    # newline="": no newline translation — what we assembled is what lands.
    with open(tmp, "w", encoding="utf-8", errors=errors, newline="") as f:
        f.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, path)


def _dump_json(obj):
    # jq-style output: 2-space indent, raw UTF-8, trailing newline.
    return json.dumps(obj, indent=2, ensure_ascii=False) + "\n"


def _load_json_file(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except ValueError as e:
        raise WireError(f"{path} is not valid JSON: {e}")
    return data


def merge_plugin_entries(entries):
    """Merge the per-plugin mcp objects into one dict (insertion order, like
    jq `add`), hard-failing on a server name defined by more than one plugin
    or squatting on a reserved generated name."""
    merged = {}
    dups = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise WireError("plugin_mcp_entries must be JSON objects")
        dups.update(n for n in entry if n in merged)
        merged.update(entry)
    if dups:
        raise WireError(
            "multiple enabled plugins define the same MCP server name(s): "
            + ", ".join(sorted(dups))
        )
    reserved = sorted(n for n in merged if n in RESERVED_SERVER_NAMES)
    if reserved:
        raise WireError(
            "plugin MCP server name(s) reserved for generated servers: "
            + ", ".join(reserved)
        )
    return merged


def _claude_server(spec):
    """Render a plugin's mcp spec for Claude's .mcp.json. Local (stdio) servers
    pass through verbatim ({command, args}); remote servers gain the explicit
    `type: http` Claude expects, ahead of the file's {url, headers}."""
    if "command" in spec:
        return spec
    return {"type": "http", **spec}


def _local_plugins(plugins):
    """The stdio (local) subset. Remote plugins are wired into Claude's
    .mcp.json only (Phase 1): cursor/gemini can't expand ${VAR} refs in remote
    headers, and their env-scoped service tokens were never wired there before
    — so restricting the other agents to local plugins keeps every config
    byte-identical to the pre-plugin capabilities era."""
    return {n: s for n, s in plugins.items() if "command" in s}


def _load_servers(path):
    """Load an agent config as (data, servers-dict), or (None, None) when the
    file is missing or ZERO-BYTE — the caller then takes the create path. The
    zero-byte case is load-bearing: the old `jq` pipeline exited 0 with empty
    output on empty input, which blanked the config; this helper is the single
    home of the fix for both the identity and plugin merge paths."""
    if not (path.is_file() and path.stat().st_size > 0):
        return None, None
    data = _load_json_file(path)  # hand-broken JSON must abort loudly
    if not isinstance(data, dict):
        raise WireError(f"{path}: expected a JSON object at the top level")
    servers = data.get("mcpServers")
    if servers is None:
        servers = {}
        data["mcpServers"] = servers
    if not isinstance(servers, dict):
        raise WireError(f"{path}: .mcpServers is not an object")
    return data, servers


def generate_claude_mcp(workspace, caps, plugins):
    """Regenerate <workspace>/main/.mcp.json from the manifest capabilities +
    plugins — unless the repo ships its own (no marker file), or there is no
    repo yet. Claude expands the ${VAR} header refs at launch via the shims,
    so this file carries no literal secrets."""
    main_dir = workspace / "main"
    mcp_path = main_dir / ".mcp.json"
    marker = workspace / ".mcp.generated"

    # Gate on the repo (.git), not just the dir: the entrypoint always creates
    # an empty main/ so editors can attach, but on a failed private-repo clone
    # it stays empty and .git-less. Writing .mcp.json there would make the dir
    # non-empty and break the clone retry on the next up.sh run — so skip.
    if not (main_dir / ".git").is_dir():
        print(f"  (skipping .mcp.json — {main_dir} has no repo yet; fix the clone and rerun up.sh)")
        return
    if mcp_path.is_file() and not marker.is_file():
        print("  (repo ships its own .mcp.json — leaving it alone; manifest capabilities/plugins are NOT merged into it)")
        return

    servers = {}
    if caps.get("obsidian"):
        servers["obsidian-annotated"] = {
            "type": "http",
            "url": OBSIDIAN_URL,
            "headers": {"Authorization": "Bearer ${OBSIDIAN_ANNOTATED_KEY}"},
        }

    # A plugin adopting a generated name would silently shadow the
    # identity-bearing entry (the merge below is last-wins) — hard-fail.
    clash = sorted(n for n in plugins if n in servers)
    if clash:
        raise WireError(
            "plugin MCP server name(s) collide with generated servers: " + ", ".join(clash)
        )
    for name, spec in plugins.items():
        servers[name] = _claude_server(spec)

    _write_atomic(mcp_path, _dump_json({"mcpServers": servers}))
    marker.touch()
    print("  ✓ .mcp.json generated (" + ", ".join(sorted(servers)) + ")")


def preapprove_claude(home, workspace):
    """Approval state lives in ~/.claude.json; since .mcp.json came from the
    manifest, its servers are approved by construction. Merge, don't clobber.

    .mcp.json may be repo-shipped rather than generated (that's a supported
    opt-out), so a shape we don't understand is a skip-with-warning, not an
    abort — the other agents' wiring must not die on a file we promised to
    leave alone. ~/.claude.json itself failing to parse IS an abort: merging
    into a corrupt state file can only destroy it."""
    mcp_path = workspace / "main" / ".mcp.json"
    if not mcp_path.is_file():
        return
    try:
        mcp = _load_json_file(mcp_path)
    except WireError as e:
        print(f"  ⚠ skipping claude pre-approval — {e}")
        return
    if not isinstance(mcp, dict) or not isinstance(mcp.get("mcpServers"), dict):
        print(f"  ⚠ skipping claude pre-approval — {mcp_path} has no mcpServers object")
        return
    servers = sorted(mcp["mcpServers"])

    cj = home / ".claude.json"
    state = _load_json_file(cj) if cj.is_file() else {}
    if not isinstance(state, dict):
        raise WireError(f"{cj} is not a JSON object")
    projects = state.setdefault("projects", {})
    if not isinstance(projects, dict):
        raise WireError(f"{cj}: .projects is not an object")
    project = projects.setdefault(str(workspace / "main"), {})
    if not isinstance(project, dict):
        raise WireError(f"{cj}: .projects[…] is not an object")
    project["enabledMcpjsonServers"] = servers
    project["hasTrustDialogAccepted"] = True

    # Write THROUGH rather than tmp+rename: the file predates this module and
    # may be a symlink (dotfiles) — a rename would swap in a detached regular
    # file. Same semantics as the old `cat /tmp/cj.json > ~/.claude.json`,
    # inode, mode, and link target all preserved.
    with open(cj, "w", encoding="utf-8") as f:
        f.write(_dump_json(state))
    print("  ✓ MCP servers pre-approved for claude (" + ", ".join(servers) + ")")


def _merge_identity_entry(path, entry):
    """Set mcpServers["obsidian-annotated"] in an existing config (preserving
    plugin and hand-added servers) or create the file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    data, servers = _load_servers(path)
    if data is None:
        data = {"mcpServers": {"obsidian-annotated": entry}}
    else:
        servers["obsidian-annotated"] = entry
    _write_atomic(path, _dump_json(data), mode=0o600)


def write_identity(agent, key, home):
    """Wire one obsidian identity into its agent's config. Cursor and Gemini
    cannot reliably expand env vars in headers for remote servers, so their
    configs carry the literal key: home files, mode 600, never inside the
    repo, regenerated from secrets.env on every up (rotation flows)."""
    auth = {"Authorization": "Bearer " + key}
    if agent == "cursor-agent":
        _merge_identity_entry(
            home / ".cursor" / "mcp.json", {"url": OBSIDIAN_URL, "headers": auth}
        )
        print("  ✓ cursor-agent MCP config (literal key: env interpolation broken for remote headers)")
    elif agent == "gemini":
        _merge_identity_entry(
            home / ".gemini" / "settings.json", {"httpUrl": OBSIDIAN_URL, "headers": auth}
        )
        print("  ✓ gemini MCP config (literal key: header env expansion is an open FR)")
    elif agent == "pi":
        # pi's file is wholly regenerated (no hand-managed entries expected);
        # plugin entries are re-merged right after by wire_plugin_servers.
        path = home / ".pi" / "agent" / "mcp.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        _write_atomic(
            path,
            _dump_json({"mcpServers": {"obsidian-annotated": {
                "type": "http", "url": OBSIDIAN_URL, "headers": auth}}}),
            mode=0o600,
        )
        print("  ✓ pi MCP config written (NOTE: inert until pi-mcp-adapter extension is installed — pi has no built-in MCP)")
    elif agent == "codex":
        print("  ⚠ codex obsidian identity not yet wired into ~/.codex/config.toml "
              "(now safely container-local after the credential split — pending "
              "verification of codex's remote-MCP config format). Key is available "
              "to codex processes as OBSIDIAN_ANNOTATED_KEY via its shim.")
    # claude: its identity rides in the generated .mcp.json as a ${VAR} ref.


def wire_plugin_servers_json(path, plugins):
    """Sync the plugin stdio servers into a JSON agent config (cursor, gemini,
    pi). The set of plugin-managed names is tracked in a sidecar
    (<file>.dev-agent-plugins) so stale entries from a plugin removed from the
    manifest are deleted without touching identity or hand-added servers."""
    sidecar = path.parent / (path.name + ".dev-agent-plugins")
    old = []
    if sidecar.is_file() and sidecar.stat().st_size > 0:
        old = _load_json_file(sidecar)
        if not isinstance(old, list):
            raise WireError(f"{sidecar}: expected a JSON array of names")

    data, servers = _load_servers(path)
    if data is None:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {"mcpServers": dict(plugins)}
    else:
        merged = {k: v for k, v in servers.items() if k not in old}
        merged.update(plugins)
        data["mcpServers"] = merged

    _write_atomic(path, _dump_json(data), mode=0o600)
    _write_atomic(sidecar, json.dumps(sorted(plugins), separators=(",", ":")) + "\n", mode=0o600)
    print(f"  ✓ plugin MCP servers synced into {path}")


def _codex_block_body(plugins):
    """Render the [mcp_servers.*] tables. Server names were validated to
    [A-Za-z0-9_-] host-side (safe as bare TOML keys); command/args are emitted
    as JSON, whose string and array escapes are a TOML subset."""
    tables = []
    for name, spec in plugins.items():
        command = json.dumps(spec.get("command"), ensure_ascii=False)
        args = json.dumps(spec.get("args") or [], ensure_ascii=False, separators=(",", ":"))
        tables.append(f"[mcp_servers.{name}]\ncommand = {command}\nargs = {args}")
    return "\n\n".join(tables) + "\n"


def wire_codex_toml(path, plugins):
    """Sync the plugin servers into codex's config.toml as a managed marker
    block, stripped and re-appended each run; hand edits outside the markers
    survive. An opening marker without its closer hard-fails rather than
    letting the strip eat the rest of the file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        path.touch()
    # newline="" disables universal-newline translation on read, and the
    # split is on \n ONLY (like the old sed) — str.splitlines() would also
    # split on \r/\f/U+2028…, silently rewriting a CRLF or exotic-char
    # config. A trailing newline yields one empty tail element — drop it so
    # the rejoin below is the single place that decides newline termination.
    with open(path, encoding="utf-8", errors="surrogateescape", newline="") as f:
        raw = f.read()
    lines = raw.split("\n")
    if lines and lines[-1] == "":
        lines.pop()

    kept = []
    in_block = False
    for line in lines:
        if not in_block and line.startswith(CODEX_OPEN_PREFIX):
            in_block = True
            continue
        if in_block:
            if line.startswith(CODEX_CLOSE_PREFIX):
                in_block = False
            continue
        kept.append(line)
    if in_block:
        # Stricter than the old grep guard on purpose: a block still open at
        # EOF is caught even when an EARLIER block closed properly (stray
        # second opener, or a closer that sits above its opener) — the old
        # sed silently deleted from the stray opener to EOF in those cases.
        raise WireError(
            f"{path} has an opening dev-agent plugin marker but no closing one "
            "— repair the markers (the strip would delete everything below them)"
        )
    stripped = "\n".join(kept) + "\n" if kept else ""

    if plugins:
        content = (
            stripped
            + CODEX_OPEN_MARKER + "\n"
            + _codex_block_body(plugins)
            + CODEX_CLOSE_MARKER + "\n"
        )
    else:
        content = stripped
    _write_atomic(path, content, mode=0o600, errors="surrogateescape")
    print(f"  ✓ plugin MCP servers synced into {path} (managed block)")


def run(payload, home, workspace, env):
    if not isinstance(payload, dict):
        raise WireError("payload must be a JSON object")
    plugins = merge_plugin_entries(payload.get("plugin_mcp_entries") or [])
    caps = payload.get("capabilities") or {}
    wire = payload.get("wire") or {}

    generate_claude_mcp(workspace, caps, plugins)
    preapprove_claude(home, workspace)

    for ident in payload.get("identities") or []:
        key = env.get(ident.get("key_env") or "", "")
        write_identity(ident.get("agent") or "", key, home)

    # Runs for every installed agent even with no plugins enabled, so entries
    # from a plugin removed from the manifest are cleaned up, not orphaned
    # (Claude gets this for free from wholesale .mcp.json regeneration). Only
    # LOCAL plugins go here: remote ones live in Claude's .mcp.json alone until
    # Phase 2 gives cursor/gemini per-agent remote rendering.
    local = _local_plugins(plugins)
    if wire.get("cursor"):
        wire_plugin_servers_json(home / ".cursor" / "mcp.json", local)
    if wire.get("gemini"):
        wire_plugin_servers_json(home / ".gemini" / "settings.json", local)
    if wire.get("pi"):
        wire_plugin_servers_json(home / ".pi" / "agent" / "mcp.json", local)
        print("    (pi: inert until the pi-mcp-adapter extension is installed)")
    if wire.get("codex"):
        wire_codex_toml(home / ".codex" / "config.toml", local)


def build_payload(env):
    """Host side: assemble the payload from env vars set by up.sh.

    Booleans arrive as the raw yq scalars (WIRE_CURSOR/…, CAP_OBSIDIAN) and
    only the literal string "true" turns a flag on — the exact semantics of
    the old `[ "$X" = "true" ]` checks, so a truthy-looking `yes`/`1` stays off
    instead of flipping on or corrupting the JSON. PLUGIN_MCP_ENTRIES is the
    newline-separated one-line-JSON-per-plugin accumulation from manifest.py;
    IDENTITY_AGENTS is space-separated "agent:KEY_ENV" pairs (KEY_ENV empty for
    codex, whose key is deliberately never shipped).
    """
    def flag(name):
        return env.get(name) == "true"

    entries = []
    for line in (env.get("PLUGIN_MCP_ENTRIES") or "").splitlines():
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError as e:
            raise WireError(f"plugin mcp extraction produced invalid JSON ({e}): {line}")
        if not isinstance(entry, dict):
            raise WireError(f"plugin mcp extraction line is not a JSON object: {line}")
        entries.append(entry)

    identities = []
    for pair in (env.get("IDENTITY_AGENTS") or "").split():
        agent, _, key_env = pair.partition(":")
        identities.append({"agent": agent, "key_env": key_env})

    return {
        "wire": {name: flag("WIRE_" + name.upper())
                 for name in ("cursor", "gemini", "pi", "codex")},
        # Only obsidian is still generated; gateway/proxyman/browser are plugins
        # now and ride in plugin_mcp_entries (Plugins v2 Phase 1).
        "capabilities": {"obsidian": flag("CAP_OBSIDIAN")},
        "plugin_mcp_entries": entries,
        "identities": identities,
    }


def _home():
    """The wiring targets the exec user's REAL home (passwd), like the old
    hardcoded /home/coder paths — not $HOME, which a future `ENV HOME=…` in
    the image would leak into `docker exec -u coder`."""
    try:
        import pwd
        return Path(pwd.getpwuid(os.getuid()).pw_dir)
    except (ImportError, KeyError):
        return Path(os.environ.get("HOME", "/home/coder"))


def main(argv):
    if "--build-payload" in argv:
        try:
            print(json.dumps(build_payload(os.environ)))
        except WireError as e:
            print(f"Error: {e}", file=sys.stderr)
            return 1
        return 0

    try:
        payload = json.load(sys.stdin)
    except ValueError as e:
        print(f"Error: invalid JSON payload on stdin: {e}")
        return 1
    try:
        run(payload, _home(), Path("/workspace"), os.environ)
    except WireError as e:
        print(f"Error: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
