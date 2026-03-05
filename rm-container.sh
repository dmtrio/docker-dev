#!/bin/bash
# rm-container.sh — stop and remove a Agent dev container
# Usage:
#   ./rm-container.sh              # lists running containers
#   ./rm-container.sh <name>       # removes agent-dev-<name>

set -e

NAME="${1:-}"

# ── List ──────────────────────────────────────────────────────────────────────
if [ -z "$NAME" ] || [ "$NAME" = "list" ]; then
    echo ""
    echo "  Agent Dev Containers"
    echo "  ─────────────────────────────────────────────────────────"
    docker ps -a --filter "name=agent-dev-" \
        --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  (none)"
    echo ""
    exit 0
fi

CONTAINER="agent-dev-$NAME"

if ! docker inspect "$CONTAINER" &>/dev/null; then
    echo "Error: container '$CONTAINER' not found"
    exit 1
fi

read -p "Remove $CONTAINER? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi

docker stop "$CONTAINER" 2>/dev/null || true
docker rm "$CONTAINER"

echo "Removed $CONTAINER"
echo "Shared data (claude-auth, gh-auth, vscode-server) is preserved on disk."
echo "Remove the Host entry from ~/.ssh/config manually if needed."
