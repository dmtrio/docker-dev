#!/bin/bash
# migrate-secrets.sh [source-dir]
# Moves secrets stored as files/folders into ~/dev-agent/secrets.env.
# Default source: ~/dev-agent/shared/secrets/
#
# Naming:
#   gateway-coding.token                 → MCP_GATEWAY_TOKEN
#   proxyman-bridge.key                  → PROXYMAN_BRIDGE_KEY
#   research-browser.key                 → RESEARCH_BROWSER_KEY
#   github.token                         → GH_TOKEN
#   obsidian/<container>/<agent>.key     → OBSIDIAN_KEY_<container>_<agent>
#   obsidian/<container>/<agent>.poll.key→ OBSIDIAN_WATCH_KEY_<container>_<agent>
#   anything else                        → path uppercased, non-alnum → _
#
# Privacy: values are never printed, logged, or echoed — only variable
# names and source paths appear in output. Existing variables in
# secrets.env are never overwritten (skipped with a notice).
# After migration the source dir is renamed to <dir>.migrated.bak —
# delete it yourself once you've confirmed secrets.env works.

set -e

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"
SRC="${1:-$BASE_PATH/shared/secrets}"
SECRETS_FILE="$BASE_PATH/secrets.env"

[ -d "$SRC" ] || { echo "Nothing to migrate: $SRC does not exist"; exit 0; }
[ -f "$SECRETS_FILE" ] || { mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; }

sanitize() { echo "$1" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_' | sed 's/_*$//;s/^_*//;s/__*/_/g'; }

var_for() {
    # $1 = path relative to SRC
    case "$1" in
        gateway-coding.token)   echo "MCP_GATEWAY_TOKEN" ;;
        proxyman-bridge.key)    echo "PROXYMAN_BRIDGE_KEY" ;;
        research-browser.key)   echo "RESEARCH_BROWSER_KEY" ;;
        github.token)           echo "GH_TOKEN" ;;
        obsidian/*/*.poll.key)
            c=$(basename "$(dirname "$1")"); a=$(basename "$1" .poll.key)
            echo "OBSIDIAN_WATCH_KEY_$(echo "$c" | tr '-' '_')_$(echo "$a" | tr '-' '_')" ;;
        obsidian/*/*.key)
            c=$(basename "$(dirname "$1")"); a=$(basename "$1" .key)
            echo "OBSIDIAN_KEY_$(echo "$c" | tr '-' '_')_$(echo "$a" | tr '-' '_')" ;;
        *)
            rel="$1"
            rel="${rel%.key}"; rel="${rel%.token}"; rel="${rel%.env}"; rel="${rel%.txt}"
            sanitize "$rel" ;;
    esac
}

MIGRATED=0
SKIPPED=0

find "$SRC" -type f ! -name '.DS_Store' | while read -r f; do
    rel="${f#$SRC/}"
    var=$(var_for "$rel")

    if grep -q "^$var=" "$SECRETS_FILE"; then
        echo "  skip  $rel → $var (already in secrets.env — not overwritten)"
        continue
    fi

    # Read the value without ever displaying it; strip a trailing newline.
    value=$(cat "$f")
    if [ -z "$value" ]; then
        echo "  skip  $rel → $var (file is empty)"
        continue
    fi
    printf '%s=%s\n' "$var" "$value" >> "$SECRETS_FILE"
    echo "  moved $rel → $var"
done

chmod 600 "$SECRETS_FILE"

BAK="$SRC.migrated.bak"
mv "$SRC" "$BAK"
echo ""
echo "Done. Source renamed to $BAK — delete it once you've verified:"
echo "  grep -c = $SECRETS_FILE   (counts entries, shows no values)"
echo "  rm -rf '$BAK'"
