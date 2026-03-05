#!/bin/bash
# list-containers.sh / rm-container.sh
# Usage:
#   ./list-containers.sh
#   ./rm-container.sh personal-site

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IP_REGISTRY="$SCRIPT_DIR/.ip-registry"
SSH_CONFIG="$HOME/.ssh/config"
CMD=$(basename "$0" .sh)

# ── list ──────────────────────────────────────────────────────────────────────
if [[ "$CMD" == "list-containers" ]] || [[ "$1" == "list" ]]; then
    echo ""
    echo "  Claude Dev Containers"
    echo "  ─────────────────────────────────────────────────────────"
    printf "  %-20s %-16s %s\n" "NAME" "IP" "PROJECT PATH"
    echo "  ─────────────────────────────────────────────────────────"

    if [ ! -s "$IP_REGISTRY" ]; then
        echo "  (none)"
    else
        while read -r name ip path; do
            STATUS=$(docker inspect --format='{{.State.Status}}' "claude-dev-$name" 2>/dev/null || echo "gone")
            printf "  %-20s %-16s %s  [%s]\n" "$name" "$ip" "$path" "$STATUS"
        done < "$IP_REGISTRY"
    fi
    echo ""
    exit 0
fi

# ── remove ────────────────────────────────────────────────────────────────────
NAME="${1:-}"
if [ -z "$NAME" ]; then
    echo "Usage: ./rm-container.sh <name>"
    echo "       ./list-containers.sh  (to see existing containers)"
    exit 1
fi

CONTAINER_DIR="$SCRIPT_DIR/instances/$NAME"

if [ ! -d "$CONTAINER_DIR" ]; then
    echo "Error: No container found with name '$NAME'"
    exit 1
fi

read -p "Remove claude-dev-$NAME and its per-container volumes? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 0
fi

# Stop and remove container + per-container volumes
cd "$CONTAINER_DIR"
docker compose --env-file .env down -v 2>/dev/null || true

# Remove instance directory
rm -rf "$CONTAINER_DIR"

# Remove from IP registry
sed -i "/^$NAME /d" "$IP_REGISTRY"

# Remove SSH config entry
sed -i "/^# claude-dev-$NAME$/,/^$/d" "$SSH_CONFIG"

echo "✓ Removed claude-dev-$NAME"
echo "  Note: Shared volumes (claude-auth, gh-auth, claude-vscode-server) are preserved."
