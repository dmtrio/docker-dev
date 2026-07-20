#!/bin/bash
# service.sh <name> [args...] — start a plugin's host-side service on this Mac.
#
# Some plugins are backed by a service that runs on the HOST, not in a
# container: the gateway (Playwright MCP), proxyman (traffic capture bridge),
# and browser (a watchable desktop browser). Each ships a run.sh in its plugin
# directory; this dispatcher starts it so you never need the path:
#
#   ./service.sh gateway          # execs plugins/gateway/run.sh
#   ./service.sh browser chrome   # extra args are forwarded to run.sh
#   ./service.sh                  # lists plugins that ship a host service
#
# Run each in its own tmux window (or wrap in a launchd plist for boot
# persistence) and leave it running; containers reach it via the port its
# plugin.yml declares.
#
# This is DELIBERATELY separate from ./up.sh: up.sh recreates a container
# (docker compose up --build), which would kill a running agent — starting a
# host service must never carry that risk, nor sit one typo away from it.
# service.sh never touches docker. It also does NOT source src/common.sh: it
# needs nothing from the dev-agent home, and keeping ./.env off the usage/list
# and error paths mirrors bin/allow-egress.sh. Each run.sh sources common.sh
# itself when it actually needs BASE_PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLUGINS_DIR="$SCRIPT_DIR/plugins"

list_services() {
    echo "Plugins with a host service (run.sh):"
    local found=0 r
    for r in "$PLUGINS_DIR"/*/run.sh; do
        [ -e "$r" ] || continue
        found=1
        printf '  %s\n' "$(basename "$(dirname "$r")")"
    done
    [ "$found" = 1 ] || echo "  (none)"
}

NAME="${1:-}"
if [ -z "$NAME" ]; then
    echo "Usage: ./service.sh <name> [args...]   (starts plugins/<name>/run.sh on this host)"
    list_services
    exit 1
fi
shift

if [ ! -d "$PLUGINS_DIR/$NAME" ]; then
    echo "Error: no plugin named '$NAME' (plugins/$NAME/ does not exist)."
    list_services
    exit 1
fi

RUN="$PLUGINS_DIR/$NAME/run.sh"
if [ ! -f "$RUN" ]; then
    echo "Error: plugin '$NAME' has no host service (no plugins/$NAME/run.sh)."
    echo "It's a container-side (serena) or remote (obsidian-annotated) plugin —"
    echo "nothing to start on the host."
    list_services
    exit 1
fi

exec bash "$RUN" "$@"
