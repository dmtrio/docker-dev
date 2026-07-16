# Agent Dev Containers

Isolated, firewalled Docker environments where AI coding agents work with
full permissions — locally on your Mac (or any Docker host). One container
per project, declared by a manifest. The assembly is a config.

```
containers/<name>.yml  ──./up.sh <name>──►  dev-agent-<name>
        │                                      ├── agents: claude, codex, pi,
~/dev-agent/secrets.env                        │   gemini, cursor-agent, aider
  (all secret values,                          ├── egress firewall (zone allowlist)
   never mounted)                              ├── /workspace (volume): main/ + worktrees/
                                               ├── /agent-rules (ro): global rules + skills
~/git/agent-conf                               ├── /artifacts → Mac-visible outbox
  (rules repo, mounted ro)                     └── per-agent identity via shims
```

## The two files you author

1. **`containers/<name>.yml`** — one manifest = one container: repo, memory,
   tools, capability grants, per-agent identities. Secret-free, committable.
   Copy `containers/TEMPLATE.yml` and edit.
2. **`~/dev-agent/secrets.env`** — every secret value, one file, mode 600,
   never mounted. See `.env.example` for the naming conventions.

Everything else is derived: `./up.sh <name>` (idempotent) composes
credentials, applies the firewall, clones the repo, lays out worktrees, and
generates MCP configs. `./down.sh <name>` stops (code survives);
`--purge` forgets the container entirely (artifacts still survive).

## Prerequisites

- Docker Desktop (macOS) or Docker Engine (Linux)
- `yq` (`brew install yq`)
- The rules repo checked out at `~/git/agent-conf`, with
  `~/dev-agent/rules` symlinked to its `rules/` dir (Linux hosts: clone it)
- `~/dev-agent/secrets.env` (chmod 600) — see `.env.example`

## Quick start

```bash
cp containers/TEMPLATE.yml containers/my-app.yml
vim containers/my-app.yml          # repo URL, memory, capabilities, identities
./up.sh my-app
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

`~/git/agent-conf` mounts read-only at `/agent-rules` in every container:
`AGENTS.md` fans out as every agent's global rules file, `skills/` as
Claude's skills. Rule layers: global → `/workspace/rules.local.md`
(container-local, uncommitted) → the project repo's own CLAUDE.md.
Agents propose rule changes via PR (as the machine user); after you merge,
`git pull` in `~/git/agent-conf` updates every container live.

## Persistence map

| State | Lives in | Survives recreate | Survives `--purge` |
|---|---|---|---|
| Code | workspace volume (+ git) | ✓ | ✗ (git: forever) |
| Agent logins, MCP approvals | per-container auth volumes | ✓ | ✗ |
| Identity keys | `secrets.env` (composed at up) | ✓ | ✓ |
| Rules & skills | `~/git/agent-conf` | ✓ | ✓ |
| Non-code outputs | `~/dev-agent/artifacts/<name>/` (`/artifacts`) | ✓ | ✓ |

## Repo map

- `up.sh` / `down.sh` — container lifecycle from manifests
- `containers/` — manifests (TEMPLATE.yml to start)
- `Dockerfile`, `docker-compose.local.yml`, `entrypoint.sh`,
  `init-firewall.sh`, `workspace.CLAUDE.md` — the image and its contracts
- `run-*.sh` — host-side capability services
- `import-obsidian-keys.sh`, `update-agent-keys.sh` — secrets tooling
  (update-agent-keys is a temporary override; durable changes go in
  secrets.env)
- `docker-compose.ssh.yml` — overlay applied automatically when a manifest
  has an `ssh:` section
- `example/` — reference material from other machines, not instructions

## Remote hosts: homelab (Unraid) & VPS

Same system, same files, one addition. On any Linux box with Docker:

1. Install `yq` (static binary), clone this repo and `agent-conf`
   (symlink `~/dev-agent/rules` → the checkout's `rules/` dir, or set
   `DEV_AGENT_HOME`).
2. Create `~/dev-agent/secrets.env` (600) — including
   `SSH_AUTHORIZED_KEY` (your public key).
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
