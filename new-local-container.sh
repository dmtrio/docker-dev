#!/bin/bash
# new-local-container.sh
# Spins up a local Agent dev container (RFC 03: attach mode — no sshd/macvlan).
# Universal: macOS (Docker Desktop / OrbStack) and plain Linux Docker Engine.
# Bash 3.2 compatible (macOS default shell).
#
# Usage: ./new-local-container.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"
SHARED_PATH="$BASE_PATH/shared"

# ── Platform detection ────────────────────────────────────────────────────────
# Docker Desktop (macOS) maps bind-mount ownership transparently; plain Linux
# does not, so there the container user must match the host user.
if [ "$(uname -s)" = "Linux" ]; then
    USER_UID="$(id -u)"
    USER_GID="$(id -g)"
else
    USER_UID=1000
    USER_GID=1000
fi

# ── Container name ────────────────────────────────────────────────────────────
printf "Container name: "
read CONTAINER_NAME
CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cd 'a-z0-9-')

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: invalid name"
    exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -q "^dev-agent-$CONTAINER_NAME$"; then
    echo "Error: container 'dev-agent-$CONTAINER_NAME' already exists"
    exit 1
fi

# ── Repo ──────────────────────────────────────────────────────────────────────
printf "Repo URL to clone as /workspace/main (blank = git init): "
read REPO_URL

# ── Git forge ─────────────────────────────────────────────────────────────────
echo "Git forge:"
echo "  1) GitHub  (gh auth login)"
echo "  2) Gitea   (tea login add)"
printf "Choose [1]: "
read FORGE_CHOICE

case "${FORGE_CHOICE:-1}" in
    1)
        FORGE="github"
        FORGE_AUTH_PATH="$SHARED_PATH/gh"
        FORGE_AUTH_MOUNT="/home/coder/.config/gh"
        ;;
    2)
        FORGE="gitea"
        FORGE_AUTH_PATH="$SHARED_PATH/gitea"
        FORGE_AUTH_MOUNT="/home/coder/.config/tea"
        ;;
    *)
        echo "Error: invalid choice"
        exit 1
        ;;
esac

# ── Git identity (defaults from host git config) ─────────────────────────────
DEFAULT_NAME="$(git config --global user.name 2>/dev/null || true)"
DEFAULT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
printf "Git user.name [%s]: " "$DEFAULT_NAME"
read GIT_USER_NAME
GIT_USER_NAME="${GIT_USER_NAME:-$DEFAULT_NAME}"
printf "Git user.email [%s]: " "$DEFAULT_EMAIL"
read GIT_USER_EMAIL
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$DEFAULT_EMAIL}"

# ── AI tools ─────────────────────────────────────────────────────────────────
echo "AI tools to install:"
printf "  Claude Code? [Y/n]: "
read INSTALL_CLAUDE
printf "  Aider?       [Y/n]: "
read INSTALL_AIDER
printf "  Gemini CLI?  [Y/n]: "
read INSTALL_GEMINI

case "${INSTALL_CLAUDE:-y}" in [Nn]*) INSTALL_CLAUDE=false ;; *) INSTALL_CLAUDE=true ;; esac
case "${INSTALL_AIDER:-y}"  in [Nn]*) INSTALL_AIDER=false  ;; *) INSTALL_AIDER=true  ;; esac
case "${INSTALL_GEMINI:-y}" in [Nn]*) INSTALL_GEMINI=false ;; *) INSTALL_GEMINI=true ;; esac

# ── Host MCP + extra egress (per RFC 03: opt-in, default closed) ─────────────
printf "Host MCP ports (comma-separated, blank = host unreachable): "
read HOST_MCP_PORTS
printf "Extra allowed egress domains (comma-separated, blank = none): "
read EXTRA_ALLOWED_DOMAINS

# ── Ensure shared dirs exist ──────────────────────────────────────────────────
mkdir -p "$SHARED_PATH/claude" "$FORGE_AUTH_PATH"
# Must be a valid MCP config — an empty file breaks `claude mcp list`
[ -s "$SHARED_PATH/mcp.json" ] || echo '{"mcpServers":{}}' > "$SHARED_PATH/mcp.json"

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "Spinning up dev-agent-$CONTAINER_NAME..."

CONTAINER_NAME="$CONTAINER_NAME" \
USER_UID="$USER_UID" \
USER_GID="$USER_GID" \
SHARED_PATH="$SHARED_PATH" \
FORGE_AUTH_PATH="$FORGE_AUTH_PATH" \
FORGE_AUTH_MOUNT="$FORGE_AUTH_MOUNT" \
GIT_USER_NAME="$GIT_USER_NAME" \
GIT_USER_EMAIL="$GIT_USER_EMAIL" \
INSTALL_CLAUDE="$INSTALL_CLAUDE" \
INSTALL_AIDER="$INSTALL_AIDER" \
INSTALL_GEMINI="$INSTALL_GEMINI" \
HOST_MCP_PORTS="$HOST_MCP_PORTS" \
EXTRA_ALLOWED_DOMAINS="$EXTRA_ALLOWED_DOMAINS" \
docker compose -p "dev-agent-$CONTAINER_NAME" -f "$SCRIPT_DIR/docker-compose.local.yml" up -d --build

# ── Wait for firewall/entrypoint to settle ────────────────────────────────────
echo "Waiting for container startup (firewall setup)..."
i=0
while [ $i -lt 24 ]; do
    STATUS="$(docker inspect -f '{{.State.Status}}' "dev-agent-$CONTAINER_NAME" 2>/dev/null || echo missing)"
    if [ "$STATUS" = "exited" ] || [ "$STATUS" = "missing" ]; then
        echo "Error: container failed to start. Logs:"
        docker logs "dev-agent-$CONTAINER_NAME" 2>&1 | tail -20
        exit 1
    fi
    if docker logs "dev-agent-$CONTAINER_NAME" 2>&1 | grep -q "firewall active\|firewall DISABLED"; then
        break
    fi
    sleep 5
    i=$((i + 1))
done

# ── Bootstrap workspace layout (RFC 03 worktree contract) ─────────────────────
echo "Bootstrapping /workspace layout..."

if [ -n "$REPO_URL" ]; then
    docker exec -u coder "dev-agent-$CONTAINER_NAME" bash -c \
        "[ -d /workspace/main/.git ] || git clone '$REPO_URL' /workspace/main" \
        || echo "WARNING: clone failed (private repo? run 'gh auth login' inside, then clone to /workspace/main)"
else
    docker exec -u coder "dev-agent-$CONTAINER_NAME" bash -c \
        "[ -d /workspace/main/.git ] || git init -b main /workspace/main"
fi

docker exec -u coder "dev-agent-$CONTAINER_NAME" bash -c '
mkdir -p /workspace/worktrees
if [ ! -f /workspace/dev.code-workspace ]; then
cat > /workspace/dev.code-workspace <<EOF
{
  "folders": [
    { "path": "main", "name": "main" }
  ],
  "settings": {}
}
EOF
fi
'

docker cp "$SCRIPT_DIR/workspace.CLAUDE.md" "dev-agent-$CONTAINER_NAME:/workspace/CLAUDE.md"
docker exec "dev-agent-$CONTAINER_NAME" chown coder:coder /workspace/CLAUDE.md

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Container:  dev-agent-$CONTAINER_NAME"
echo "  Forge:      $FORGE"
echo "  Firewall:   on (HOST_MCP_PORTS='${HOST_MCP_PORTS:-none}')"
echo ""
echo "  VS Code / Cursor:"
echo "    Dev Containers: Attach to Running Container → dev-agent-$CONTAINER_NAME"
echo "    then open /workspace/dev.code-workspace"
echo ""
echo "  Terminal:   docker exec -it dev-agent-$CONTAINER_NAME bash"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
