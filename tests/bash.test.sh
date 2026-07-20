#!/bin/bash
# tests/bash.test.sh — unit tests for the host-side bash that holds real logic.
# Hand-rolled execute-and-assert (same style as plugins.test.sh; no bats
# dependency). Covers:
#   - src/compose-keys.sh   key-file composition (sourced by up.sh)
#   - common.sh             BASE_PATH resolution (default / env / ./.env / broken)
#   - allow-egress.sh       arg parsing + strict domain validation
#   - update-agent-keys.sh  per-agent key edits (set / remove / common / list)
#   - run-*.sh              host launchers' token generate-if-missing + persist
# Out of scope: container-internal scripts (init-firewall.sh, entrypoint.sh,
# mosh-server-wrapper.sh, tmux-*) — they run in a built container, and the
# pure docker orchestration in up.sh (a test would only assert "docker ran").
set -u

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
FAILURES=0
pass() { echo "  ✓ $1"; }
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1"; printf '     expected: [%s]\n     got:      [%s]\n' "$2" "$3"; fi; }
assert_rc() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected rc $2, got $3)"; fi; }
assert_contains() { case "$2" in *"$3"*) pass "$1" ;; *) fail "$1"; printf '     missing [%s] in: [%s]\n' "$3" "$2" ;; esac; }
assert_absent() { case "$2" in *"$3"*) fail "$1"; printf '     unexpected [%s] in: [%s]\n' "$3" "$2" ;; *) pass "$1" ;; esac; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# ────────────────────────────────────────────────────────────────────────────
echo "── src/compose-keys.sh ──"
# shellcheck disable=SC1091
. "$REPO/src/compose-keys.sh"   # defines warn_missing + compose_keys, no side effects
SHIM="claude pi gemini cursor-agent codex"

d="$WORK/ck1"; mkdir -p "$d"; chmod 700 "$d"
MCP_GATEWAY_TOKEN=gwval GH_TOKEN=ghval SRC_C=ckey SRC_P=pkey
PES=$(printf 'MCP_GATEWAY_TOKEN\tMCP_GATEWAY_TOKEN\tgateway (run run-gateway-coding.sh once)\n')
AS=$(printf 'claude\tOBSIDIAN_ANNOTATED_KEY\tSRC_C\npi\tANNOTATED_WATCH_KEY\tSRC_P\n')
compose_keys "$d" "$SHIM" "$PES" "$AS" >/dev/null

assert_eq "claude.env = shared + its agent-scoped key" \
    $'MCP_GATEWAY_TOKEN=gwval\nGH_TOKEN=ghval\nOBSIDIAN_ANNOTATED_KEY=ckey' "$(cat "$d/claude.env")"
assert_eq "gemini.env = shared only (no binding)" \
    $'MCP_GATEWAY_TOKEN=gwval\nGH_TOKEN=ghval' "$(cat "$d/gemini.env")"
assert_eq "pi.env carries its watch key" \
    $'MCP_GATEWAY_TOKEN=gwval\nGH_TOKEN=ghval\nANNOTATED_WATCH_KEY=pkey' "$(cat "$d/pi.env")"
assert_eq "every shim agent gets a file" "5" "$(ls "$d"/*.env | wc -l | tr -d ' ')"
assert_absent "no common.env written" "$(ls "$d")" "common.env"
assert_eq "files are mode 600" "600" "$(mode_of "$d/claude.env")"
unset MCP_GATEWAY_TOKEN GH_TOKEN SRC_C SRC_P

# missing source var → warn, and the slot is NOT written
d="$WORK/ck2"; mkdir -p "$d"; chmod 700 "$d"
PES=$(printf 'MISSING_TOK\tMISSING_TOK\tgateway (run run-gateway-coding.sh once)\n')
out=$(compose_keys "$d" "claude" "$PES" "")
assert_contains "missing source warns" "$out" "MISSING_TOK not in secrets.env — gateway (run run-gateway-coding.sh once) will not authenticate"
assert_eq "missing source leaves an empty file" "" "$(cat "$d/claude.env")"

# agent-scoped appended AFTER shared → wins on a name collision when sourced
d="$WORK/ck3"; mkdir -p "$d"; chmod 700 "$d"
FOO=shared BAR=agentval
PES=$(printf 'FOO\tFOO\thint\n')
AS=$(printf 'claude\tFOO\tBAR\n')   # rebinds FOO for claude to BAR's value
compose_keys "$d" "claude" "$PES" "$AS" >/dev/null
sourced=$(env -i bash -c 'set -a; . "$1"; set +a; echo "$FOO"' _ "$d/claude.env")
assert_eq "agent-scoped overrides shared on source (last wins)" "agentval" "$sourced"
unset FOO BAR

# ────────────────────────────────────────────────────────────────────────────
echo "── common.sh ──"
# Copy it out so CDD_ROOT is our temp dir (not the repo, whose ./.env we must
# not read) and BASH_SOURCE resolves there.
cfg="$WORK/cfg"; mkdir -p "$cfg"; cp "$REPO/common.sh" "$cfg/common.sh"
bp() { env -i DEV_AGENT_HOME="${1-}" bash -c '. "$1"; echo "$BASE_PATH"' _ "$cfg/common.sh"; }
assert_eq "default BASE_PATH is ./.dev-agent" "$cfg/.dev-agent" "$(bp '')"
assert_eq "DEV_AGENT_HOME overrides BASE_PATH" "/custom/home" "$(bp /custom/home)"
printf 'DEV_AGENT_HOME=%s/from-dotenv\n' "$WORK" > "$cfg/.env"
assert_eq "./.env sets DEV_AGENT_HOME" "$WORK/from-dotenv" "$(env -i bash -c '. "$1"; echo "$BASE_PATH"' _ "$cfg/common.sh")"
# A failing COMMAND in ./.env (as opposed to an explicit `exit`, which would
# terminate the shell directly) is what common.sh's set +e guard converts into
# a loud exit 1 instead of a silent abort under the caller's set -e.
printf 'false\n' > "$cfg/.env"
out=$(env -i bash -c 'set -e; . "$1"' _ "$cfg/common.sh" 2>&1); rc=$?
assert_rc "broken ./.env aborts with exit 1" 1 "$rc"
assert_contains "broken ./.env reports the failure" "$out" "./.env exited non-zero"
rm -f "$cfg/.env"

# CONTAINERS_PATH resolution (mirrors RULES_PATH: override → $BASE_PATH/containers → repo)
cpath() { env -i DEV_AGENT_HOME="${1-}" CONTAINERS_PATH="${2-}" bash -c '. "$1"; echo "$CONTAINERS_PATH"' _ "$cfg/common.sh"; }
assert_eq "default CONTAINERS_PATH is the repo's containers/" "$cfg/containers" "$(cpath '' '')"
dah="$WORK/dah-cp"; mkdir -p "$dah/containers"
assert_eq "\$BASE_PATH/containers wins when it exists" "$dah/containers" "$(cpath "$dah" '')"
assert_eq "CONTAINERS_PATH env override wins over everything" "/my/private/manifests" "$(cpath "$dah" /my/private/manifests)"

# ────────────────────────────────────────────────────────────────────────────
echo "── allow-egress.sh ──"
run_ae() { ( cd "$REPO" && PATH="$WORK/aebin:$PATH" bash allow-egress.sh "$@" ) 2>&1; }
# docker mock: inspect succeeds (container "exists"), reports NOT running so the
# live-apply path is skipped; ps -a prints nothing.
mkdir -p "$WORK/aebin"
cat > "$WORK/aebin/docker" <<'MOCK'
#!/bin/bash
# $1=subcommand. `inspect -f {{.State.Running}} <c>` → not running (skip live
# apply); plain `inspect <c>` → exit 0 (container exists); ps → nothing.
case "$1" in
    inspect) [ "$2" = "-f" ] && echo false; exit 0 ;;
    ps)      exit 0 ;;
    *)       exit 0 ;;
esac
MOCK
chmod +x "$WORK/aebin/docker"

out=$(run_ae 2>&1); rc=$?
assert_rc "no args → usage rc 1" 1 "$rc"
assert_contains "no args → usage text" "$out" "Usage: ./allow-egress.sh"
out=$(run_ae mycontainer --badflag); rc=$?
assert_rc "unknown flag rc 1" 1 "$rc"
out=$(run_ae mycontainer good.com --save bogus); rc=$?
assert_rc "bad --save value rc 1" 1 "$rc"
assert_contains "bad --save message" "$out" "--save must be yml, firewall, or none"
out=$(run_ae mycontainer 'not_a_domain' --save none); rc=$?
assert_rc "invalid domain rejected rc 1" 1 "$rc"
assert_contains "invalid domain message" "$out" "not valid domain names"
out=$(run_ae mycontainer 'http://x.com' --save none); rc=$?
assert_rc "domain with scheme rejected" 1 "$rc"
out=$(run_ae mycontainer cdn.playwright.dev --save none); rc=$?
assert_rc "valid domain accepted rc 0" 0 "$rc"
assert_contains "valid domain echoed" "$out" "Domains:   cdn.playwright.dev"

# ────────────────────────────────────────────────────────────────────────────
echo "── update-agent-keys.sh ──"
DAH="$WORK/dah"; KP="$DAH/keys/mysite"; mkdir -p "$KP"
uak() { ( cd "$REPO" && env DEV_AGENT_HOME="$DAH" bash update-agent-keys.sh "$@" ) ; }

uak mysite claude OBSIDIAN_ANNOTATED_KEY sekret >/dev/null
assert_eq "set writes VAR to <agent>.env" "OBSIDIAN_ANNOTATED_KEY=sekret" "$(cat "$KP/claude.env")"
assert_eq "edited file is mode 600" "600" "$(mode_of "$KP/claude.env")"
uak mysite claude OBSIDIAN_ANNOTATED_KEY newval >/dev/null
assert_eq "idempotent replace (one line, new value)" "OBSIDIAN_ANNOTATED_KEY=newval" "$(cat "$KP/claude.env")"
printf '\n' | uak mysite claude OBSIDIAN_ANNOTATED_KEY >/dev/null   # empty value → remove
assert_eq "empty value removes the var" "" "$(cat "$KP/claude.env")"
uak mysite common MCP_GATEWAY_TOKEN shared >/dev/null
allhave=1; for a in claude pi gemini cursor-agent codex; do grep -q '^MCP_GATEWAY_TOKEN=shared$' "$KP/$a.env" || allhave=0; done
assert_eq "common fans out to every shim agent" "1" "$allhave"
out=$(uak mysite 2>&1); rc=$?
assert_rc "list mode rc 0" 0 "$rc"
assert_contains "list mode shows var names" "$out" "MCP_GATEWAY_TOKEN"
out=$(uak nosuchcontainer claude VAR val 2>&1); rc=$?
assert_rc "missing keys dir rc 1" 1 "$rc"
out=$(uak mysite bogusagent VAR val 2>&1); rc=$?
assert_rc "unknown agent rc 1" 1 "$rc"
assert_contains "unknown agent message" "$out" "agent must be one of"

# ────────────────────────────────────────────────────────────────────────────
echo "── run-*.sh token generation ──"
mkdir -p "$WORK/rbin"
cat > "$WORK/rbin/openssl" <<'MOCK'
#!/bin/bash
[ "$1" = rand ] && { echo "DETERMINISTICTOKEN"; exit 0; }
exec /usr/bin/openssl "$@" 2>/dev/null || exit 0
MOCK
cat > "$WORK/rbin/docker" <<'MOCK'
#!/bin/bash
echo "docker $* | AUTH=${MCP_GATEWAY_AUTH_TOKEN:-} KEY=${PROXYMAN_BRIDGE_KEY:-}" >> "$DOCKER_LOG"
MOCK
chmod +x "$WORK/rbin/openssl" "$WORK/rbin/docker"

RDAH="$WORK/rdah"; mkdir -p "$RDAH"; SEC="$RDAH/secrets.env"
run_svc() { ( cd "$REPO" && env DEV_AGENT_HOME="$RDAH" DOCKER_LOG="$WORK/dockerlog" PATH="$WORK/rbin:$PATH" bash "$1" ) ; }

: > "$WORK/dockerlog"
run_svc run-gateway-coding.sh >/dev/null 2>&1 || true
assert_contains "gateway self-generates its token into secrets.env" "$(cat "$SEC")" "MCP_GATEWAY_TOKEN=DETERMINISTICTOKEN"
assert_contains "gateway launches docker with the token in env" "$(cat "$WORK/dockerlog")" "AUTH=DETERMINISTICTOKEN"
assert_contains "gateway runs the coding profile on 8811" "$(cat "$WORK/dockerlog")" "gateway run --profile coding --transport streaming --port 8811"

# idempotent: a preset token is not regenerated
printf 'MCP_GATEWAY_TOKEN=PRESET\n' > "$SEC"; : > "$WORK/dockerlog"
run_svc run-gateway-coding.sh >/dev/null 2>&1 || true
assert_eq "preset token kept (one line, unchanged)" "MCP_GATEWAY_TOKEN=PRESET" "$(cat "$SEC")"
assert_contains "preset token passed to docker" "$(cat "$WORK/dockerlog")" "AUTH=PRESET"
# run-proxyman-bridge.sh and run-research-browser.sh share this exact
# generate-if-missing+persist logic, but each gates on a macOS app binary
# (/Applications/…) FIRST, so they can't reach the token step on a Linux host —
# gateway (no such gate) is the representative test for the shared pattern.

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "FAILED: $FAILURES bash test(s)"; exit 1; fi
echo "all bash tests passed"
