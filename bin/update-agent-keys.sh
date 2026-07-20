#!/bin/bash
# update-agent-keys.sh — TEMPORARY override of an MCP credential for one
# agent in one container. Takes effect the NEXT time that agent starts (the
# shims read ~/.agent-keys at process launch) — no container restart needed.
#
# WARNING: ~/dev-agent/keys/<container>/ is DERIVED output — the next
# ./up.sh <container> wipes and recomposes it from ~/dev-agent/secrets.env
# and the manifest. Make DURABLE changes there instead; use this script only
# for quick between-runs experiments.
#
# Usage:
#   ./bin/update-agent-keys.sh <container> <agent|common> <VAR> [value]
#   ./bin/update-agent-keys.sh <container>                       # list keys
#
# Examples:
#   ./bin/update-agent-keys.sh mysite claude OBSIDIAN_ANNOTATED_KEY   # prompts
#   ./bin/update-agent-keys.sh mysite pi OBSIDIAN_ANNOTATED_KEY      # pi's own key
#   ./bin/update-agent-keys.sh mysite common MCP_GATEWAY_TOKEN       # all agents
#
# Agents: claude, pi, gemini, cursor-agent (or 'common' for shared
# capability tokens like the gateway/bridge secrets).

set -e

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../src/common.sh"   # sets BASE_PATH
CONTAINER="$1"
AGENT="$2"
VAR="$3"
VALUE="$4"

if [ -z "$CONTAINER" ]; then
    echo "Usage: $0 <container> <agent|common> <VAR> [value]"
    exit 1
fi

KEYS_PATH="$BASE_PATH/keys/$CONTAINER"
if [ ! -d "$KEYS_PATH" ]; then
    echo "Error: no keys dir at $KEYS_PATH (container never applied via ./up.sh?)"
    exit 1
fi

# List mode
if [ -z "$AGENT" ]; then
    echo "Key files for $CONTAINER (values hidden):"
    for f in "$KEYS_PATH"/*.env; do
        [ -f "$f" ] || continue
        echo "  $(basename "$f" .env):"
        cut -d= -f1 "$f" | sed 's/^/    /'
    done
    exit 0
fi

case "$AGENT" in
    claude|pi|gemini|cursor-agent|codex|common) ;;
    *) echo "Error: agent must be one of: claude, pi, gemini, cursor-agent, codex, common"; exit 1 ;;
esac

if [ -z "$VAR" ]; then
    echo "Error: VAR required (e.g. OBSIDIAN_ANNOTATED_KEY)"
    exit 1
fi

if [ -z "$VALUE" ]; then
    printf "Value for %s (%s/%s, input hidden): " "$VAR" "$CONTAINER" "$AGENT"
    read -s VALUE
    echo ""
fi

FILE="$KEYS_PATH/$AGENT.env"
touch "$FILE"
chmod 600 "$FILE"

TMP="$FILE.tmp.$$"
grep -v "^$VAR=" "$FILE" > "$TMP" || true
if [ -n "$VALUE" ]; then
    echo "$VAR=$VALUE" >> "$TMP"
fi
mv "$TMP" "$FILE"
chmod 600 "$FILE"

if [ -n "$VALUE" ]; then
    echo "✓ $VAR set for $CONTAINER/$AGENT — applies on that agent's next start"
else
    echo "✓ $VAR removed for $CONTAINER/$AGENT"
fi
