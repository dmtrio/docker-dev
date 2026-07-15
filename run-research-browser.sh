#!/bin/bash
# run-research-browser.sh [brave|chrome]
# Launches a WATCHABLE agent browser (RFC 03 research profile) and bridges
# it for dev containers on localhost:8814.
#
# - Dedicated browser instance with its OWN profile dir — none of your
#   cookies, sessions, or extensions. Windows appear on your desktop so you
#   can watch (and physically interrupt) everything the agent does.
# - CDP debug port binds localhost only; the bridge requires X-API-Key.
# - Container side: profile 'research' grants port 8814.
#
# Default browser: Brave if installed, else Chrome. Run in tmux/launchd.

set -e

BRAVE="/Applications/Brave Browser.app"
CHROME="/Applications/Google Chrome.app"

case "${1:-auto}" in
    brave)  APP="$BRAVE" ;;
    chrome) APP="$CHROME" ;;
    auto)   if [ -d "$BRAVE" ]; then APP="$BRAVE"; else APP="$CHROME"; fi ;;
    *) echo "Usage: $0 [brave|chrome]"; exit 1 ;;
esac
[ -d "$APP" ] || { echo "ERROR: browser not found at $APP"; exit 1; }

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"
PROFILE_DIR="$BASE_PATH/research-browser"
CDP_PORT=9222
BRIDGE_PORT=8814

KEY_FILE="$BASE_PATH/secrets/research-browser.key"
if [ ! -s "$KEY_FILE" ]; then
    mkdir -p "$(dirname "$KEY_FILE")"
    openssl rand -hex 24 > "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    echo "Generated new bridge key at $KEY_FILE"
fi

# Start the browser if its CDP port isn't already up (idempotent).
# open -n detaches via LaunchServices so the browser outlives this script's
# shell (a directly-exec'd child dies with it).
if ! curl -s -m 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null; then
    echo "Launching $(basename "$APP" .app) with isolated profile $PROFILE_DIR"
    mkdir -p "$PROFILE_DIR"
    open -n "$APP" --args \
        --user-data-dir="$PROFILE_DIR" \
        --remote-debugging-port=$CDP_PORT \
        --no-first-run \
        --no-default-browser-check
    for i in $(seq 1 20); do
        curl -s -m 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null && break
        sleep 1
    done
    curl -s -m 2 "http://127.0.0.1:$CDP_PORT/json/version" >/dev/null \
        || { echo "ERROR: browser CDP port never came up"; exit 1; }
fi

echo "Bridging chrome-devtools-mcp on 127.0.0.1:$BRIDGE_PORT (X-API-Key required)"
exec npx -y mcp-proxy \
    --host 127.0.0.1 \
    --port $BRIDGE_PORT \
    --server stream \
    --apiKey "$(cat "$KEY_FILE")" \
    -- npx -y chrome-devtools-mcp --browserUrl "http://127.0.0.1:$CDP_PORT"
