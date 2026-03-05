#!/bin/bash
set -e

CONTAINER_NAME="${CONTAINER_NAME:-unnamed}"

echo "╔══════════════════════════════════════════╗"
echo "║        Agent Dev Container         ║"
echo "║        ${CONTAINER_NAME}                 ║"
echo "╚══════════════════════════════════════════╝"

# ── Git config ────────────────────────────────────────────────────────────────
if [ -n "$GIT_USER_NAME" ]; then
    su -c "git config --global user.name '$GIT_USER_NAME'" coder
    echo "✓ Git user.name: $GIT_USER_NAME"
fi
if [ -n "$GIT_USER_EMAIL" ]; then
    su -c "git config --global user.email '$GIT_USER_EMAIL'" coder
    echo "✓ Git user.email: $GIT_USER_EMAIL"
fi

# ── Git safe directory ────────────────────────────────────────────────────────
su -c "git config --global safe.directory /workspace" coder

# ── SSH host keys ─────────────────────────────────────────────────────────────
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    echo "Generating SSH host keys..."
    ssh-keygen -A
    echo "✓ SSH host keys generated"
fi

# ── Print connection info ─────────────────────────────────────────────────────
CONTAINER_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Container:  claude-dev-${CONTAINER_NAME}"
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

# ── Start SSH daemon ──────────────────────────────────────────────────────────
echo "Starting sshd..."
exec /usr/sbin/sshd -D
