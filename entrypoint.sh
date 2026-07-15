#!/bin/bash
set -e

CONTAINER_NAME="${CONTAINER_NAME:-unnamed}"

echo "╔══════════════════════════════════════════╗"
echo "║        Agent Dev Container         ║"
echo "║        ${CONTAINER_NAME}                 ║"
echo "╚══════════════════════════════════════════╝"

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
    su -c "git config --global user.name '$GIT_USER_NAME'" coder
    echo "✓ Git user.name: $GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    su -c "git config --global user.email '$GIT_USER_EMAIL'" coder
    echo "✓ Git user.email: $GIT_USER_EMAIL"
fi

# (No /workspace/.mcp.json symlink: Claude Code reads .mcp.json only from
# its start directory — the per-container config lives in /workspace/main
# and is symlinked into each worktree per the workspace contract.)

# ── Git safe directory ────────────────────────────────────────────────────────
su -c "git config --global safe.directory /workspace" coder

# ── Git over HTTPS via gh credential helper ──────────────────────────────────
# One credential lane for both API and git transport: agents present
# GH_TOKEN (shim env), humans fall back to the shared gh login. No SSH keys.
su -c "git config --global credential.'https://github.com'.helper '!gh auth git-credential'" coder

# ── SSH mode vs attach mode ───────────────────────────────────────────────────
if [ "$SSH_ENABLED" = "true" ]; then
    # SSH host keys
    if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
        echo "Generating SSH host keys..."
        ssh-keygen -A
        echo "✓ SSH host keys generated"
    fi

    CONTAINER_IP=$(hostname -I | awk '{print $1}')
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Container:  dev-agent-${CONTAINER_NAME}"
    echo "  Hostname:   ${CONTAINER_NAME}"
    echo "  IP:         ${CONTAINER_IP}"
    echo ""
    echo "  SSH:        ssh coder@${CONTAINER_IP}"
    echo "  VS Code:    Remote SSH → ${CONTAINER_NAME} (if ~/.ssh/config is set)"
    echo "  Workspace:  /workspace"
    echo ""
    echo "  Dev servers will be reachable at http://${CONTAINER_IP}:<port>"
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
