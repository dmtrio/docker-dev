#!/usr/bin/env python3
"""Host-side manifest reading + validation for up.sh (Phase 2 of the Python
extraction; wire_plugins.py was Phase 1).

up.sh feeds this file yq-converted JSON on stdin and evals the derived shell
assignments it prints:

    input (stdin):  line 1: the manifest as JSON (yq -o=json -I=0)
                    then one line per plugins/*.yml: "<name>\t<json>"
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
- agent_for_ref suffix matching preserves the old case-statement ORDER:
  _cursor_agent wins before _claude/_codex/_pi/_gemini can match.
- Error ordering matches the old top-to-bottom flow: forge → plugins list →
  ssh/remote → mosh ports → identity refs (aggregated) → per-plugin egress +
  mcp entries (fail-fast) → ntfy. Messages are byte-identical to the bash.
"""

import json
import os
import re
import shlex
import sys

NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
REF_RE = re.compile(r"^[A-Za-z0-9_]+$")
DOMAIN_RE = re.compile(
    r"^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+"
    r"[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$"
)
IPV4_RE = re.compile(r"^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$")
MOSH_PORTS_RE = re.compile(r"^[0-9]{1,5}:[0-9]{1,5}$")

DEFAULT_TOOLS = ["claude", "codex", "pi", "gemini", "cursor", "aider"]
RESERVED_SERVER_NAMES = ("coding", "proxyman", "browser", "obsidian-annotated")

# Suffix → agent, in the OLD case-statement order (first match wins).
AGENT_SUFFIXES = (
    ("_cursor_agent", "cursor-agent"),
    ("_claude", "claude"),
    ("_codex", "codex"),
    ("_pi", "pi"),
    ("_gemini", "gemini"),
)

OBSIDIAN_HOST = "mcp-obsidian.dmetr.io"


class ManifestError(Exception):
    """Fatal validation error; main() prints 'Error: …' to stderr, exit 1."""


def _falsy(v):
    # jq/yq `//` alternative operator fires on null and false ONLY.
    return v is None or v is False


def _scalar(v, default=""):
    """Render like `yq -r '.x // ""'`: falsy → default, bool → true/false,
    everything else via str() (numbers lose no precision we care about)."""
    if _falsy(v):
        return default
    if v is True:
        return "true"
    return str(v)


def _raw_flag(v):
    """Render like `yq '.x // false'` (no -r): the raw scalar as yq prints
    it. Downstream only ever compares against the literal string 'true'."""
    if _falsy(v):
        return "false"
    if v is True:
        return "true"
    return str(v)


def agent_for_ref(ref):
    for suffix, agent in AGENT_SUFFIXES:
        if ref.endswith(suffix):
            return agent
    return ""


def _tool_installed(tools, name):
    # jq contains(): a string element "contains" the needle as a SUBSTRING.
    return any(isinstance(t, str) and name in t for t in tools)


class Derived(dict):
    """Ordered VAR → value string map with shell-quoted rendering."""

    def render(self):
        return "".join(f"{k}={shlex.quote(v)}\n" for k, v in self.items())


def derive(manifest, plugin_files, env):
    """The whole old 'Read manifest' section of up.sh as one function.
    manifest: parsed manifest JSON; plugin_files: {name: parsed plugin JSON}
    for every file shipped under plugins/; env: os.environ-like mapping."""
    if not isinstance(manifest, dict):
        raise ManifestError("manifest must be a YAML mapping")
    out = Derived()
    secrets_file = env.get("SECRETS_FILE", "secrets.env")

    # ── Scalars (old Y() reads + defaults) ──────────────────────────────
    out["REPO_URL"] = _scalar(manifest.get("repo"))
    forge = _scalar(manifest.get("forge")) or "github"
    if forge not in ("github", "gitea"):
        raise ManifestError("forge must be github or gitea")
    out["FORGE"] = forge
    git = manifest.get("git") if isinstance(manifest.get("git"), dict) else {}
    out["GIT_USER_NAME"] = _scalar(git.get("name")) or env.get("GIT_NAME_DEFAULT", "")
    out["GIT_USER_EMAIL"] = _scalar(git.get("email")) or env.get("GIT_EMAIL_DEFAULT", "")
    out["MEM_LIMIT"] = _scalar(manifest.get("memory")) or "2g"

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

    # ── Capabilities ────────────────────────────────────────────────────
    caps = manifest.get("capabilities")
    caps = caps if isinstance(caps, dict) else {}
    out["CAP_GATEWAY"] = _raw_flag(caps.get("gateway"))
    out["CAP_PROXYMAN"] = _raw_flag(caps.get("proxyman"))
    out["CAP_BROWSER"] = _raw_flag(caps.get("browser"))
    egress_list = caps.get("egress")
    egress_list = [] if _falsy(egress_list) else egress_list
    if not isinstance(egress_list, list):
        raise ManifestError("manifest capabilities.egress must be a list")
    egress = ",".join(_scalar(d) for d in egress_list)
    cidr_list = caps.get("egress_cidrs")
    cidr_list = [] if _falsy(cidr_list) else cidr_list
    if not isinstance(cidr_list, list):
        raise ManifestError("manifest capabilities.egress_cidrs must be a list")
    egress_cidrs = ",".join(_scalar(c) for c in cidr_list)

    # ── Plugins list (aggregated errors, old order) ─────────────────────
    plugins = manifest.get("plugins")
    if _falsy(plugins):
        plugins = []
    if not isinstance(plugins, list):
        raise ManifestError("manifest plugins: must be a list, e.g. plugins: [serena]")
    plugins = [_scalar(p) for p in plugins]
    plugin_errors = []
    for p in plugins:
        if not NAME_RE.match(p):
            plugin_errors.append(
                f"  plugin '{p}': illegal characters (allowed: letters, digits, underscore, dash)")
            continue
        if p not in plugin_files:
            plugin_errors.append(f"  plugin '{p}': no plugin file at plugins/{p}.yml")
    if plugin_errors:
        raise ManifestError(
            "manifest plugins failed validation:\n" + "\n".join(plugin_errors))
    out["PLUGINS"] = " ".join(plugins)

    # ── ssh / remote (RFC 04) ───────────────────────────────────────────
    ssh = manifest.get("ssh") if isinstance(manifest.get("ssh"), dict) else {}
    ssh_port = _scalar(ssh.get("port"))
    out["SSH_PORT"] = ssh_port
    out["SSH_BIND"] = _scalar(ssh.get("bind")) or "127.0.0.1"

    remote = manifest.get("remote") if isinstance(manifest.get("remote"), dict) else {}
    remote_tmux = _raw_flag(remote.get("tmux"))
    remote_mosh = _raw_flag(remote.get("mosh"))
    remote_notify = _scalar(remote.get("notify"))
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
        mosh_ports = _scalar(remote.get("mosh_ports")) or "60000:60010"
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
    ids = manifest.get("identities") if isinstance(manifest.get("identities"), dict) else {}
    obs_refs = ids.get("obsidian")
    obs_refs = [] if _falsy(obs_refs) else obs_refs
    watch_refs = ids.get("watch")
    watch_refs = [] if _falsy(watch_refs) else watch_refs
    if not isinstance(obs_refs, list) or not isinstance(watch_refs, list):
        raise ManifestError("manifest identities.obsidian / identities.watch must be lists")
    obs_refs = [_scalar(r) for r in obs_refs]
    watch_refs = [_scalar(r) for r in watch_refs]

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

    # ── HOST_MCP_PORTS ──────────────────────────────────────────────────
    ports = []
    if out["CAP_GATEWAY"] == "true":
        ports.append("8811")
    if out["CAP_PROXYMAN"] == "true":
        ports.append("8813")
    if out["CAP_BROWSER"] == "true":
        ports.append("8814")
    out["HOST_MCP_PORTS"] = ",".join(ports)

    # ── Egress fold: obsidian implies its endpoint; plugins add theirs ──
    egress_items = [d for d in egress.split(",") if d] if egress else []

    def add_egress_domain(domain):
        if domain not in egress_items:
            egress_items.append(domain)

    if obs_refs:
        add_egress_domain(OBSIDIAN_HOST)

    # ── Per-plugin egress + mcp entry validation (fail-fast, old order) ─
    plugin_mcp_entries = []
    seen_server_names = set()
    for p in plugins:
        doc = plugin_files[p]
        doc = doc if isinstance(doc, dict) else {}
        p_egress = doc.get("egress")
        p_egress = [] if _falsy(p_egress) else p_egress
        if not isinstance(p_egress, list):
            raise ManifestError(f"plugin '{p}' egress must be a list of domains")
        for d in (_scalar(x) for x in p_egress):
            if not DOMAIN_RE.match(d):
                raise ManifestError(
                    f"plugin '{p}' egress entry '{d}' is not a bare hostname (no scheme, path, port, or wildcard — a domain already covers its subdomains)")
            add_egress_domain(d)
        mcp = doc.get("mcp")
        mcp = {} if _falsy(mcp) else mcp
        if not isinstance(mcp, dict):
            raise ManifestError(f"plugin '{p}' mcp must be a map of stdio servers")
        for n, spec in mcp.items():
            if not NAME_RE.match(n):
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': illegal characters in name (allowed: letters, digits, underscore, dash — it becomes a TOML/JSON key)")
            if n in RESERVED_SERVER_NAMES:
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': name is reserved for generated servers")
            spec = spec if isinstance(spec, dict) else {}
            if not isinstance(spec.get("command"), str):
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': command must be a string (local stdio server)")
            extra = ",".join(k for k in spec if k not in ("command", "args"))
            if extra:
                raise ManifestError(
                    f"plugin '{p}' mcp server '{n}': unsupported field(s): {extra} (only command and args are wired, identically for every agent)")
            if n in seen_server_names:
                raise ManifestError(
                    f"multiple enabled plugins define the same MCP server name: {n}")
            seen_server_names.add(n)
        # One line of compact JSON per plugin — the --build-payload contract.
        plugin_mcp_entries.append(json.dumps(mcp, separators=(",", ":"), ensure_ascii=False))
    out["PLUGIN_MCP_ENTRIES"] = "".join(e + "\n" for e in plugin_mcp_entries)

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
            cidr_items = [c for c in egress_cidrs.split(",") if c] if egress_cidrs else []
            if f"{host}/32" not in cidr_items:
                cidr_items.append(f"{host}/32")
            egress_cidrs = ",".join(cidr_items)
        else:
            add_egress_domain(host)
        ntfy_topic = env.get("NTFY_TOPIC") or ""
    out["CONTAINER_NTFY_URL"] = ntfy_url
    out["CONTAINER_NTFY_TOPIC"] = ntfy_topic

    out["EGRESS"] = ",".join(egress_items)
    out["EGRESS_CIDRS"] = egress_cidrs
    return out


def read_stdin_docs(stream):
    """Line 1: manifest JSON. Then '<name>\\t<json>' per plugins/*.yml file."""
    first = stream.readline()
    if not first.strip():
        raise ManifestError("no manifest JSON on stdin")
    try:
        manifest = json.loads(first)
    except ValueError as e:
        raise ManifestError(f"manifest is not valid JSON ({e})")
    # yq maps an EMPTY yaml file to null; treat as empty manifest.
    if manifest is None:
        manifest = {}
    plugin_files = {}
    for line in stream:
        if not line.strip():
            continue
        name, sep, doc = line.partition("\t")
        if not sep:
            raise ManifestError(f"malformed plugin doc line (no tab): {line!r}")
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
