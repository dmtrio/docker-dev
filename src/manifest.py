#!/usr/bin/env python3
"""Host-side manifest reading + validation for up.sh (Phase 2 of the Python
extraction; wire_plugins.py was Phase 1).

up.sh feeds this file yq-converted JSON on stdin and evals the derived shell
assignments it prints:

    input (stdin):  line 1: the manifest as JSON (yq -o=json -I=0)
                    then one line per plugins/*.yml: "<name>\t<json>" — or
                    "<name>\t!" when yq could not parse that file (an error
                    only if the manifest actually lists the plugin; an
                    unlisted broken file must not block unrelated containers)
    input (env):    SECRET_KEY_VARS  — space-separated names of the non-empty
                                       OBSIDIAN_KEY_* / OBSIDIAN_WATCH_KEY_*
                                       vars currently defined (names only —
                                       secret VALUES never reach this process
                                       beyond NTFY_URL/NTFY_TOPIC below)
                    GIT_NAME_DEFAULT / GIT_EMAIL_DEFAULT — host git config
                                       fallbacks for manifests without git:
                    NTFY_URL / NTFY_TOPIC — from secrets.env, only consumed
                                       when the manifest asks for ntfy
                    SECRETS_FILE     — path, used verbatim in error messages
    output (stdout): one VAR=value line per derived variable, every value
                    shell-quoted (shlex.quote); up.sh does DERIVED=$(…) and
                    eval "$DERIVED". Errors go to stderr as "Error: …" with
                    exit 1 — the command substitution assignment then aborts
                    up.sh under set -e.

Behavioral fidelity notes (each is pinned by tests/test_manifest.py):
- yq/jq `//` treats false AND null as empty: `plugins: false` means "no
  plugins", `repo: false` reads as "", `tools: false` gets the default set.
- The old `tools | contains(["claude"])` had jq's SUBSTRING semantics for
  strings inside arrays (tools: [claude-code] enabled claude too). Ported
  as-is; tightening it is a deliberate future change, not a port surprise.
- null entries inside word-split lists (plugins, identity refs) vanish, the
  way the old `join(" ")` + word splitting dropped them — so a trailing
  flow-style comma (`plugins: [serena,]`) keeps working. Comma-joined lists
  (egress, egress_cidrs) keep their empty slots byte-for-byte.
- agent_for_ref suffix matching preserves the old case-statement ORDER:
  _cursor_agent wins before _claude/_codex/_pi/_gemini can match.
- Error ordering matches the old top-to-bottom flow: forge → plugins list →
  ssh/remote → mosh ports → identity refs (aggregated) → per-plugin egress +
  mcp entries (fail-fast) → ntfy. Messages are byte-identical to the bash.
- Deliberate departures from the old bash, all loud-instead-of-silent: a
  section written as the wrong YAML type (capabilities:/identities:/… as a
  list) is a named error where yq used to emit a cryptic 'cannot index'
  abort — or, worse, where a sequence-root plugin file validated as empty;
  and a non-scalar leaf (memory: [2g]) is a named error instead of leaked
  YAML/repr garbage.
- Known cosmetic deviation: numeric scalars ride through yq's JSON encoder,
  so `memory: 2.50` derives as "2.5" (the old `yq -r` printed the original
  spelling). Quote the value in YAML if the exact spelling matters.
"""

import json
import os
import re
import shlex
import sys

# Both modules live in src/ and run host-side here (wire_plugins.py is ALSO
# baked into the image, where it never imports this file) — the reserved-name
# set has exactly one home. Host ports are DATA now (each remote plugin's
# host_port:), not a table in code, so nothing is imported for them.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from wire_plugins import RESERVED_SERVER_NAMES

# \Z, not $: Python's $ also matches just before a trailing newline, which
# would wave "evil.com\n" through into dnsmasq config (the old bash never saw
# trailing newlines — word splitting ate them).
NAME_RE = re.compile(r"^[A-Za-z0-9_-]+\Z")
REF_RE = re.compile(r"^[A-Za-z0-9_]+\Z")
DOMAIN_RE = re.compile(
    r"^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]\Z"
)
IPV4_RE = re.compile(r"^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\Z")
MOSH_PORTS_RE = re.compile(r"^[0-9]{1,5}:[0-9]{1,5}\Z")

DEFAULT_TOOLS = ["claude", "codex", "pi", "gemini", "cursor", "aider"]

# Suffix → agent, in the OLD case-statement order (first match wins).
AGENT_SUFFIXES = (
    ("_cursor_agent", "cursor-agent"),
    ("_claude", "claude"),
    ("_codex", "codex"),
    ("_pi", "pi"),
    ("_gemini", "gemini"),
)

OBSIDIAN_HOST = "mcp-obsidian.dmetr.io"

# Marker for a plugins/*.yml that yq could not parse (see module docstring).
UNREADABLE = object()


class ManifestError(Exception):
    """Fatal validation error; main() prints 'Error: …' to stderr, exit 1."""


def _falsy(v):
    # jq/yq `//` alternative operator fires on null and false ONLY.
    return v is None or v is False


def _scalar(v, field, default=""):
    """Render like `yq -r '.x // ""'`: falsy → default, bool → true/false.
    A map/list leaf is a named error — the old yq spat multi-line garbage
    into the variable; refusing loudly is the whole point of this module."""
    if _falsy(v):
        return default
    if v is True:
        return "true"
    if isinstance(v, (dict, list)):
        raise ManifestError(f"manifest {field} must be a single value, not a map/list")
    return str(v)


def _raw_flag(v, field):
    """Render like `yq '.x // false'` (no -r): the raw scalar as yq prints
    it. Downstream only ever compares against the literal string 'true'."""
    if _falsy(v):
        return "false"
    if v is True:
        return "true"
    if isinstance(v, (dict, list)):
        raise ManifestError(f"manifest {field} must be a single value, not a map/list")
    return str(v)


def _section(manifest, key):
    """A top-level map section: absent/null → {}; any other non-map type is a
    named error (the old yq aborted with a cryptic 'cannot index' here — and
    silently-empty would be worse: a list-typo'd identities: must not bring
    the container up unauthenticated)."""
    v = manifest.get(key)
    if v is None:
        return {}
    if not isinstance(v, dict):
        raise ManifestError(f"manifest {key}: must be a map (got a {_yaml_type(v)})")
    return v


def _word_list(v, field):
    """A list the old bash consumed via join(" ") + word splitting: falsy →
    [], null entries vanish (they joined as empty words), scalars render like
    yq -r. Non-list values are named errors."""
    if _falsy(v):
        return []
    if not isinstance(v, list):
        raise ManifestError(f"manifest {field} must be a list")
    rendered = (_scalar(x, f"{field} entry") for x in v)
    return [r for r in rendered if r != ""]


def _comma_list(v, field):
    """A list the old bash consumed via join(",") with NO word splitting:
    empty slots from null entries survive byte-for-byte (they always have —
    downstream tolerates them, and inventing a cleanup here would change the
    emitted EGRESS string)."""
    if _falsy(v):
        return []
    if not isinstance(v, list):
        raise ManifestError(f"manifest {field} must be a list")
    return [_scalar(x, f"{field} entry") for x in v]


def _yaml_type(v):
    return {list: "list", str: "string", int: "number", float: "number",
            bool: "boolean"}.get(type(v), type(v).__name__)


def agent_for_ref(ref):
    for suffix, agent in AGENT_SUFFIXES:
        if ref.endswith(suffix):
            return agent
    return ""


def _tool_installed(tools, name):
    # jq contains(): a string element "contains" the needle as a SUBSTRING.
    return any(isinstance(t, str) and name in t for t in tools)


def _parse_secret(val, plugin, slot):
    """A plugin secret slot value: either a bare scope string ('env'/'agent')
    or a map {scope: ..., hint: ...}. Returns (scope, hint). The hint is shown
    verbatim in up.sh's 'not in secrets.env' warning, so it must be a single
    line with no tab (PLUGIN_ENV_SECRETS is tab/newline-delimited)."""
    if isinstance(val, str):
        scope, hint = val, ""
    elif isinstance(val, dict):
        scope = val.get("scope")
        hint = val.get("hint", "")
        if not isinstance(hint, str):
            raise ManifestError(f"plugin '{plugin}' secret '{slot}': hint must be a string")
    else:
        raise ManifestError(
            f"plugin '{plugin}' secret '{slot}': must be a scope ('env'/'agent') or a map with a scope: key")
    if scope not in ("env", "agent"):
        got = "no scope:" if scope is None else f"'{scope}'"
        raise ManifestError(
            f"plugin '{plugin}' secret '{slot}': scope must be 'env' or 'agent' (got {got})")
    if "\t" in hint or "\n" in hint:
        raise ManifestError(f"plugin '{plugin}' secret '{slot}': hint must be a single line (no tab/newline)")
    return scope, hint


class Derived(dict):
    """Ordered VAR → value string map with shell-quoted rendering."""

    def render(self):
        return "".join(f"{k}={shlex.quote(v)}\n" for k, v in self.items())


def derive(manifest, plugin_files, env):
    """The whole old 'Read manifest' section of up.sh as one function.
    manifest: parsed manifest JSON; plugin_files: {name: parsed plugin JSON,
    or UNREADABLE for a file yq couldn't parse} for every file shipped under
    plugins/; env: os.environ-like mapping."""
    if not isinstance(manifest, dict):
        raise ManifestError("manifest must be a YAML mapping")
    out = Derived()
    secrets_file = env.get("SECRETS_FILE", "secrets.env")

    # ── Scalars (old Y() reads + defaults) ──────────────────────────────
    out["REPO_URL"] = _scalar(manifest.get("repo"), "repo")
    forge = _scalar(manifest.get("forge"), "forge") or "github"
    if forge not in ("github", "gitea"):
        raise ManifestError("forge must be github or gitea")
    out["FORGE"] = forge
    git = _section(manifest, "git")
    out["GIT_USER_NAME"] = _scalar(git.get("name"), "git.name") or env.get("GIT_NAME_DEFAULT", "")
    out["GIT_USER_EMAIL"] = _scalar(git.get("email"), "git.email") or env.get("GIT_EMAIL_DEFAULT", "")
    out["MEM_LIMIT"] = _scalar(manifest.get("memory"), "memory") or "2g"

    # ── Tools ───────────────────────────────────────────────────────────
    tools = manifest.get("tools")
    if _falsy(tools):
        tools = DEFAULT_TOOLS
    if not isinstance(tools, list):
        raise ManifestError("manifest tools: must be a list")
    for var, name in (("INSTALL_CLAUDE", "claude"), ("INSTALL_CODEX", "codex"),
                      ("INSTALL_PI", "pi"), ("INSTALL_GEMINI", "gemini"),
                      ("INSTALL_CURSOR", "cursor"), ("INSTALL_AIDER", "aider")):
        out[var] = "true" if _tool_installed(tools, name) else "false"

    # ── Capabilities: egress firewall keys stay; gateway/proxyman/browser are
    #    deprecated sugar for the equivalent plugins (PLN - Plugins v2). ──────
    caps = _section(manifest, "capabilities")
    egress_items = _comma_list(caps.get("egress"), "capabilities.egress")
    cidr_items = _comma_list(caps.get("egress_cidrs"), "capabilities.egress_cidrs")
    sugar_plugins = []
    for cap in ("gateway", "proxyman", "browser"):
        if _raw_flag(caps.get(cap), f"capabilities.{cap}") == "true":
            sugar_plugins.append(cap)
            print(f"  ⚠ capabilities.{cap}: true is deprecated — use plugins: [{cap}] "
                  "instead (the capabilities: flag is sugar and will be removed)",
                  file=sys.stderr)

    # ── Plugins list (aggregated errors, old order) ─────────────────────
    plugins_val = manifest.get("plugins")
    if not _falsy(plugins_val) and not isinstance(plugins_val, list):
        raise ManifestError("manifest plugins: must be a list, e.g. plugins: [serena]")
    plugins = _word_list(plugins_val, "plugins")
    # capabilities: sugar appends the equivalent plugin names (dedup, explicit
    # list first) so gateway/proxyman/browser flow through the one pipeline.
    for cap in sugar_plugins:
        if cap not in plugins:
            plugins.append(cap)
    plugin_errors = []
    for p in plugins:
        if not NAME_RE.match(p):
            plugin_errors.append(
                f"  plugin '{p}': illegal characters (allowed: letters, digits, underscore, dash)")
            continue
        if p not in plugin_files:
            plugin_errors.append(f"  plugin '{p}': no plugin file at plugins/{p}.yml")
        elif plugin_files[p] is UNREADABLE:
            plugin_errors.append(f"  plugin '{p}': plugins/{p}.yml is not valid YAML (yq could not parse it)")
    if plugin_errors:
        raise ManifestError(
            "manifest plugins failed validation:\n" + "\n".join(plugin_errors))
    out["PLUGINS"] = " ".join(plugins)

    # ── ssh / remote (RFC 04) ───────────────────────────────────────────
    ssh = _section(manifest, "ssh")
    ssh_port = _scalar(ssh.get("port"), "ssh.port")
    out["SSH_PORT"] = ssh_port
    out["SSH_BIND"] = _scalar(ssh.get("bind"), "ssh.bind") or "127.0.0.1"

    remote = _section(manifest, "remote")
    remote_tmux = _raw_flag(remote.get("tmux"), "remote.tmux")
    remote_mosh = _raw_flag(remote.get("mosh"), "remote.mosh")
    remote_notify = _scalar(remote.get("notify"), "remote.notify")
    if (remote_tmux == "true" or remote_mosh == "true" or remote_notify) and not ssh_port:
        raise ManifestError(
            "manifest has remote: but no ssh: section — remote access rides the SSH login path (add ssh.port)")
    if remote_notify not in ("", "ntfy"):
        raise ManifestError(f"remote.notify must be 'ntfy' (got '{remote_notify}')")
    if remote_notify and remote_tmux != "true":
        raise ManifestError(
            "remote.notify requires remote.tmux: true (the idle monitor runs inside the tmux session)")
    out["REMOTE_TMUX"] = remote_tmux
    out["REMOTE_MOSH"] = remote_mosh
    out["REMOTE_NOTIFY"] = remote_notify

    mosh_ports = ""
    mosh_ports_dash = ""
    if remote_mosh == "true":
        mosh_ports = _scalar(remote.get("mosh_ports"), "remote.mosh_ports") or "60000:60010"
        if not MOSH_PORTS_RE.match(mosh_ports):
            raise ManifestError(f"remote.mosh_ports must be START:END (got '{mosh_ports}')")
        lo, hi = (int(x) for x in mosh_ports.split(":"))
        if lo > hi or hi > 65535 or lo < 1024:
            raise ManifestError(
                f"remote.mosh_ports '{mosh_ports}' out of range (need 1024 <= START <= END <= 65535)")
        mosh_ports_dash = f"{lo}-{hi}"
    out["MOSH_PORTS"] = mosh_ports
    out["MOSH_PORTS_DASH"] = mosh_ports_dash

    # ── Identity refs (aggregated errors) ───────────────────────────────
    ids = _section(manifest, "identities")
    obs_refs = _word_list(ids.get("obsidian"), "identities.obsidian")
    watch_refs = _word_list(ids.get("watch"), "identities.watch")

    secret_vars = set((env.get("SECRET_KEY_VARS") or "").split())
    identity_errors = []

    def check_ref(kind, prefix, ref):
        if not REF_RE.match(ref):
            identity_errors.append(
                f"  {kind} ref '{ref}': illegal characters (allowed: letters, digits, underscore)")
            return
        if not agent_for_ref(ref):
            identity_errors.append(
                f"  {kind} ref '{ref}': suffix is not a known agent (_claude/_codex/_pi/_gemini/_cursor_agent)")
            return
        var = f"{prefix}_{ref}"
        if var not in secret_vars:
            identity_errors.append(f"  {kind} ref '{ref}': {var} not found in {secrets_file}")

    for ref in obs_refs:
        check_ref("obsidian", "OBSIDIAN_KEY", ref)
    for ref in watch_refs:
        check_ref("watch", "OBSIDIAN_WATCH_KEY", ref)
    if identity_errors:
        raise ManifestError(
            "manifest identity references failed validation:\n" + "\n".join(identity_errors))
    out["OBS_REFS"] = " ".join(obs_refs)
    out["WATCH_REFS"] = " ".join(watch_refs)
    # ref:agent pairs — so up.sh's key-composition and wiring loops don't
    # need their own copy of the suffix→agent mapping anymore.
    out["OBS_REF_AGENTS"] = " ".join(f"{r}:{agent_for_ref(r)}" for r in obs_refs)
    out["WATCH_REF_AGENTS"] = " ".join(f"{r}:{agent_for_ref(r)}" for r in watch_refs)

    # ── Egress fold: obsidian implies its endpoint; plugins add theirs ──
    def add_egress_domain(domain):
        if domain not in egress_items:
            egress_items.append(domain)

    if obs_refs:
        add_egress_domain(OBSIDIAN_HOST)

    # ── Per-plugin egress + mcp entry validation (fail-fast, old order) ─
    # Each mcp server is local (command:) OR remote (url:) — the shape, not a
    # type: field, decides. host_port: is legal only with a remote server;
    # install: is required iff a local server (the Dockerfile bakes it).
    plugin_mcp_entries = []
    seen_server_names = set()
    host_ports = []
    env_slots = {}    # SLOT -> (plugin, hint)  for env-scoped secrets
    agent_slots = {}  # SLOT -> plugin          declared now, bound in Phase 2
    for p in plugins:
        doc = plugin_files[p]
        if doc is None:
            doc = {}  # empty yaml file → null → a valid no-op plugin
        if not isinstance(doc, dict):
            raise ManifestError(
                f"plugin '{p}': plugins/{p}.yml must be a YAML map (got a {_yaml_type(doc)})")
        for d in _comma_list(doc.get("egress"), f"plugin '{p}' egress"):
            if not DOMAIN_RE.match(d):
                raise ManifestError(
                    f"plugin '{p}' egress entry '{d}' is not a bare hostname (no scheme, path, port, or wildcard — a domain already covers its subdomains)")
            add_egress_domain(d)
        mcp = doc.get("mcp")
        mcp = {} if _falsy(mcp) else mcp
        if not isinstance(mcp, dict):
            raise ManifestError(f"plugin '{p}' mcp must be a map of MCP servers")
        has_local = False
        has_remote = False
        for n, spec in mcp.items():
            if not NAME_RE.match(n):
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': illegal characters in name (allowed: letters, digits, underscore, dash — it becomes a TOML/JSON key)")
            if n in RESERVED_SERVER_NAMES:
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': name is reserved for generated servers")
            spec = spec if isinstance(spec, dict) else {}
            is_local = "command" in spec
            is_remote = "url" in spec
            if is_local and is_remote:
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': set exactly one of command: (local stdio) or url: (remote http), not both")
            if not is_local and not is_remote:
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': needs command: (local stdio) or url: (remote http)")
            if is_local:
                has_local = True
                if not isinstance(spec.get("command"), str):
                    raise ManifestError(
                        f"plugin '{p}' mcp server '{n}': command must be a string (local stdio server)")
                extra = ",".join(k for k in spec if k not in ("command", "args"))
                if extra:
                    raise ManifestError(
                        f"plugin '{p}' mcp server '{n}': unsupported field(s) for a local server: {extra} (only command and args)")
            else:
                has_remote = True
                if not isinstance(spec.get("url"), str):
                    raise ManifestError(
                        f"plugin '{p}' mcp server '{n}': url must be a string (remote http server)")
                headers = spec.get("headers", {})
                if not isinstance(headers, dict) or not all(isinstance(v, str) for v in headers.values()):
                    raise ManifestError(
                        f"plugin '{p}' mcp server '{n}': headers must be a map of string values")
                extra = ",".join(k for k in spec if k not in ("url", "headers"))
                if extra:
                    raise ManifestError(
                        f"plugin '{p}' mcp server '{n}': unsupported field(s) for a remote server: {extra} (only url and headers)")
            if n in seen_server_names:
                raise ManifestError(
                    f"multiple enabled plugins define the same MCP server name: {n}")
            seen_server_names.add(n)

        install = doc.get("install")
        if has_local and (_falsy(install) or not isinstance(install, str) or not install.strip()):
            raise ManifestError(
                f"plugin '{p}': a local (command:) server needs an install: block (baked into the image)")

        hp = doc.get("host_port")
        if not _falsy(hp):
            if not has_remote:
                raise ManifestError(
                    f"plugin '{p}': host_port is only valid with a remote (url:) server")
            if isinstance(hp, bool) or not isinstance(hp, int):
                raise ManifestError(f"plugin '{p}': host_port must be an integer port number")
            if not 1 <= hp <= 65535:
                raise ManifestError(f"plugin '{p}': host_port {hp} out of range (1-65535)")
            host_ports.append(hp)

        secrets = doc.get("secrets")
        secrets = {} if _falsy(secrets) else secrets
        if not isinstance(secrets, dict):
            raise ManifestError(f"plugin '{p}' secrets must be a map of SLOT: scope")
        for slot, val in secrets.items():
            if not REF_RE.match(slot):
                raise ManifestError(
                    f"plugin '{p}' secret slot '{slot}': illegal characters (must be a shell env var name)")
            if slot in env_slots or slot in agent_slots:
                raise ManifestError(f"secret slot '{slot}' is declared by more than one enabled plugin")
            scope, hint = _parse_secret(val, p, slot)
            if scope == "env":
                env_slots[slot] = (p, hint)
            else:
                agent_slots[slot] = p

        # One line of compact JSON per plugin — the --build-payload contract.
        plugin_mcp_entries.append(json.dumps(mcp, separators=(",", ":"), ensure_ascii=False))
    out["PLUGIN_MCP_ENTRIES"] = "".join(e + "\n" for e in plugin_mcp_entries)
    # Sorted + deduped so the firewall grant string is order-independent of the
    # plugin list (the old CAPABILITY_PORTS table emitted 8811,8813,8814 in
    # order) and two plugins sharing a port don't double up the grant.
    out["HOST_MCP_PORTS"] = ",".join(str(p) for p in sorted(set(host_ports)))

    # ── Env-scoped secret bindings (common_secrets) → required-secret plan ──
    # up.sh composes VALUES (it has secrets.env; this module never sees them):
    # each record is SLOT<tab>SOURCE<tab>HINT. A plugin env slot defaults to a
    # same-named source var; common_secrets (map) re-points it, or (list)
    # passes an extra var through by name.
    common = manifest.get("common_secrets")
    remap = {}
    passthrough = []
    if not _falsy(common):
        if isinstance(common, list):
            passthrough = _word_list(common, "common_secrets")
        elif isinstance(common, dict):
            for slot, source in common.items():
                remap[slot] = _scalar(source, f"common_secrets.{slot}")
        else:
            raise ManifestError("manifest common_secrets: must be a list of names or a map of SLOT: source")
    for slot, source in remap.items():
        if slot in agent_slots:
            raise ManifestError(
                f"common_secrets slot '{slot}' is agent-scoped — bind it under agent_secrets, not common_secrets")
        if slot not in env_slots:
            raise ManifestError(
                f"common_secrets slot '{slot}': no enabled plugin declares an env-scoped secret named '{slot}'")
        if not REF_RE.match(source):
            raise ManifestError(
                f"common_secrets slot '{slot}': source '{source}' is not a valid env var name")
    records = []
    for slot, (plugin, hint) in env_slots.items():
        records.append((slot, remap.get(slot, slot), hint))
    for name in passthrough:
        if name in env_slots:
            continue  # already covered as a plugin slot
        if not REF_RE.match(name):
            raise ManifestError(f"common_secrets passthrough '{name}' is not a valid env var name")
        records.append((name, name, ""))
    out["PLUGIN_ENV_SECRETS"] = "".join(f"{s}\t{src}\t{h}\n" for s, src, h in records)

    # ── remote.notify: ntfy egress + env passthrough ────────────────────
    ntfy_url = ""
    ntfy_topic = ""
    if remote_notify == "ntfy":
        ntfy_url = env.get("NTFY_URL") or ""
        if not ntfy_url:
            raise ManifestError(
                f"manifest has remote.notify: ntfy but NTFY_URL is missing from {secrets_file}")
        if any(c in ntfy_url for c in ('#', '"', "'")):
            raise ManifestError(
                "NTFY_URL must be a bare origin (no '#', quotes) — put the topic in NTFY_TOPIC")
        # Host = URL minus scheme, path, userinfo, port — the path strip must
        # precede the userinfo strip so an '@' in a path can't masquerade as
        # userinfo (same order as the old sed).
        host = re.sub(r"^[A-Za-z]+://", "", ntfy_url)
        host = re.sub(r"/.*$", "", host)
        host = re.sub(r"^.*@", "", host)
        host = re.sub(r":[0-9]+$", "", host)
        if not host:
            raise ManifestError(f"cannot parse a host from NTFY_URL '{ntfy_url}'")
        if IPV4_RE.match(host):
            # IP literal: the domain allowlist is dnsmasq-driven, so an IP
            # host must go through the CIDR path or the push is firewalled.
            if f"{host}/32" not in cidr_items:
                cidr_items.append(f"{host}/32")
        else:
            add_egress_domain(host)
        ntfy_topic = env.get("NTFY_TOPIC") or ""
    out["CONTAINER_NTFY_URL"] = ntfy_url
    out["CONTAINER_NTFY_TOPIC"] = ntfy_topic

    out["EGRESS"] = ",".join(egress_items)
    out["EGRESS_CIDRS"] = ",".join(cidr_items)
    return out


def read_stdin_docs(stream):
    """Line 1: manifest JSON. Then '<name>\\t<json>' per plugins/*.yml file,
    with '!' in place of the JSON when yq could not parse the file."""
    first = stream.readline()
    if not first.strip():
        raise ManifestError("no manifest JSON on stdin")
    try:
        manifest = json.loads(first)
    except ValueError as e:
        raise ManifestError(
            f"manifest did not convert to valid JSON ({e}) — is the manifest YAML valid? (see any yq error above)")
    # yq maps an EMPTY yaml file to null; treat as empty manifest.
    if manifest is None:
        manifest = {}
    plugin_files = {}
    for line in stream:
        if not line.strip():
            continue
        name, sep, doc = line.partition("\t")
        if not sep:
            raise ManifestError(
                f"unexpected document after the manifest (a stray '---' making it multi-document?): {line.strip()[:120]}")
        if doc.strip() == "!":
            plugin_files[name] = UNREADABLE
            continue
        try:
            plugin_files[name] = json.loads(doc)
        except ValueError as e:
            raise ManifestError(f"plugin file '{name}' is not valid JSON ({e})")
    return manifest, plugin_files


def main(argv):
    if "--derive" not in argv:
        print("Error: manifest.py requires --derive (see module docstring)", file=sys.stderr)
        return 2
    try:
        manifest, plugin_files = read_stdin_docs(sys.stdin)
        derived = derive(manifest, plugin_files, os.environ)
    except ManifestError as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    sys.stdout.write(derived.render())
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
