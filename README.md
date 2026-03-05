# Claude Code Dev Container

Isolated, reproducible Docker environments for Claude Code. One container per project, each appearing as a real host on your VLAN (`192.168.35.80–90`). SSH in from your MacBook with local VS Code Remote SSH. Dev servers are directly accessible by IP. Code never touches `main` — Claude pushes branches, you review PRs.

## How it works

Each container gets:
- A name you choose (e.g. `personal-site`) used as both the Docker container name and SSH hostname
- A static VLAN IP from the `192.168.35.80–90` pool via macvlan on `br0`
- An isolated `/workspace` mounted from your Unraid project subdirectory
- Full Claude Code + GitHub CLI + fnm + pipenv inside

Your MacBook SSHes directly to the container IP — no port mapping, no tunnels on the local network. Any dev server Claude starts (Vite, Next, Express, etc.) is reachable at `http://192.168.35.8x:<port>` from your Mac immediately.

---

## Prerequisites

- Docker + Docker Compose on Unraid
- `br0` as the Unraid bridge interface (verify with `ip link show`)
- IPs `192.168.35.80–90` reserved and outside your DHCP pool
- Your SSH public key (`~/.ssh/id_ed25519.pub`)
- Unraid projects share at `/mnt/user/dev/`

---

## First-time Setup

### 1. Configure
```bash
cp .env.example .env
# Fill in: AUTHORIZED_KEY, GIT_USER_NAME, GIT_USER_EMAIL
```

### 2. Bootstrap shared network and volumes (once)
```bash
chmod +x bootstrap.sh new-container.sh rm-container.sh list-containers.sh
./bootstrap.sh
```

Creates:
- `claude-macvlan` Docker network (macvlan on `br0`, `192.168.35.0/24`)
- Shared volumes: `claude-auth`, `gh-auth`, `claude-vscode-server`

---

## Spinning Up a Container

```bash
./new-container.sh --name personal-site --path /mnt/user/dev/personal-site
```

Or interactively:
```bash
./new-container.sh
```

The script assigns the next available IP, starts the container, and prints the SSH config block to add on your MacBook.

### Add to MacBook ~/.ssh/config

```
Host personal-site
    HostName 192.168.35.80
    User coder
    StrictHostKeyChecking no
```

---

## Connecting from MacBook

```bash
ssh personal-site

# VS Code Remote SSH
# Ctrl+Shift+P → "Remote-SSH: Connect to Host" → personal-site
# Open folder: /workspace
```

---

## First Time in a Container

```bash
ssh personal-site

# Auth Claude (once — stored in shared volume)
claude

# Auth GitHub (once — stored in shared volume)
gh auth login
# PAT permissions: Contents (read/write) + Pull Requests (read/write)
# Do NOT grant merge or admin permissions
```

---

## Using Claude Code

```bash
ssh personal-site
cd /workspace

# Interactive
claude

# Fire-and-forget
claude --dangerously-skip-permissions -p "scaffold a Next.js app with Tailwind"
```

### Recommended CLAUDE.md

Add `/workspace/CLAUDE.md` to each project:
```markdown
# Project Context

## What this is
[Brief description]

## Rules
- Always work on a feature branch, never commit to main
- After completing work, update claude-progress.txt
- Use conventional commits (feat:, fix:, chore:)
- When done: gh pr create --title "..." --body "..."
```

---

## Accessing Dev Servers

```
http://192.168.35.80:3000   ← Next.js dev server
http://192.168.35.81:8080   ← Express API
```

No port forwarding needed — macvlan makes each container a real VLAN host.

---

## Managing Containers

```bash
./list-containers.sh          # show all containers + status
./rm-container.sh personal-site   # remove container (keeps shared auth volumes)
```

---

## Volume Reference

| Volume | Scope | Contents |
|--------|-------|----------|
| `claude-auth` | Shared | Claude Code auth + skills |
| `gh-auth` | Shared | GitHub CLI auth |
| `claude-vscode-server` | Shared | VS Code server + extensions |
| `claude-dev-{name}-npm` | Per container | npm globals |
| `claude-dev-{name}-ssh-host-keys` | Per container | SSH host keys |

---

## GitHub Workflow

```
Claude:  git checkout -b feature/x
Claude:  [writes code, commits]
Claude:  gh pr create
You:     review + merge on GitHub
         main never touched until you approve
```
