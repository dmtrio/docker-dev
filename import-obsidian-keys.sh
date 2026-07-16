#!/bin/bash
# import-obsidian-keys.sh <container> [file]
# Imports per-agent Obsidian Annotated keys into ~/dev-agent/secrets.env.
# Default source: ~/dev-agent/secrets.obsidian.env
#
# Accepted line formats (one key per line, '#' comments ignored):
#   <agent>.key <value>          or  <agent>.key=<value>
#   <agent>.poll.key <value>     or  <agent>.poll.key=<value>
# Agent names: claude, codex, pi, gemini, cursor (mapped to cursor-agent).
#
# Mapping (dashes → underscores):
#   <agent>.key       → OBSIDIAN_KEY_<container>_<agent>
#   <agent>.poll.key  → OBSIDIAN_WATCH_KEY_<container>_<agent>
#
# Values are never printed. Existing vars are never overwritten. The source
# file is renamed to <file>.imported.bak — nothing is ever deleted.

set -e

CONTAINER="$1"
[ -n "$CONTAINER" ] || { echo "Usage: ./import-obsidian-keys.sh <container> [file]"; exit 1; }

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"
SRC="${2:-$BASE_PATH/secrets.obsidian.env}"
SECRETS_FILE="$BASE_PATH/secrets.env"

[ -f "$SRC" ] || { echo "Error: $SRC not found"; exit 1; }
[ -f "$SECRETS_FILE" ] || { mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; }

C=$(echo "$CONTAINER" | tr '-' '_')

while IFS= read -r line || [ -n "$line" ]; do
    # strip comments and surrounding whitespace
    line=$(echo "$line" | sed 's/#.*//;s/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue

    # split on first '=' or first run of whitespace
    case "$line" in
        *=*) name="${line%%=*}"; value="${line#*=}" ;;
        *)   name="${line%%[[:space:]]*}"; value="${line#*[[:space:]]}" ;;
    esac
    name=$(echo "$name" | sed 's/[[:space:]]*$//')
    value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$value" ] && { echo "  skip  $name (no value)"; continue; }

    # agent + tier from the name
    case "$name" in
        *.poll.key) agent="${name%.poll.key}"; prefix="OBSIDIAN_WATCH_KEY" ;;
        *.key)      agent="${name%.key}";      prefix="OBSIDIAN_KEY" ;;
        *) echo "  skip  $name (expected <agent>.key or <agent>.poll.key)"; continue ;;
    esac

    # manifest/agent binary naming: cursor → cursor-agent
    [ "$agent" = "cursor" ] && agent="cursor-agent"
    A=$(echo "$agent" | tr '-' '_')
    var="${prefix}_${C}_${A}"

    if grep -q "^$var=" "$SECRETS_FILE"; then
        echo "  skip  $name → $var (already set — not overwritten)"
        continue
    fi
    printf '%s=%s\n' "$var" "$value" >> "$SECRETS_FILE"
    echo "  moved $name → $var"
done < "$SRC"

chmod 600 "$SECRETS_FILE"
mv "$SRC" "$SRC.imported.bak"
chmod 600 "$SRC.imported.bak"
echo ""
echo "Done. Source renamed to $SRC.imported.bak (delete when confident)."
echo "Apply to the container with: ./up.sh $CONTAINER"
