#!/bin/bash
# tests/plugins.test.sh — host-runnable checks for the plugin mechanism.
# Needs only yq + jq (no docker): validates every plugins/*.yml against the
# schema up.sh and the Dockerfile expect, and exercises the same extraction +
# merge expressions up.sh uses so a plugin that parses here wires correctly
# at up time. The docker build/up path itself is covered by the manual
# build-test against a throwaway manifest (see PLN/LOG - Baked-in Plugins).

# SC2015 (`A && pass || fail` is not if-else): intentional here — pass() is a
# bare echo and cannot fail, so the || arm only runs when the check fails.
# shellcheck disable=SC2015

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$SCRIPT_DIR"

command -v yq >/dev/null || { echo "SKIP: yq not installed"; exit 0; }
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

FAILURES=0
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✓ $1"; }

echo "── syntax"
bash -n up.sh   && pass "bash -n up.sh"   || fail "up.sh has syntax errors"

echo "── plugin files"
found=0
for f in plugins/*.yml; do
    [ -e "$f" ] || continue
    found=1
    name=$(basename "$f" .yml)

    printf '%s' "$name" | grep -qE '^[A-Za-z0-9_-]+$' \
        && pass "$name: name passes up.sh's charset check" \
        || fail "$name: name would be rejected by up.sh ([A-Za-z0-9_-] only)"

    install=$(yq -r '.install // ""' "$f")
    [ -n "$install" ] \
        && pass "$name: install block present" \
        || fail "$name: missing install: (Dockerfile bake would be a no-op)"

    [ "$(yq '.mcp | tag' "$f")" = "!!map" ] \
        && pass "$name: mcp is a map" \
        || fail "$name: mcp must be a map of server-name → config"

    bad=$(yq -o=json '.mcp // {}' "$f" | jq -r 'to_entries[] | select(.value.command == null or (.value.command | type != "string")) | .key')
    [ -z "$bad" ] \
        && pass "$name: every mcp server has a string command (stdio)" \
        || fail "$name: mcp server(s) missing string command: $bad"

    egress_tag=$(yq '.egress // [] | tag' "$f")
    [ "$egress_tag" = "!!seq" ] \
        && pass "$name: egress is a list" \
        || fail "$name: egress must be a list of domains"
done
[ "$found" = 1 ] || fail "no plugin files found under plugins/"

echo "── template"
[ "$(yq '.plugins | tag' containers/TEMPLATE.yml)" = "!!seq" ] \
    && pass "TEMPLATE.yml has a plugins: list" \
    || fail "TEMPLATE.yml is missing the plugins: [] key"

echo "── wiring simulation (same expressions as up.sh)"
# Host side: manifest read + per-plugin extraction. Uses serena as the fixture.
MANIFEST=$(mktemp); trap 'rm -f "$MANIFEST"' EXIT
printf 'plugins: [serena]\n' > "$MANIFEST"
PLUGINS=$(yq -r '(.plugins // []) | join(" ")' "$MANIFEST")
[ "$PLUGINS" = "serena" ] && pass "manifest plugins: list reads back" || fail "manifest read: got '$PLUGINS'"

EGRESS="api.example.com"   # pre-existing manifest egress must survive
PLUGIN_MCP_ENTRIES=""
for p in $PLUGINS; do
    for d in $(yq -r '(.egress // []) | join(" ")' "plugins/$p.yml"); do
        echo ",$EGRESS," | grep -q ",$d," || EGRESS="${EGRESS:+$EGRESS,}$d"
    done
    PLUGIN_MCP_ENTRIES="$PLUGIN_MCP_ENTRIES$(yq -o=json -I=0 '.mcp // {}' "plugins/$p.yml")
"
done
echo ",$EGRESS," | grep -q ",blob.core.windows.net," \
    && pass "serena egress folded into EGRESS" \
    || fail "EGRESS missing serena's domains: '$EGRESS'"
echo ",$EGRESS," | grep -q ",api.example.com," \
    && pass "pre-existing egress preserved" \
    || fail "plugin fold clobbered manifest egress: '$EGRESS'"

# In-container side: the jq slurp-add + additive mcpServers merge.
J='{"mcpServers":{"coding":{"type":"http","url":"http://host.docker.internal:8811/mcp"}}}'
PLUGINS_OBJ=$(printf "%s" "$PLUGIN_MCP_ENTRIES" | jq -s "add // {}")
J=$(echo "$J" | jq --argjson p "$PLUGINS_OBJ" ".mcpServers += \$p")
[ "$(echo "$J" | jq -r '.mcpServers.serena.command')" = "serena" ] \
    && pass ".mcp.json merge carries serena (command intact)" \
    || fail "merged .mcp.json missing serena: $J"
[ "$(echo "$J" | jq -r '.mcpServers.coding.type')" = "http" ] \
    && pass "merge is additive (existing servers preserved)" \
    || fail "merge clobbered existing mcpServers: $J"

# Name validation must reject path-escaping input (the up.sh hard-fail).
printf '%s' "../evil" | grep -qE '^[A-Za-z0-9_-]+$' \
    && fail "charset check accepted '../evil'" \
    || pass "charset check rejects path traversal"

echo "── dockerfile bake simulation"
# Same extraction the image build runs; execute under `bash -n` only (no
# network here) to prove the install block is valid shell.
for f in plugins/*.yml; do
    [ -e "$f" ] || continue
    yq -r '.install // ""' "$f" | bash -n \
        && pass "$(basename "$f" .yml): install block is valid bash" \
        || fail "$(basename "$f" .yml): install block fails bash -n"
done

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "all checks passed"
