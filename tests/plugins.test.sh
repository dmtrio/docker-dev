#!/bin/bash
# tests/plugins.test.sh — host-runnable checks for the plugin mechanism.
# Needs only yq + jq (no docker): validates every plugins/*.yml against the
# schema up.sh and the Dockerfile expect, exercises the same extraction +
# merge logic up.sh uses, and pins the copied expressions to up.sh's actual
# text (drift guard) so an up.sh edit can't leave this suite green while the
# real wiring changes. The docker build/up path itself is covered by the
# manual build-test against a throwaway manifest (see PLN/LOG - Baked-in
# Plugins).

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

# Same rules as up.sh (the drift guard below pins them to up.sh's text)
NAME_RE='^[A-Za-z0-9_-]+$'
DOMAIN_RE='^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$'

echo "── syntax"
bash -n up.sh   && pass "bash -n up.sh"   || fail "up.sh has syntax errors"

echo "── plugin files"
found=0
for f in plugins/*.yml; do
    [ -e "$f" ] || continue
    found=1
    name=$(basename "$f" .yml)

    printf '%s' "$name" | grep -qE "$NAME_RE" \
        && pass "$name: name passes up.sh's charset check" \
        || fail "$name: name would be rejected by up.sh ([A-Za-z0-9_-] only)"

    install=$(yq -r '.install // ""' "$f")
    [ -n "$install" ] && [ "$install" != "null" ] \
        && pass "$name: install block present" \
        || fail "$name: missing install: (yq -e in the Dockerfile fails the build)"

    # mcp may be absent (egress/install-only plugin merges as {}), but when
    # present it must be a map of stdio servers. Guard every jq/yq that can
    # error on malformed input with || so one bad file records a failure
    # instead of killing the suite via set -e.
    mcp_tag=$(yq '.mcp // {} | tag' "$f")
    if [ "$mcp_tag" = "!!map" ]; then
        bad=$(yq -o=json '.mcp // {}' "$f" \
              | jq -r 'to_entries[] | select(.value.command == null or (.value.command | type != "string")) | .key' 2>/dev/null) \
              || bad="(unparseable mcp block)"
        [ -z "$bad" ] \
            && pass "$name: mcp servers all have a string command (stdio)" \
            || fail "$name: mcp server(s) missing string command: $bad"
    else
        fail "$name: mcp must be a map when present (got $mcp_tag)"
    fi

    egress_tag=$(yq '.egress // [] | tag' "$f")
    if [ "$egress_tag" = "!!seq" ]; then
        bad_dom=""
        for d in $(yq -r '(.egress // []) | join(" ")' "$f"); do
            printf '%s' "$d" | grep -qE "$DOMAIN_RE" || bad_dom="$bad_dom $d"
        done
        [ -z "$bad_dom" ] \
            && pass "$name: egress entries are bare hostnames" \
            || fail "$name: egress entries up.sh would reject:$bad_dom"
    else
        fail "$name: egress must be a list of domains"
    fi
done
[ "$found" = 1 ] || fail "no plugin files found under plugins/"

echo "── template"
[ "$(yq '.plugins | tag' containers/TEMPLATE.yml)" = "!!seq" ] \
    && pass "TEMPLATE.yml has a plugins: list" \
    || fail "TEMPLATE.yml is missing the plugins: [] key"

echo "── wiring simulation (logic mirrored from up.sh; see drift guard)"
MANIFEST=$(mktemp); trap 'rm -f "$MANIFEST"' EXIT
printf 'plugins: [serena]\n' > "$MANIFEST"

# Scalar plugins: must be caught by the tag check, not die inside yq join()
printf 'plugins: serena\n' > "$MANIFEST.scalar" 2>/dev/null || true
[ "$(yq '.plugins // [] | tag' "$MANIFEST")" = "!!seq" ] \
    && pass "list-form plugins: passes the tag check" \
    || fail "tag check rejects a valid plugins: list"
echo 'plugins: serena' > "$MANIFEST"
[ "$(yq '.plugins // [] | tag' "$MANIFEST")" != "!!seq" ] \
    && pass "scalar plugins: is caught by the tag check (named error, not raw yq)" \
    || fail "tag check misses the scalar plugins: typo"
printf 'plugins: [serena]\n' > "$MANIFEST"

PLUGINS=$(yq -r '(.plugins // []) | join(" ")' "$MANIFEST")
[ "$PLUGINS" = "serena" ] && pass "manifest plugins: list reads back" || fail "manifest read: got '$PLUGINS'"

# Same helper as up.sh: literal match (-F), append if absent
EGRESS="api.example.com"
add_egress_domain() {
    echo ",$EGRESS," | grep -qF ",$1," || EGRESS="${EGRESS:+$EGRESS,}$1"
}
PLUGIN_MCP_ENTRIES=""
for p in $PLUGINS; do
    for d in $(yq -r '(.egress // []) | join(" ")' "plugins/$p.yml"); do
        add_egress_domain "$d"
    done
    PLUGIN_MCP_ENTRIES="$PLUGIN_MCP_ENTRIES$(yq -o=json -I=0 '.mcp // {}' "plugins/$p.yml")
"
done
echo ",$EGRESS," | grep -qF ",blob.core.windows.net," \
    && pass "serena egress folded into EGRESS" \
    || fail "EGRESS missing serena's domains: '$EGRESS'"
echo ",$EGRESS," | grep -qF ",api.example.com," \
    && pass "pre-existing egress preserved" \
    || fail "plugin fold clobbered manifest egress: '$EGRESS'"

# Literal dedup: a lookalike must NOT suppress the real domain (regex-dot bug)
EGRESS="api-foo.com"
add_egress_domain "api.foo.com"
[ "$EGRESS" = "api-foo.com,api.foo.com" ] \
    && pass "dedup is literal — api-foo.com does not swallow api.foo.com" \
    || fail "dedup treated the domain as a regex: '$EGRESS'"

# In-container side: duplicate/collision detection, then the additive merge
J='{"mcpServers":{"coding":{"type":"http","url":"http://host.docker.internal:8811/mcp"}}}'
DUP=$(printf "%s" "$PLUGIN_MCP_ENTRIES" | jq -rs "[.[] | keys[]] | group_by(.) | map(select(length > 1) | .[0]) | join(\", \")")
[ -z "$DUP" ] \
    && pass "no duplicate server names across enabled plugins" \
    || fail "cross-plugin duplicate detection false positive: $DUP"
DUP=$(printf '%s\n%s\n' '{"serena":{"command":"a"}}' '{"serena":{"command":"b"}}' \
      | jq -rs "[.[] | keys[]] | group_by(.) | map(select(length > 1) | .[0]) | join(\", \")")
[ "$DUP" = "serena" ] \
    && pass "cross-plugin duplicate is detected" \
    || fail "cross-plugin duplicate NOT detected"

PLUGINS_OBJ=$(printf "%s" "$PLUGIN_MCP_ENTRIES" | jq -s "add // {}")
CLASH=$(echo "$J" | jq -r --argjson p "$PLUGINS_OBJ" "(.mcpServers | keys) as \$k | \$p | keys | map(select(. as \$n | \$k | index(\$n))) | join(\", \")")
[ -z "$CLASH" ] \
    && pass "no collision between plugin and generated server names" \
    || fail "collision detection false positive: $CLASH"
CLASH=$(echo "$J" | jq -r --argjson p '{"coding":{"command":"evil"}}' "(.mcpServers | keys) as \$k | \$p | keys | map(select(. as \$n | \$k | index(\$n))) | join(\", \")")
[ "$CLASH" = "coding" ] \
    && pass "plugin shadowing a generated server IS detected" \
    || fail "collision with generated server NOT detected"

J=$(echo "$J" | jq --argjson p "$PLUGINS_OBJ" ".mcpServers += \$p")
[ "$(echo "$J" | jq -r '.mcpServers.serena.command')" = "bash" ] \
    && pass ".mcp.json merge carries serena (command intact)" \
    || fail "merged .mcp.json missing serena: $J"
[ "$(echo "$J" | jq -r '.mcpServers.coding.type')" = "http" ] \
    && pass "merge is additive (existing servers preserved)" \
    || fail "merge clobbered existing mcpServers: $J"

echo "── per-agent wiring simulation (reserved names, JSON merge, codex TOML)"
# Reserved names: plugin servers are wired into every installed agent's
# config with a last-wins merge, so generated-server names are rejected
# outright (in-container check in up.sh; same expression here).
RESV=$(printf '%s\n' '{"browser":{"command":"x"},"mine":{"command":"y"}}' \
      | jq -rs '[.[] | keys[]] | map(select(. as $n | ["coding","proxyman","browser","obsidian-annotated"] | index($n))) | unique | join(", ")')
[ "$RESV" = "browser" ] \
    && pass "reserved generated-server name is detected" \
    || fail "reserved-name check missed 'browser': got '$RESV'"
RESV=$(printf "%s" "$PLUGIN_MCP_ENTRIES" \
      | jq -rs '[.[] | keys[]] | map(select(. as $n | ["coding","proxyman","browser","obsidian-annotated"] | index($n))) | unique | join(", ")')
[ -z "$RESV" ] \
    && pass "shipped plugins pass the reserved-name check" \
    || fail "reserved-name false positive: $RESV"

# cursor/gemini/pi: same merge the in-container JSON_MERGE script runs —
# additive into .mcpServers, existing entries (identity servers) preserved,
# idempotent on rerun (last-wins refresh of the plugin's own entry).
AGENT_CFG='{"mcpServers":{"obsidian-annotated":{"url":"https://x/mcp"}}}'
P=$(printf "%s" "$PLUGIN_MCP_ENTRIES" | jq -s "add // {}")
MERGED=$(echo "$AGENT_CFG" | jq --argjson p "$P" ".mcpServers = ((.mcpServers // {}) + \$p)")
[ "$(echo "$MERGED" | jq -r '.mcpServers.serena.command')" = "bash" ] \
    && pass "agent config merge carries serena" \
    || fail "agent config merge missing serena: $MERGED"
[ "$(echo "$MERGED" | jq -r '.mcpServers["obsidian-annotated"].url')" = "https://x/mcp" ] \
    && pass "agent config merge preserves identity servers" \
    || fail "agent config merge clobbered obsidian: $MERGED"
MERGED2=$(echo "$MERGED" | jq --argjson p "$P" ".mcpServers = ((.mcpServers // {}) + \$p)")
[ "$MERGED" = "$MERGED2" ] \
    && pass "agent config merge is idempotent" \
    || fail "agent config merge is not idempotent"

# codex: stdio entries render to a [mcp_servers.*] TOML block; @json emits
# TOML basic strings/arrays (JSON string+array escapes are a TOML subset).
TOML=$(printf "%s" "$PLUGIN_MCP_ENTRIES" | jq -rs "add // {} | to_entries[] | \"[mcp_servers.\(.key)]\ncommand = \(.value.command | @json)\nargs = \(.value.args // [] | @json)\n\"")
echo "$TOML" | grep -qF "[mcp_servers.serena]" \
    && pass "codex TOML block has the serena table header" \
    || fail "codex TOML missing table header: $TOML"
echo "$TOML" | grep -qF 'command = "bash"' \
    && pass "codex TOML renders the command" \
    || fail "codex TOML command wrong: $TOML"
# The managed-block replace: sed range-delete removes ONLY a previous block
PREV=$(printf '%s\n' "keep = 1" "# >>> dev-agent plugin MCP (managed) >>>" "[mcp_servers.old]" "# <<< dev-agent plugin MCP <<<" "also_keep = 2")
STRIPPED=$(echo "$PREV" | sed "/^# >>> dev-agent plugin MCP/,/^# <<< dev-agent plugin MCP/d")
[ "$STRIPPED" = "$(printf 'keep = 1\nalso_keep = 2')" ] \
    && pass "codex managed-block strip keeps surrounding config" \
    || fail "codex managed-block strip broken: '$STRIPPED'"

# Name validation must reject path-escaping input (the up.sh hard-fail).
printf '%s' "../evil" | grep -qE "$NAME_RE" \
    && fail "charset check accepted '../evil'" \
    || pass "charset check rejects path traversal"

# Domain validation must reject non-hostnames before they reach dnsmasq.
for bad in "https://x.com" "x.com/path" "*.foo.com" "foo" "a b.com"; do
    printf '%s' "$bad" | grep -qE "$DOMAIN_RE" \
        && fail "domain check accepted '$bad'" \
        || pass "domain check rejects '$bad'"
done

echo "── drift guard (expressions this suite mirrors must exist in up.sh)"
# The wiring simulation above tests COPIES of up.sh's logic. These literal
# greps fail the suite the moment the original changes, forcing the mirror
# (and these assertions) to be updated together with up.sh.
while IFS= read -r expr; do
    [ -n "$expr" ] || continue
    grep -qF -- "$expr" up.sh \
        && pass "up.sh still contains: $expr" \
        || fail "up.sh no longer contains (update this suite!): $expr"
done <<'DRIFT'
(.plugins // []) | join(" ")
.plugins // [] | tag
(.egress // []) | join(" ")
yq -o=json -I=0 '.mcp // {}'
jq -s "add // {}"
.mcpServers += \$p
[A-Za-z0-9_-]+$
add_egress_domain
group_by(.) | map(select(length > 1)
map(select(. as \$n | [\"coding\",\"proxyman\",\"browser\",\"obsidian-annotated\"] | index(\$n))) | unique
.mcpServers = ((.mcpServers // {}) + \$p)
[mcp_servers.\(.key)]
/^# >>> dev-agent plugin MCP/,/^# <<< dev-agent plugin MCP/d
DRIFT
grep -qF -- "$DOMAIN_RE" up.sh \
    && pass "up.sh still contains the domain validation regex" \
    || fail "up.sh's domain regex changed (update this suite!)"

echo "── dockerfile bake simulation"
# Same extraction the image build runs; execute under `bash -n` only (no
# network here) to prove the install block is valid shell.
for f in plugins/*.yml; do
    [ -e "$f" ] || continue
    yq -r '.install // ""' "$f" | bash -n \
        && pass "$(basename "$f" .yml): install block is valid bash" \
        || fail "$(basename "$f" .yml): install block fails bash -n"
done
grep -qF -- "yq -e -r '.install'" Dockerfile \
    && pass "Dockerfile bake uses yq -e (missing install: fails the build)" \
    || fail "Dockerfile bake no longer hard-fails on a missing install: key"

rm -f "$MANIFEST.scalar"
echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "all checks passed"
