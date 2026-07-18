#!/bin/bash
# tests/plugins.test.sh — host-runnable checks for the plugin mechanism.
# The validation and wiring LOGIC is real Python now (src/manifest.py,
# src/wire_plugins.py — unit-tested by tests/test_*.py, run below), so this
# suite is down to what only a shell can check: every SHIPPED plugin file
# passes the real validator, the TEMPLATE manifest derives cleanly, the
# derive → build-payload chain holds together, the Dockerfile bake contract
# stands, and up.sh still calls the modules (pin greps). The docker build/up
# path itself is covered by the manual build-test against a throwaway
# manifest (see PLN/LOG - Baked-in Plugins).

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
bash -n up.sh && pass "bash -n up.sh" || fail "up.sh has syntax errors"

if ! command -v python3 >/dev/null; then
    # python3 is a hard up.sh requirement — a green run must never mean
    # "the validation/wiring logic went untested".
    fail "python3 not installed — manifest/wiring tests did NOT run (up.sh requires python3)"
else

echo "── shipped plugin files (validated through the real src/manifest.py)"
found=0
for f in plugins/*.yml; do
    [ -e "$f" ] || continue
    found=1
    name=$(basename "$f" .yml)
    # Same conversion up.sh feeds --derive, with a manifest enabling just
    # this plugin: the real validator applies every rule (name charset, mcp
    # schema, reserved names, egress hostnames) — no mirrored copies.
    OUT=$(
        {
            printf '{"plugins": ["%s"]}\n' "$name"
            printf '%s\t' "$name"
            yq -o=json -I=0 "$f"
        } | python3 src/manifest.py --derive 2>&1
    ) \
        && pass "$name: passes manifest.py validation" \
        || fail "$name: rejected by manifest.py: $(printf '%s' "$OUT" | head -3)"

    install=$(yq -r '.install // ""' "$f")
    [ -n "$install" ] && [ "$install" != "null" ] \
        && pass "$name: install block present" \
        || fail "$name: missing install: (yq -e in the Dockerfile fails the build)"
done
[ "$found" = 1 ] || fail "no plugin files found under plugins/"

echo "── template"
[ "$(yq '.plugins | tag' containers/TEMPLATE.yml)" = "!!seq" ] \
    && pass "TEMPLATE.yml has a plugins: list" \
    || fail "TEMPLATE.yml is missing the plugins: [] key"
# TEMPLATE must pass the real validator end-to-end
{
    yq -o=json -I=0 containers/TEMPLATE.yml
    for f in plugins/*.yml; do
        [ -e "$f" ] || continue
        printf '%s\t' "$(basename "$f" .yml)"
        yq -o=json -I=0 "$f"
    done
} | python3 src/manifest.py --derive >/dev/null \
    && pass "TEMPLATE.yml passes manifest.py --derive" \
    || fail "TEMPLATE.yml rejected by manifest.py"

echo "── derive → build-payload chain (both host halves, real serena file)"
DERIVED=$(
    {
        printf '{"plugins": ["serena"], "capabilities": {"gateway": true}}\n'
        printf 'serena\t'; yq -o=json -I=0 plugins/serena.yml
    } | python3 src/manifest.py --derive
) || fail "--derive exited non-zero on a serena manifest"
PLUGIN_MCP_ENTRIES=$(eval "$DERIVED"; printf '%s' "$PLUGIN_MCP_ENTRIES")
PAYLOAD=$(WIRE_CURSOR=true WIRE_GEMINI=yes WIRE_PI=false WIRE_CODEX=true \
    CAP_GATEWAY=true CAP_PROXYMAN=1 CAP_BROWSER=false CAP_OBSIDIAN=true \
    PLUGIN_MCP_ENTRIES="$PLUGIN_MCP_ENTRIES" \
    IDENTITY_AGENTS="cursor-agent:IDENTITY_KEY_0 codex:" \
    python3 src/wire_plugins.py --build-payload) \
    || fail "--build-payload exited non-zero"
printf '%s' "$PAYLOAD" | jq -e '
    .wire == {cursor: true, gemini: false, pi: false, codex: true}
    and .capabilities == {gateway: true, proxyman: false, browser: false, obsidian: true}
    and (.plugin_mcp_entries[0] | has("serena"))
    and .identities == [{agent: "cursor-agent", key_env: "IDENTITY_KEY_0"}, {agent: "codex", key_env: ""}]' >/dev/null \
    && pass "derive → build-payload yields the wiring payload (strict booleans: yes/1 stay off)" \
    || fail "payload chain output wrong: $PAYLOAD"

echo "── python unit tests (src/manifest.py + src/wire_plugins.py)"
UNIT_OUT=$(python3 -m unittest discover -s tests 2>&1) \
    && pass "python3 -m unittest discover -s tests" \
    || { fail "unit tests failed:"; printf '%s\n' "$UNIT_OUT" | tail -30; }

fi  # command -v python3

echo "── up.sh ↔ module contract pins"
# The modules are unit-tested; these greps only prove up.sh still CALLS them
# (and converts YAML with yq) — the last mirror-drift risk left in bash.
while IFS= read -r expr; do
    [ -n "$expr" ] || continue
    grep -qF -- "$expr" up.sh \
        && pass "up.sh still contains: $expr" \
        || fail "up.sh no longer contains (update this suite!): $expr"
done <<'DRIFT'
yq -o=json -I=0 "$MANIFEST"
src/manifest.py" --derive
--build-payload
"$PYTHON3" "$SCRIPT_DIR/src/wire_plugins.py"
python3 /usr/local/lib/dev-agent/wire_plugins.py
DRIFT

echo "── dockerfile bake"
for f in plugins/*.yml; do
    [ -e "$f" ] || continue
    yq -r '.install // ""' "$f" | bash -n \
        && pass "$(basename "$f" .yml): install block is valid bash" \
        || fail "$(basename "$f" .yml): install block fails bash -n"
done
grep -qF -- "yq -e -r '.install'" Dockerfile \
    && pass "Dockerfile bake uses yq -e (missing install: fails the build)" \
    || fail "Dockerfile bake no longer hard-fails on a missing install: key"
grep -qF -- "COPY src/wire_plugins.py" Dockerfile \
    && pass "Dockerfile bakes src/wire_plugins.py into the image" \
    || fail "Dockerfile no longer bakes wire_plugins.py (up.sh execs it)"

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "all checks passed"
