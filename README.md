# Agent Dev Containers

Isolated, firewalled Docker environments where AI coding agents work with
full permissions — locally on your Mac (or any Docker host). One container
per project, declared by a manifest. The assembly is a config.

```
containers/<name>.yml  ──./up.sh <name>──►  dev-agent-<name>
        │                                      ├── agents: claude, codex, pi,
.dev-agent/secrets.env                         │   gemini, cursor-agent, aider
  (all secret values, gitignored;              ├── egress firewall (zone allowlist)
   move via DEV_AGENT_HOME)                     ├── /workspace (volume): main/ + worktrees/
                                               ├── /agent-rules (ro): global rules + skills
rules/  (bundled default;                       ├── /artifacts → Mac-visible outbox
  override via RULES_PATH)                      └── per-agent identity via shims
```

The repo is self-contained: a fresh clone runs with no external setup.
Runtime state (`secrets.env`, keys, artifacts) defaults to a gitignored
`./.dev-agent/`, and rules come from the bundled `rules/`. A gitignored
`./.env` overrides both — see [Prerequisites](#prerequisites).

## The two files you author

1. **`containers/<name>.yml`** — one manifest = one container: repo, memory,
   tools, capability grants, per-agent identities. Secret-free, committable.
   Copy `containers/TEMPLATE.yml` and edit.
2. **`secrets.env`** — every secret value, one file, mode 600, never mounted
   (default `./.dev-agent/secrets.env`, gitignored). Copy `secrets.env.example`
   and fill in what your manifests reference.

Everything else is derived: `./up.sh <name>` (idempotent) composes
credentials, applies the firewall, clones the repo, lays out worktrees, and
generates MCP configs. `./down.sh <name>` stops (code survives);
`--purge` forgets the container entirely (artifacts still survive).

## Prerequisites

- Docker Desktop (macOS) or Docker Engine (Linux)
- `yq` (`brew install yq`)
- `python3` (any 3.9+, stdlib only — present via Xcode CLT on macOS; on a
  minimal Linux box, `apt install python3`). `up.sh` uses it for manifest
  validation and the wiring payload, preferring `/usr/bin/python3` over
  version-manager shims (`PYTHON3=/path` overrides).

That's it — the repo is self-contained. `up.sh` keeps its runtime state
(secrets, keys, artifacts) in a gitignored `./.dev-agent/` and uses the
bundled `rules/`. To point at your own locations instead, drop a gitignored
`./.env` at the repo root:

```bash
DEV_AGENT_HOME="$HOME/dev-agent"           # move the runtime home (secrets/keys/artifacts)
RULES_PATH="$HOME/git/agent-conf/rules"    # use your own rules repo instead of bundled rules/
```

(When `DEV_AGENT_HOME` is set and `$DEV_AGENT_HOME/rules` exists, it's used as
the rules dir automatically — no need to set `RULES_PATH` too.)

## Quick start

```bash
cp containers/TEMPLATE.yml containers/my-app.yml
./up.sh my-app
```

`TEMPLATE.yml` runs unedited (blank repo → git-inits an empty workspace, no
identities → needs no secrets), so a copy is a working smoke test. Then edit it
— repo URL, memory, capabilities, identities — and rerun (idempotent). Add any
secrets it references to `secrets.env`:

```bash
mkdir -p .dev-agent && cp secrets.env.example .dev-agent/secrets.env   # up.sh also creates it empty
```

Then attach: VS Code / Cursor → **"Dev Containers: Attach to Running
Container"** → `dev-agent-my-app` (lands as `coder` in `/workspace` — open
`dev.code-workspace` for the multi-root worktree view). Terminal:
`docker exec -it -u coder dev-agent-my-app bash`. Run `claude` from
`/workspace/main`.

**First session per container** (persists across rebuilds in per-container
auth volumes): `claude` login; `codex` / `gemini` if used. Agents already
carry the GitHub machine-user token from `secrets.env`.

## Firewall egress (`capabilities:`)

| Manifest key | Effect |
|---|---|
| `egress: [...]` | extra allowed zones (a zone covers its subdomains) |
| `egress_cidrs: [...]` | IP-range escape hatch (LAN subnets) |

A container without a grant cannot reach the zone — enforced by the
in-container firewall (dnsmasq resolver-driven ipset; rotating CDN DNS can't
outrun it).

> The old `gateway`/`proxyman`/`browser` capability flags are **plugins** now
> (see below). `capabilities: {gateway: true}` still works for one release but
> prints a deprecation warning — prefer `plugins: [gateway]`.

## Plugins (every MCP server is a file)

A **plugin** is one file — `plugins/<name>.yml` — describing an MCP server a
container can get. Listing its name in a manifest's `plugins:` wires it in;
unlisted plugins stay dormant in the shared image. There are two shapes,
distinguished by the entry itself (no `type:` field):

**Local** — a stdio server that runs INSIDE the container (`command:`). Its
`install:` runs at image build so the binary is present offline, and it wires
into *every* installed MCP-capable agent.

```yaml
install: |                     # runs at IMAGE BUILD (full network; offline after)
  uv tool install -p 3.13 serena-agent
mcp:                           # wired into every installed agent's MCP config
  serena:                      # ("$PWD" so the server follows worktree sessions)
    command: bash
    args: [-c, 'exec serena start-mcp-server --context ide-assistant --project "$PWD"']
egress:                        # added to this container's firewall allowlist
  - blob.core.windows.net
```

**Remote** — an HTTP server running on the Mac host (`url:`, no `install:`,
nothing baked). `host_port:` folds into the firewall grant; `secrets:` names
the token slot its headers reference. Wired into Claude's `.mcp.json` (the
`${VAR}` ref expands from the shim env); the Mac-side service self-generates
its token into `secrets.env` on first run.

```yaml
host_port: 8811                          # firewall grant for host.docker.internal:8811
secrets:
  MCP_GATEWAY_TOKEN: {scope: env, hint: "gateway (run run-gateway-coding.sh once)"}
mcp:
  coding:
    url: http://host.docker.internal:8811/mcp
    headers: {Authorization: "Bearer ${MCP_GATEWAY_TOKEN}"}
```

Shipped remote plugins (each needs its host service started once):

| Plugin | Port | Mac-side service | Token |
|---|---|---|---|
| `gateway` | 8811 | `run-gateway-coding.sh` — headless Playwright via Docker MCP gateway | `MCP_GATEWAY_TOKEN` |
| `proxyman` | 8813 | `run-proxyman-bridge.sh` — Proxyman traffic capture | `PROXYMAN_BRIDGE_KEY` |
| `browser` | 8814 | `run-research-browser.sh` — watchable desktop Brave/Chrome, isolated profile | `RESEARCH_BROWSER_KEY` |

Two independent axes, deliberately split:

- **Baked (build, image-wide):** every *local* plugin's `install:` runs at
  image build, so all plugin binaries live in the shared image and work offline
  behind the runtime firewall (remote plugins bake nothing). Adding a plugin =
  dropping a file + a rebuild — no `Dockerfile` or `up.sh` edits.
- **Wired (up, per container):** a manifest opts in with `plugins: [serena]`;
  `src/manifest.py` validates the plugin file and derives the wiring, and
  `up.sh` hands it to `src/wire_plugins.py` (baked into the image; one
  `docker exec` with a JSON payload). Local servers merge into every installed
  MCP-capable agent — claude's `.mcp.json` (pre-approved, like the generated
  obsidian server), cursor-agent's / gemini's / pi's JSON configs, and a
  managed `[mcp_servers.*]` block in codex's `config.toml` (aider has no MCP
  support; pi's config is inert until the pi-mcp-adapter extension is
  installed). Remote servers wire into claude's `.mcp.json` only (Phase 1).
  Both fold their `egress`/`host_port` into the firewall. De-listing a plugin
  removes its wiring on the next up. One asymmetry: if the workspace repo
  ships its own `.mcp.json`, claude keeps that file untouched (no plugin
  entries) while the other agents' home-dir configs are still wired.

First plugin: **serena** (`github.com/oraios/serena`) — semantic code
retrieval + editing over LSP. It lazily downloads a language server per
language on first use; github/npm/pythonhosted are already allowlisted
(Python/TS/JS) and the plugin adds the Azure-blob hosts. If some other
language's download is blocked, add the host live with `allow-egress.sh`.

## Identity model

- **Per agent, not per container**: shims front each CLI and load
  `~/.agent-keys/common.env` + `<agent>.env` at process start. Delegation
  (`cursor-agent -p` from claude) never leaks the invoker's credentials.
- **Obsidian Annotated**: one scoped key per agent
  (`OBSIDIAN_KEY_<ref>` in secrets.env), referenced explicitly from the
  manifest's `identities:` lists — validated at `up` time, hard-fail on
  dangling refs.
- **GitHub**: agents act as the machine user (`GH_TOKEN`); your personal
  login never enters a container unless you `gh auth login` there yourself.
  PRs/comments from agents show as the bot; you review and merge as you.

## Rules & skills (shared knowledge, never shared identity)

The rules dir mounts read-only at `/agent-rules` in every container:
`AGENTS.md` fans out as every agent's global rules file, `skills/` as
Claude's skills. By default this is the repo's bundled `rules/`; set
`RULES_PATH` (in `./.env`) to your own rules repo — e.g. `~/git/agent-conf/rules`
— to override. Rule layers: global → `/workspace/rules.local.md`
(container-local, uncommitted) → the project repo's own CLAUDE.md.
Agents propose rule changes via PR; for an external rules repo, `up.sh`
`git pull`s it each run so merged changes land in every container.

## Persistence map

| State | Lives in | Survives recreate | Survives `--purge` |
|---|---|---|---|
| Code | workspace volume (+ git) | ✓ | ✗ (git: forever) |
| Agent logins, MCP approvals | per-container auth volumes | ✓ | ✗ |
| Identity keys | `secrets.env` (composed at up) | ✓ | ✓ |
| Rules & skills | bundled `rules/` (or your `RULES_PATH` repo) | ✓ | ✓ |
| Non-code outputs | `$DEV_AGENT_HOME/artifacts/<name>/` (`/artifacts`) | ✓ | ✓ |

## Repo map

- `up.sh` / `down.sh` — container lifecycle from manifests
- `common.sh` — shared path resolution (sourced by the scripts; not run directly)
- `containers/` — manifests (`TEMPLATE.yml` to copy; your own are gitignored)
- `plugins/` — drop-in local MCP tools (one `<name>.yml` each: install / mcp /
  egress), baked at image build, wired per container via the manifest's
  `plugins:` list
- `rules/` — bundled default agent rules & skills (override via `RULES_PATH`)
- `tests/` — host-runnable checks (`plugins.test.sh` — yq + jq + python3;
  the manifest validation and wiring logic are unit-tested in
  `test_manifest.py` / `test_wire_plugins.py`)
- `Dockerfile`, `docker-compose.local.yml`, `workspace.CLAUDE.md`,
  `src/` (`entrypoint.sh`, `init-firewall.sh`, `manifest.py` — host-side
  manifest validation, `wire_plugins.py` — the agent-config writer `up.sh`
  execs after boot) — the image and its contracts
- `run-*.sh` — host-side capability services
- `allow-egress.sh` — add egress domains to a running container (no restart)
- `update-agent-keys.sh` — temporary per-agent key override; durable changes
  go in secrets.env
- `secrets.env.example` — template for your `secrets.env`
- `.env` (gitignored) — optional `DEV_AGENT_HOME` / `RULES_PATH` /
  `DEV_AGENT_SUBNET` overrides
- `docker-compose.ssh.yml` / `docker-compose.mosh.yml` — overlays applied
  automatically for a manifest's `ssh:` / `remote.mosh` settings
- `script.md` — every script, grouped by lifecycle

## Remote hosts: homelab (Unraid) & VPS

Same system, same files, one addition. On any Linux box with Docker:

1. Install `yq` (static binary) and `python3`, and clone this repo. The bundled `rules/`
   and gitignored `./.dev-agent/` work as-is; set `DEV_AGENT_HOME` /
   `RULES_PATH` in `./.env` only if you want them elsewhere.
2. Put your secrets in `secrets.env` (default `./.dev-agent/secrets.env`,
   600) — including `SSH_AUTHORIZED_KEY` (your public key).
3. Add an `ssh:` section to the container's manifest:

   ```yaml
   ssh:
     port: 2222        # published on the host
     bind: 127.0.0.1   # keep loopback; reach it through your tunnel
   ```

4. `./up.sh <name>` — identical to the Mac. Connect with VS Code
   **Remote-SSH** to the host/port; everything else (firewall, identities,
   rules, artifacts) behaves exactly the same.

Never expose sshd publicly: keep the bind on loopback (or a tunnel
interface) and front it with your WireGuard/VPN tunnel. The remote MCP
plugins (`gateway`/`proxyman`/`browser`) are Mac-desktop services — on
headless hosts leave them out of `plugins:` or run the host service on that
host.

## Remote agent access (phone / second device)

The `remote:` manifest block (requires `ssh:`) turns an SSH-reachable
container into something you can drive from a phone — start a task, walk
away, get pinged when the agent needs you, answer from anywhere. Works for
every agent in the image; nothing is vendor-hosted or public-facing.

```yaml
ssh:     { port: 2222, bind: 127.0.0.1 }
remote:  { tmux: true, mosh: true, notify: ntfy }
```

- **tmux** — interactive SSH/mosh logins land attached to one durable
  session (`agent`). Phone and laptop share the same view; agents survive
  disconnects. `docker exec` and editor terminals are exempt.
- **mosh** — a per-manifest UDP range (`remote.mosh_ports`, default
  60000:60010; disjoint per container, like `ssh.port`), published next to
  sshd with the same bind rules and pinned server-side. Survives phone
  sleep and WiFi↔cellular switches; use a mosh-capable client (e.g. Moshi
  or Blink on iOS).
- **notify: ntfy** — an agent-blind monitor pushes to your ntfy topic when
  the session goes idle at a prompt and nobody is attached. Set `NTFY_URL`
  (+ optional `NTFY_TOPIC`) in `secrets.env`; the host is auto-allowlisted.

**Reach.** All containers sit on one shared bridge (`dev-agent-net`,
`172.30.0.0/24` by default, `DEV_AGENT_SUBNET` in `./.env` to override;
created automatically by `up.sh`). Point your WireGuard/VPN layer at that
CIDR once and every container is reachable at its bridge IP from any
enrolled device — `up.sh` prints the IP in its summary. sshd and the mosh
range stay loopback/tunnel-only; nothing listens publicly.
