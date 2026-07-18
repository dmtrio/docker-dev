#!/usr/bin/env python3
"""In-container agent-config wiring, invoked by up.sh after the container is up.

Reads ONE JSON payload on stdin and wires MCP servers into every installed
agent's config files — the work that used to live in up.sh as jq/sed programs
inside triple-quoted `docker exec bash -c` strings:

    {
      "wire":         {"cursor": bool, "gemini": bool, "pi": bool, "codex": bool},
      "capabilities": {"gateway": bool, "proxyman": bool, "browser": bool,
                       "obsidian": bool},
      "plugin_mcp_entries": [{"<name>": {"command": "...", "args": [...]}}, ...],
      "identities":   [{"agent": "cursor-agent", "key_env": "IDENTITY_KEY_0"}, ...]
    }

- plugin_mcp_entries carries one object per enabled plugin (host-side yq
  extracts them from plugins/<name>.yml). Cross-plugin duplicate server names
  hard-fail here as well as host-side: both merges are last-wins, so a
  collision must never silently replace an entry.
- Identity keys never ride in the payload: each identities[] element names an
  environment variable (set on the docker exec) that holds the key, so the
  payload itself is secret-free.

Stdlib only — the image guarantees python3 but nothing else, and the TOML we
emit (bare validated keys, JSON-escaped strings/arrays, which are a TOML
subset) doesn't need a writer library. Baked into the image at
/usr/local/lib/dev-agent/wire_plugins.py. Every config write is atomic
(tmp + rename) with the final mode set before the rename.
"""

import json
import os
import sys
from pathlib import Path

OBSIDIAN_URL = "https://mcp-obsidian.dmetr.io/mcp"

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
    with open(tmp, "w", encoding="utf-8", errors=errors) as f:
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
    jq `add`), hard-failing on a server name defined by more than one plugin."""
    merged = {}
    seen = set()
    dups = set()
    for entry in entries:
        if not isinstance(entry, dict):
            raise WireError("plugin_mcp_entries must be JSON objects")
        for name in entry:
            if name in seen:
                dups.add(name)
            seen.add(name)
        merged.update(entry)
    if dups:
        raise WireError(
            "multiple enabled plugins define the same MCP server name(s): "
            + ", ".join(sorted(dups))
        )
    return merged


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
    if caps.get("gateway"):
        servers["coding"] = {
            "type": "http",
            "url": "http://host.docker.internal:8811/mcp",
            "headers": {"Authorization": "Bearer ${MCP_GATEWAY_TOKEN}"},
        }
    if caps.get("proxyman"):
        servers["proxyman"] = {
            "type": "http",
            "url": "http://host.docker.internal:8813/mcp",
            "headers": {"X-API-Key": "${PROXYMAN_BRIDGE_KEY}"},
        }
    if caps.get("browser"):
        servers["browser"] = {
            "type": "http",
            "url": "http://host.docker.internal:8814/mcp",
            "headers": {"X-API-Key": "${RESEARCH_BROWSER_KEY}"},
        }
    if caps.get("obsidian"):
        servers["obsidian-annotated"] = {
            "type": "http",
            "url": OBSIDIAN_URL,
            "headers": {"Authorization": "Bearer ${OBSIDIAN_ANNOTATED_KEY}"},
        }

    # A plugin adopting a generated name would silently shadow a pre-approved
    # or identity-bearing entry (the merge below is last-wins) — hard-fail.
    clash = sorted(n for n in plugins if n in servers)
    if clash:
        raise WireError(
            "plugin MCP server name(s) collide with generated servers: " + ", ".join(clash)
        )
    servers.update(plugins)

    _write_atomic(mcp_path, _dump_json({"mcpServers": servers}))
    marker.touch()
    print("  ✓ .mcp.json generated (" + ", ".join(sorted(servers)) + ")")


def preapprove_claude(home, workspace):
    """Approval state lives in ~/.claude.json; since .mcp.json came from the
    manifest, its servers are approved by construction. Merge, don't clobber."""
    mcp_path = workspace / "main" / ".mcp.json"
    if not mcp_path.is_file():
        return
    mcp = _load_json_file(mcp_path)
    if not isinstance(mcp, dict) or not isinstance(mcp.get("mcpServers"), dict):
        raise WireError(f"{mcp_path} has no mcpServers object — cannot pre-approve")
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

    # Preserve the file's existing mode (it may predate us); default otherwise.
    mode = (cj.stat().st_mode & 0o777) if cj.is_file() else None
    _write_atomic(cj, _dump_json(state), mode=mode)
    print("  ✓ MCP servers pre-approved for claude (" + ", ".join(servers) + ")")


def _merge_identity_entry(path, entry):
    """Set mcpServers["obsidian-annotated"] in an existing config (preserving
    plugin and hand-added servers) or create the file. A zero-byte file takes
    the create path — the old `jq` pipeline would have blanked the config on
    empty input, which is exactly the bug class this module removes."""
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.is_file() and path.stat().st_size > 0:
        data = _load_json_file(path)
        if not isinstance(data, dict):
            raise WireError(f"{path}: expected a JSON object at the top level")
        if data.get("mcpServers") is None:
            data["mcpServers"] = {}
        if not isinstance(data["mcpServers"], dict):
            raise WireError(f"{path}: .mcpServers is not an object")
        data["mcpServers"]["obsidian-annotated"] = entry
    else:
        data = {"mcpServers": {"obsidian-annotated": entry}}
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

    if path.is_file() and path.stat().st_size > 0:
        data = _load_json_file(path)  # hand-broken JSON must abort loudly
        if not isinstance(data, dict):
            raise WireError(f"{path}: expected a JSON object at the top level")
        servers = data.get("mcpServers")
        if servers is None:
            servers = {}
        if not isinstance(servers, dict):
            raise WireError(f"{path}: .mcpServers is not an object")
        merged = {k: v for k, v in servers.items() if k not in old}
        merged.update(plugins)
        data["mcpServers"] = merged
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        data = {"mcpServers": dict(plugins)}

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
    raw = path.read_text(encoding="utf-8", errors="surrogateescape")
    lines = raw.splitlines()

    has_open = any(l.startswith(CODEX_OPEN_PREFIX) for l in lines)
    has_close = any(l.startswith(CODEX_CLOSE_PREFIX) for l in lines)
    if has_open and not has_close:
        raise WireError(
            f"{path} has an opening dev-agent plugin marker but no closing one "
            "— repair the markers (the strip would delete everything below them)"
        )

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
    # (Claude gets this for free from wholesale .mcp.json regeneration).
    if wire.get("cursor"):
        wire_plugin_servers_json(home / ".cursor" / "mcp.json", plugins)
    if wire.get("gemini"):
        wire_plugin_servers_json(home / ".gemini" / "settings.json", plugins)
    if wire.get("pi"):
        wire_plugin_servers_json(home / ".pi" / "agent" / "mcp.json", plugins)
        print("    (pi: inert until the pi-mcp-adapter extension is installed)")
    if wire.get("codex"):
        wire_codex_toml(home / ".codex" / "config.toml", plugins)


def main():
    try:
        payload = json.load(sys.stdin)
    except ValueError as e:
        print(f"Error: invalid JSON payload on stdin: {e}")
        return 1
    try:
        run(payload, Path(os.environ.get("HOME", "/home/coder")), Path("/workspace"), os.environ)
    except WireError as e:
        print(f"Error: {e}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
