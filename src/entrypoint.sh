#!/bin/bash
set -e

CONTAINER_NAME="${CONTAINER_NAME:-unnamed}"

echo "╔══════════════════════════════════════════╗"
echo "║        Agent Dev Container         ║"
echo "║        ${CONTAINER_NAME}                 ║"
echo "╚══════════════════════════════════════════╝"

# ── Persist ~/.claude.json via symlink ────────────────────────────────────────
# Non-fatal (|| true): a failure here (e.g. an unexpectedly root-owned volume
# mountpoint) must not crash-loop the container before the firewall runs — it
# only means claude.json isn't persisted this boot.
su coder -c 'if [ ! -L /home/coder/.claude.json ]; then [ -f /home/coder/.claude.json ] && mv /home/coder/.claude.json /home/coder/.claude/claude.json; ln -sf /home/coder/.claude/claude.json /home/coder/.claude.json; fi' || true

# ── Egress firewall (default ON — fail loud, never run open) ─────────────────
if [ "${ENABLE_FIREWALL:-true}" = "true" ]; then
    if /usr/local/bin/init-firewall.sh; then
        echo "✓ Egress firewall active"
    else
        echo ""
        echo "FATAL: firewall setup failed (missing NET_ADMIN/NET_RAW caps?)."
        echo "Refusing to start with open egress. Set ENABLE_FIREWALL=false to"
        echo "run without the firewall, or add cap_add: [NET_ADMIN, NET_RAW]."
        exit 1
    fi
else
    echo "⚠ Egress firewall DISABLED (ENABLE_FIREWALL=false)"
fi

# ── Git config ────────────────────────────────────────────────────────────────
if [ -n "$GIT_USER_NAME" ]; then
    GIT_USER_NAME="$GIT_USER_NAME" su coder -c 'git config --global user.name "$GIT_USER_NAME"'
    echo "✓ Git user.name: $GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    GIT_USER_EMAIL="$GIT_USER_EMAIL" su coder -c 'git config --global user.email "$GIT_USER_EMAIL"'
    echo "✓ Git user.email: $GIT_USER_EMAIL"
fi

# (No /workspace/.mcp.json symlink: Claude Code reads .mcp.json only from
# its start directory — the per-container config lives in /workspace/main
# and is symlinked into each worktree per the workspace contract.)

# ── Workspace skeleton (always present so editors can attach) ────────────────
# The editor opens /workspace/dev.code-workspace, whose "main" folder makes the
# integrated-terminal cwd /workspace/main. Guarantee that path exists at EVERY
# boot — independent of whether up.sh's clone/init bootstrap has run yet, and
# surviving a private-repo clone that failed — so "Attach to Running Container"
# never dies with 'cwd "/workspace/main" does not exist'. Left empty (no .git)
# when unbootstrapped: git clone accepts an existing empty dir, and up.sh's
# `[ -d /workspace/main/.git ]` guard still retries the clone on a later rerun.
su coder -c 'mkdir -p /workspace/main /workspace/worktrees'

# ── Git safe directory ────────────────────────────────────────────────────────
su -c "git config --global safe.directory /workspace" coder

# ── Git over HTTPS via gh credential helper ──────────────────────────────────
# One credential lane for both API and git transport: agents present
# GH_TOKEN (shim env), humans fall back to the shared gh login. No SSH keys.
su -c "git config --global credential.'https://github.com'.helper '!gh auth git-credential'" coder

# ── SSH mode vs attach mode ───────────────────────────────────────────────────
if [ "$SSH_ENABLED" = "true" ]; then
    # Runtime key injection — same image everywhere, key comes from the
    # manifest deploy (SSH_AUTHORIZED_KEY in secrets.env). Fail loud rather
    # than start sshd nobody can log into.
    if [ -z "$SSH_AUTHORIZED_KEY" ]; then
        echo "FATAL: SSH_ENABLED=true but SSH_AUTHORIZED_KEY is empty."
        echo "Set SSH_AUTHORIZED_KEY in ~/dev-agent/secrets.env (your public key)."
        exit 1
    fi
    echo "$SSH_AUTHORIZED_KEY" > /home/coder/.ssh/authorized_keys
    chmod 600 /home/coder/.ssh/authorized_keys
    chown coder:coder /home/coder/.ssh/authorized_keys

    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        echo "Generating SSH host keys..."
        ssh-keygen -A
        echo "✓ SSH host keys generated"
    fi

    # RFC 04: sshd builds each session's env via PAM (/etc/environment) and
    # ignores container env — persist the remote-access vars there so login
    # shells (and the tmux server/hooks they start) can see them. mosh
    # sessions inherit from their SSH bootstrap, so this covers both.
    for var in REMOTE_TMUX MOSH_PORTS NTFY_URL NTFY_TOPIC CONTAINER_NAME; do
        val="${!var:-}"
        [ -n "$val" ] || continue
        sed -i "/^$var=/d" /etc/environment
        echo "$var=$val" >> /etc/environment
    done
    [ "${REMOTE_TMUX:-false}" = "true" ] && echo "✓ Remote access: SSH/mosh logins land in tmux session 'agent'"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Container:  dev-agent-${CONTAINER_NAME}   (sshd on :22, published"
    echo "              on the host at the manifest's ssh.port)"
    echo "  SSH:        ssh -p <ssh.port> coder@<docker-host>"
    echo "  VS Code:    Remote-SSH to the same host/port"
    echo "  Workspace:  /workspace"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""

    echo "Starting sshd..."
    exec /usr/sbin/sshd -D
else
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Container:  dev-agent-${CONTAINER_NAME}   (attach mode, no sshd)"
    echo ""
    echo "  VS Code / Cursor:"
    echo "    Dev Containers: Attach to Running Container → dev-agent-${CONTAINER_NAME}"
    echo "    then open /workspace (or /workspace/dev.code-workspace)"
    echo ""
    echo "  Terminal:   docker exec -it -u coder dev-agent-${CONTAINER_NAME} bash"
    echo "  Workspace:  /workspace"
    echo ""
    echo "  Dev servers: use VS Code port forwarding, or publish ports at launch"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    exec sleep infinity
fi
