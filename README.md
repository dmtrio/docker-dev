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

## Capabilities (manifest → Mac-side service)

| Manifest key | Port | Service (run in tmux/launchd) | Secret in secrets.env |
|---|---|---|---|
| `gateway: true` | 8811 | `run-gateway-coding.sh` — headless Playwright via Docker MCP gateway | `MCP_GATEWAY_TOKEN` |
| `proxyman: true` | 8813 | `run-proxyman-bridge.sh` — Proxyman traffic capture | `PROXYMAN_BRIDGE_KEY` |
| `browser: true` | 8814 | `run-research-browser.sh` — watchable desktop Brave/Chrome, isolated profile | `RESEARCH_BROWSER_KEY` |
| `egress: [...]` | — | extra allowed zones (a zone covers its subdomains) | — |
| `egress_cidrs: [...]` | — | IP-range escape hatch (LAN subnets) | — |

Service tokens self-generate into `secrets.env` on each script's first run.
A container without a grant cannot reach the host or the zone — enforced by
the in-container firewall (dnsmasq resolver-driven ipset; rotating CDN DNS
can't outrun it).

## Plugins (drop-in local MCP tools)

Where capabilities are host-side services (port + secret) and remote MCP
servers need a per-agent key, a **plugin** is the simplest kind of tool: a
local stdio MCP server that runs entirely inside the container. One file —
`plugins/<name>.yml` — describes everything about it:

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

Two independent axes, deliberately split:

- **Baked (build, image-wide):** every plugin file's `install:` runs at image
  build, so all plugin binaries live in the shared image and work offline
  behind the runtime firewall. Adding a plugin = dropping a file + a rebuild —
  no `Dockerfile` or `up.sh` edits.
- **Wired (up, per container):** a manifest opts in with `plugins: [serena]`;
  `up.sh` merges that plugin's `mcp` into the configs of every installed
  MCP-capable agent — claude's `.mcp.json` (pre-approved, like the other
  generated servers), cursor-agent's / gemini's / pi's JSON configs, and a
  managed `[mcp_servers.*]` block in codex's `config.toml` (aider has no MCP
  support) — and its `egress` into the firewall. Containers that don't list
  it carry the dormant binary and nothing else.

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
- `tests/` — host-runnable checks (`plugins.test.sh` — needs only yq + jq)
- `Dockerfile`, `docker-compose.local.yml`, `workspace.CLAUDE.md`,
  `src/` (`entrypoint.sh`, `init-firewall.sh`) — the image and its contracts
- `run-*.sh` — host-side capability services
- `allow-egress.sh` — add egress domains to a running container (no restart)
- `update-agent-keys.sh` — temporary per-agent key override; durable changes
  go in secrets.env
- `secrets.env.example` — template for your `secrets.env`
- `.env` (gitignored) — optional `DEV_AGENT_HOME` / `RULES_PATH` overrides
- `docker-compose.ssh.yml` — overlay applied automatically when a manifest
  has an `ssh:` section
- `script.md` — every script, grouped by lifecycle

## Remote hosts: homelab (Unraid) & VPS

Same system, same files, one addition. On any Linux box with Docker:

1. Install `yq` (static binary) and clone this repo. The bundled `rules/`
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
interface) and front it with Pangolin / Tailscale / WireGuard. Host MCP
capabilities (`gateway`/`proxyman`/`browser`) are Mac-desktop services —
on headless hosts leave them `false` or run the gateway service on that
host.
