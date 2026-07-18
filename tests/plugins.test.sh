#!/bin/bash
# tests/plugins.test.sh — host-runnable checks for the plugin mechanism.
# Needs only yq + jq (no docker): validates every plugins/*.yml against the
# schema up.sh and the Dockerfile expect, exercises the host-side (yq)
# extraction up.sh runs, and pins the copied expressions to up.sh's actual
# text (drift guard) so an up.sh edit can't leave this suite green while the
# real wiring changes. The in-container wiring (JSON merges, codex TOML) is
# real Python — src/wire_plugins.py — unit-tested by
# tests/test_wire_plugins.py and run from here when python3 is available.
# The docker build/up path itself is covered by the manual build-test
# against a throwaway manifest (see PLN/LOG - Baked-in Plugins).

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
if command -v python3 >/dev/null; then
    python3 -m py_compile src/wire_plugins.py 2>/dev/null \
        && pass "py_compile src/wire_plugins.py" \
        || fail "src/wire_plugins.py has syntax errors"
fi

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

# The extraction contract wire_plugins.py consumes: each entry is ONE line
# of valid JSON, and up.sh's paste-join turns them into a JSON array (the
# exec payload shape). The merges themselves are unit-tested in Python.
printf '%s' "$PLUGIN_MCP_ENTRIES" | head -1 | jq -e 'has("serena")' >/dev/null \
    && pass "extracted entry is one-line JSON with the serena server" \
    || fail "extraction contract broken: '$PLUGIN_MCP_ENTRIES'"
JOINED=$(printf '%s' "$PLUGIN_MCP_ENTRIES" | paste -sd, -)
printf '[%s]' "$JOINED" | jq -e 'length == 1' >/dev/null \
    && pass "paste-join yields a valid JSON array (the exec payload shape)" \
    || fail "payload assembly would produce invalid JSON: [$JOINED]"

echo "── host-side mcp entry validation (mirrors up.sh's yq rows + checks)"
# Same row extraction up.sh runs per plugin: name, command type, extra keys
V_EXPR='(.mcp // {}) | to_entries[] | [.key, (.value.command | type), ([.value | keys | .[] | select(. != "command" and . != "args")] | join(","))] | @tsv'
ROWS=$(yq -r "$V_EXPR" plugins/serena.yml)
[ "$ROWS" = "$(printf 'serena\t!!str\t')" ] \
    && pass "serena row: valid name, string command, no extra fields" \
    || fail "validation rows for serena unexpected: '$ROWS'"
BADPLUG=$(mktemp)
printf 'install: x\nmcp:\n  bad.name:\n    command: 1\n    env: {A: b}\n' > "$BADPLUG"
ROW=$(yq -r "$V_EXPR" "$BADPLUG"); rm -f "$BADPLUG"
n=$(printf '%s' "$ROW" | cut -f1)
ctype=$(printf '%s' "$ROW" | cut -f2)
extra=$(printf '%s' "$ROW" | cut -f3)
printf '%s' "$n" | grep -qE "$NAME_RE" \
    && fail "server name with a dot ('$n') passed the charset check (breaks codex TOML keys)" \
    || pass "server name with a dot is rejected"
[ "$ctype" != "!!str" ] \
    && pass "non-string command is detected (got $ctype)" \
    || fail "non-string command slipped through"
[ -n "$extra" ] \
    && pass "unsupported field is detected (got: $extra)" \
    || fail "extra field env was not surfaced"
# Reserved names: same case pattern as up.sh
resv() { case "$1" in coding|proxyman|browser|obsidian-annotated) return 0;; *) return 1;; esac; }
resv browser \
    && pass "reserved generated-server name is detected" \
    || fail "reserved-name check missed 'browser'"
resv serena \
    && fail "reserved-name false positive on serena" \
    || pass "serena passes the reserved-name check"
# Cross-plugin duplicates: same literal-space-delimited membership test
PLUGIN_MCP_NAMES="serena other"
printf '%s' " $PLUGIN_MCP_NAMES " | grep -qF " serena " \
    && pass "duplicate server name across plugins is detected" \
    || fail "duplicate name membership test broken"

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
# The yq simulation above tests COPIES of up.sh's host-side extraction. These
# literal greps fail the suite the moment the original changes, forcing the
# mirror (and these assertions) to be updated together with up.sh. The
# in-container logic needs no drift guard anymore: the unit tests import the
# real wire_plugins.py, and the last two pins prove up.sh still execs it.
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
[A-Za-z0-9_-]+$
add_egress_domain
(.mcp // {}) | to_entries[] | [.key, (.value.command | type)
coding|proxyman|browser|obsidian-annotated
paste -sd, -
python3 /usr/local/lib/dev-agent/wire_plugins.py
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
grep -qF -- "COPY src/wire_plugins.py" Dockerfile \
    && pass "Dockerfile bakes src/wire_plugins.py into the image" \
    || fail "Dockerfile no longer bakes wire_plugins.py (up.sh execs it)"

echo "── python unit tests (src/wire_plugins.py)"
if command -v python3 >/dev/null; then
    python3 -m unittest discover -s tests >/dev/null 2>&1 \
        && pass "python3 -m unittest discover -s tests" \
        || fail "unit tests failed (run: python3 -m unittest discover -s tests -v)"
else
    echo "  (python3 not installed — skipped; the suite also runs in-container)"
fi

rm -f "$MANIFEST.scalar"
echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "all checks passed"
