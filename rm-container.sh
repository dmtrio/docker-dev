#!/bin/bash
# rm-container.sh — stop and remove an Agent dev container
# Usage:
#   ./rm-container.sh              # lists running containers
#   ./rm-container.sh <name>       # removes dev-agent-<name>

set -e

NAME="${1:-}"

# ── List ──────────────────────────────────────────────────────────────────────
if [ -z "$NAME" ] || [ "$NAME" = "list" ]; then
    echo ""
    echo "  Agent Dev Containers"
    echo "  ─────────────────────────────────────────────────────────"
    docker ps -a --filter "name=dev-agent-" \
        --format "  {{.Names}}\t{{.Status}}" 2>/dev/null || echo "  (none)"
    echo ""
    exit 0
fi

CONTAINER="dev-agent-$NAME"

if ! docker inspect "$CONTAINER" &>/dev/null; then
    echo "Error: container '$CONTAINER' not found"
    exit 1
fi

read -p "Remove $CONTAINER? [y/N] " confirm
if [[ ! "$confirm" =~ ^[Yy]$ ]]; then echo "Aborted."; exit 0; fi

docker stop "$CONTAINER" 2>/dev/null || true
docker rm "$CONTAINER"

echo "Removed $CONTAINER"
echo "Shared data (shared/claude, shared/gh, shared/gitea) is preserved on disk."
echo "Remove the Host entry from ~/.ssh/config manually if needed."
