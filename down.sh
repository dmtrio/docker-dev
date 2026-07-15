#!/bin/bash
# down.sh <name> [--purge] — stop and remove a container.
# Default keeps the workspace volume (code) — ./up.sh <name> restores the
# container around it. --purge also deletes the volume and derived keys;
# the manifest, secrets.env, and artifacts/<name>/ always survive.

set -e

NAME="$1"
[ -n "$NAME" ] || { echo "Usage: ./down.sh <name> [--purge]"; exit 1; }

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"

if [ "$2" = "--purge" ]; then
    docker compose -p "dev-agent-$NAME" down -v
    rm -rf "$BASE_PATH/keys/$NAME"
    echo "Purged dev-agent-$NAME (volume + derived keys). Kept: manifest, secrets.env, artifacts/$NAME/"
else
    docker compose -p "dev-agent-$NAME" down
    echo "Stopped dev-agent-$NAME (workspace volume kept — ./up.sh $NAME to restore)"
fi
