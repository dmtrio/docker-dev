#!/bin/bash
# new-container.sh
# Spins up a new Claude Code dev container on the macvlan network.
#
# Usage: ./new-container.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"

SHARED_PATH="/mnt/user/docker-dev"
IP_PREFIX="192.168.35"
IP_POOL_START=81
IP_POOL_END=90

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    echo $SCRIPT_DIR
    echo "Error: .env not found. Copy .env.example to .env and fill in values."
    exit 1
fi
source "$ENV_FILE"

# ── Container name ────────────────────────────────────────────────────────────
read -p "Container name: " CONTAINER_NAME
CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cd 'a-z0-9-')

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: invalid name"
    exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -q "^claude-dev-$CONTAINER_NAME$"; then
    echo "Error: container 'claude-dev-$CONTAINER_NAME' already exists"
    exit 1
fi

# ── Project path ──────────────────────────────────────────────────────────────
DEFAULT_PATH="$SHARED_PATH/$CONTAINER_NAME"
read -p "Project path [$DEFAULT_PATH]: " PROJECT_PATH
PROJECT_PATH="${PROJECT_PATH:-$DEFAULT_PATH}"

if [ ! -d "$PROJECT_PATH" ]; then
    read -p "Path '$PROJECT_PATH' doesn't exist. Create it? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mkdir -p "$PROJECT_PATH"
        echo "Created $PROJECT_PATH"
    else
        echo "Aborted."
        exit 1
    fi
fi

# ── Suggest next available IP ─────────────────────────────────────────────────
USED_IPS=$(docker network inspect br0 \
    --format '{{range .Containers}}{{.IPv4Address}}{{"\n"}}{{end}}' 2>/dev/null \
    | sed 's|/[0-9]*||g')

SUGGESTED_IP=""
for octet in $(seq $IP_POOL_START $IP_POOL_END); do
    CANDIDATE="$IP_PREFIX.$octet"
    if ! echo "$USED_IPS" | grep -q "^$CANDIDATE$"; then
        SUGGESTED_IP="$CANDIDATE"
        break
    fi
done

read -p "Container IP [$SUGGESTED_IP]: " CONTAINER_IP
CONTAINER_IP="${CONTAINER_IP:-$SUGGESTED_IP}"

if [ -z "$CONTAINER_IP" ]; then
    echo "Error: no IP available — specify one manually"
    exit 1
fi

# ── Git forge ─────────────────────────────────────────────────────────────────
echo "Git forge:"
echo "  1) GitHub  (gh auth login)"
echo "  2) Gitea   (tea login add)"
read -p "Choose [1]: " FORGE_CHOICE

case "${FORGE_CHOICE:-1}" in
    1)
        FORGE="github"
        FORGE_AUTH_PATH="$SHARED_PATH/gh-auth"
        FORGE_AUTH_MOUNT="/home/coder/.config/gh"
        ;;
    2)
        FORGE="gitea"
        FORGE_AUTH_PATH="$SHARED_PATH/gitea-auth"
        FORGE_AUTH_MOUNT="/home/coder/.config/tea"
        ;;
    *)
        echo "Error: invalid choice"
        exit 1
        ;;
esac

# ── Git identity ──────────────────────────────────────────────────────────────
read -p "Git user.name: " GIT_USER_NAME
read -p "Git user.email: " GIT_USER_EMAIL

# ── Ensure shared dirs exist ──────────────────────────────────────────────────
mkdir -p "$SHARED_PATH/claude-auth" "$FORGE_AUTH_PATH"

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "Spinning up claude-dev-$CONTAINER_NAME ($CONTAINER_IP)..."

AUTHORIZED_KEY="$AUTHORIZED_KEY" \
CONTAINER_NAME="$CONTAINER_NAME" \
CONTAINER_IP="$CONTAINER_IP" \
PROJECT_PATH="$PROJECT_PATH" \
SHARED_PATH="$SHARED_PATH" \
FORGE_AUTH_PATH="$FORGE_AUTH_PATH" \
FORGE_AUTH_MOUNT="$FORGE_AUTH_MOUNT" \
GIT_USER_NAME="$GIT_USER_NAME" \
GIT_USER_EMAIL="$GIT_USER_EMAIL" \
docker compose -f "$SCRIPT_DIR/docker-compose.yml" up -d --build

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Container:  claude-dev-$CONTAINER_NAME"
echo "  IP:         $CONTAINER_IP"
echo "  Project:    $PROJECT_PATH"
echo "  Forge:      $FORGE"
echo ""
echo "  Add to ~/.ssh/config on your Mac:"
echo ""
echo "    Host $CONTAINER_NAME"
echo "        HostName $CONTAINER_IP"
echo "        User coder"
echo "        StrictHostKeyChecking no"
echo ""
echo "  Then: ssh $CONTAINER_NAME"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
