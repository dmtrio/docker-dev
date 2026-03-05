# Agent Dev Container

Isolated Docker environments for AI-assisted development on Unraid. One container per project, each appearing as a real host on your VLAN (`192.168.35.81–90`). SSH in from your MacBook, use VS Code Remote SSH, and access dev servers directly by IP.

## How it works

Each container gets:

- A name you choose (e.g. `my-api`) used as Docker container name and SSH hostname
- A static VLAN IP from the `192.168.35.81–90` pool via macvlan on `br0`
- An isolated `/workspace` mounted from `/mnt/user/docker-dev/<name>`
- Claude Code, GitHub CLI, Gitea CLI (tea), fnm, pipenv

Shared auth (Claude, GitHub/Gitea) lives under `/mnt/user/docker-dev/` and is mounted into whichever containers need it.

---

## Prerequisites

- Docker + Docker Compose on Unraid
- `br0` macvlan network already created in Docker
- IPs `192.168.35.81–90` reserved and outside your DHCP pool
- Your SSH public key (`~/.ssh/id_ed25519.pub`)

---

## First-time Setup

```bash
cp .env.example .env
# Fill in: AUTHORIZED_KEY
chmod +x new-container.sh rm-container.sh
```

---

## Spinning Up a Container

```bash
./new-container.sh
```

Prompts for:

1. **Container name** — e.g. `my-api`
2. **Project path** — defaults to `/mnt/user/docker-dev/<name>`
3. **IP** — auto-suggests the next free IP on `br0`
4. **Git identity** — name and email for commits (per container)
5. **Git forge** — GitHub or Gitea (determines which shared auth dir is mounted)

Prints an SSH config block to paste into `~/.ssh/config` on your Mac.

---

## Connecting from MacBook

Add the printed block to `~/.ssh/config`:

```
Host my-api
    HostName 192.168.35.81
    User coder
    StrictHostKeyChecking no
```

Then:

```bash
ssh my-api

# VS Code: Remote-SSH → Connect to Host → my-api
# Open folder: /workspace
```

---

## First Time in a Container

```bash
ssh my-api

# Auth Claude (once — stored in shared dir)
claude

# Auth GitHub (once — stored in shared dir)
gh auth login

# Or auth Gitea
tea login add
```

---

## Accessing Dev Servers

```
http://192.168.35.81:3000   <- Next.js dev server
http://192.168.35.81:8080   <- Express API
```

No port forwarding needed — macvlan makes each container a real VLAN host.

---

## Managing Containers

```bash
./rm-container.sh              # list all containers
./rm-container.sh my-api       # remove container (shared auth preserved on disk)
docker restart dev-agent-my-api   # restart a container
docker logs -f dev-agent-my-api   # view logs
```

---

## Directory Layout

```
/mnt/user/docker-dev/
├── new-container.sh, rm-container.sh, ...   <- scripts
├── shared/
│   ├── claude/           <- shared, ~/.claude
│   ├── gh/               <- shared, ~/.config/gh (GitHub)
│   └── gitea/            <- shared, ~/.config/tea (Gitea)
└── workspaces/
    ├── my-api/           <- workspace for container "my-api"
    └── personal-site/    <- workspace for container "personal-site"
```
