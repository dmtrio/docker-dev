#!/bin/bash
# tests/bash.test.sh — unit tests for the host-side bash that holds real logic.
# Hand-rolled execute-and-assert (same style as plugins.test.sh; no bats
# dependency). Covers:
#   - src/keyfiles.sh   key-file composition (sourced by up.sh)
#   - common.sh             BASE_PATH resolution (default / env / ./.env / broken)
#   - allow-egress.sh       arg parsing + strict domain validation
#   - update-agent-keys.sh  per-agent key edits (set / remove / common / list)
#   - plugins/*/run.sh      host launchers' token generate-if-missing + persist
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

# pwd -P so WORK matches what common.sh computes for CDD_ROOT: it resolves
# symlinks, and macOS puts mktemp dirs under /var/folders (/var → private/var),
# which would make every path-equality assertion below fail on a Mac.
WORK=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$WORK"' EXIT

# A sandbox copy of the scripts under test, laid out exactly like the repo
# (bin/ + src/) but with NO ./.env. The scripts that resolve a dev-agent home
# source src/common.sh, which reads the repo root's ./.env BEFORE honouring
# $DEV_AGENT_HOME — so running them from $REPO on a machine that has the
# documented `DEV_AGENT_HOME=...` in ./.env would ignore our sandbox and write
# to the user's REAL keys/secrets. Running them from here can't.
SBOX="$WORK/repo"; mkdir -p "$SBOX/bin" "$SBOX/src" "$SBOX/plugins/gateway"
cp "$REPO"/bin/*.sh "$SBOX/bin/"; cp "$REPO"/src/common.sh "$SBOX/src/"
# The launcher test drives gateway THROUGH service.sh (the only supported entry
# point): service.sh sources src/common.sh, resolves BASE_PATH, and hands it to
# plugins/<name>/run.sh in the env. Mirror that layout — service.sh at the root,
# common.sh under src/, the launcher under plugins/gateway/. gateway is the
# representative launcher (see the run.sh note below).
cp "$REPO/service.sh" "$SBOX/service.sh"
cp "$REPO"/plugins/gateway/run.sh "$SBOX/plugins/gateway/"

# ────────────────────────────────────────────────────────────────────────────
echo "── src/keyfiles.sh ──"
# shellcheck disable=SC1091
. "$REPO/src/keyfiles.sh"   # defines warn_missing + write_keyfiles, no side effects
SHIM="claude pi gemini cursor-agent codex"

d="$WORK/ck1"; mkdir -p "$d"; chmod 700 "$d"
MCP_GATEWAY_TOKEN=gwval GH_TOKEN=ghval SRC_C=ckey SRC_P=pkey
PES=$(printf 'MCP_GATEWAY_TOKEN\tMCP_GATEWAY_TOKEN\tgateway (run ./service.sh gateway once)\n')
AS=$(printf 'claude\tOBSIDIAN_ANNOTATED_KEY\tSRC_C\npi\tANNOTATED_WATCH_KEY\tSRC_P\n')
write_keyfiles "$d" "$SHIM" "$PES" "$AS" >/dev/null

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
PES=$(printf 'MISSING_TOK\tMISSING_TOK\tgateway (run ./service.sh gateway once)\n')
out=$(write_keyfiles "$d" "claude" "$PES" "")
assert_contains "missing source warns" "$out" "MISSING_TOK not in secrets.env — gateway (run ./service.sh gateway once) will not authenticate"
assert_eq "missing source leaves an empty file" "" "$(cat "$d/claude.env")"

# agent-scoped appended AFTER shared → wins on a name collision when sourced
d="$WORK/ck3"; mkdir -p "$d"; chmod 700 "$d"
FOO=shared BAR=agentval
PES=$(printf 'FOO\tFOO\thint\n')
AS=$(printf 'claude\tFOO\tBAR\n')   # rebinds FOO for claude to BAR's value
write_keyfiles "$d" "claude" "$PES" "$AS" >/dev/null
sourced=$(env -i bash -c 'set -a; . "$1"; set +a; echo "$FOO"' _ "$d/claude.env")
assert_eq "agent-scoped overrides shared on source (last wins)" "agentval" "$sourced"
unset FOO BAR

# ────────────────────────────────────────────────────────────────────────────
echo "── common.sh ──"
# Copy it out so CDD_ROOT is our temp dir (not the repo, whose ./.env we must
# not read) and BASH_SOURCE resolves there. It lives in src/, and CDD_ROOT is
# that dir's PARENT — so mirror the layout: $cfg/src/common.sh → CDD_ROOT=$cfg.
cfg="$WORK/cfg"; mkdir -p "$cfg/src"; cp "$REPO/src/common.sh" "$cfg/src/common.sh"
bp() { env -i DEV_AGENT_HOME="${1-}" bash -c '. "$1"; echo "$BASE_PATH"' _ "$cfg/src/common.sh"; }
assert_eq "default BASE_PATH is ./.dev-agent" "$cfg/.dev-agent" "$(bp '')"
assert_eq "DEV_AGENT_HOME overrides BASE_PATH" "/custom/home" "$(bp /custom/home)"
printf 'DEV_AGENT_HOME=%s/from-dotenv\n' "$WORK" > "$cfg/.env"
assert_eq "./.env sets DEV_AGENT_HOME" "$WORK/from-dotenv" "$(env -i bash -c '. "$1"; echo "$BASE_PATH"' _ "$cfg/src/common.sh")"
# A failing COMMAND in ./.env (as opposed to an explicit `exit`, which would
# terminate the shell directly) is what common.sh's set +e guard converts into
# a loud exit 1 instead of a silent abort under the caller's set -e.
printf 'false\n' > "$cfg/.env"
out=$(env -i bash -c 'set -e; . "$1"' _ "$cfg/src/common.sh" 2>&1); rc=$?
assert_rc "broken ./.env aborts with exit 1" 1 "$rc"
assert_contains "broken ./.env reports the failure" "$out" "./.env exited non-zero"
rm -f "$cfg/.env"

# CONTAINERS_PATH resolution (mirrors RULES_PATH: override → $BASE_PATH/containers → repo)
cpath() { env -i DEV_AGENT_HOME="${1-}" CONTAINERS_PATH="${2-}" bash -c '. "$1"; echo "$CONTAINERS_PATH"' _ "$cfg/src/common.sh"; }
assert_eq "default CONTAINERS_PATH is the repo's containers/" "$cfg/containers" "$(cpath '' '')"
dah="$WORK/dah-cp"; mkdir -p "$dah/containers"
assert_eq "\$BASE_PATH/containers wins when it exists" "$dah/containers" "$(cpath "$dah" '')"
assert_eq "CONTAINERS_PATH env override wins over everything" "/my/private/manifests" "$(cpath "$dah" /my/private/manifests)"

# ────────────────────────────────────────────────────────────────────────────
echo "── allow-egress.sh ──"
run_ae() { ( cd "$SBOX" && env CONTAINERS_PATH="$WORK/no-such-manifests" PATH="$WORK/aebin:$PATH" bash bin/allow-egress.sh "$@" ) 2>&1; }
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
assert_contains "no args → usage text" "$out" "Usage: ./bin/allow-egress.sh"
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
uak() { ( cd "$SBOX" && env DEV_AGENT_HOME="$DAH" bash bin/update-agent-keys.sh "$@" ) ; }

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
# Drive the launcher through service.sh (the entry point): service.sh resolves
# BASE_PATH from DEV_AGENT_HOME via common.sh and exports it for run.sh.
run_svc() { ( cd "$SBOX" && env DEV_AGENT_HOME="$RDAH" DOCKER_LOG="$WORK/dockerlog" PATH="$WORK/rbin:$PATH" bash service.sh "$1" ) ; }

: > "$WORK/dockerlog"
run_svc gateway >/dev/null 2>&1 || true
assert_contains "gateway self-generates its token into secrets.env" "$(cat "$SEC")" "MCP_GATEWAY_TOKEN=DETERMINISTICTOKEN"
assert_contains "gateway launches docker with the token in env" "$(cat "$WORK/dockerlog")" "AUTH=DETERMINISTICTOKEN"
assert_contains "gateway runs the coding profile on 8811" "$(cat "$WORK/dockerlog")" "gateway run --profile coding --transport streaming --port 8811"

# service.sh resolves + exports BASE_PATH so run.sh needs no path of its own
assert_contains "launcher requires BASE_PATH from service.sh" \
    "$(cd "$SBOX" && bash plugins/gateway/run.sh 2>&1 || true)" \
    "run this launcher via ./service.sh gateway"

# idempotent: a preset token is not regenerated
printf 'MCP_GATEWAY_TOKEN=PRESET\n' > "$SEC"; : > "$WORK/dockerlog"
run_svc gateway >/dev/null 2>&1 || true
assert_eq "preset token kept (one line, unchanged)" "MCP_GATEWAY_TOKEN=PRESET" "$(cat "$SEC")"
assert_contains "preset token passed to docker" "$(cat "$WORK/dockerlog")" "AUTH=PRESET"
# plugins/proxyman/run.sh and plugins/browser/run.sh share this exact
# generate-if-missing+persist logic, but each gates on a macOS app binary
# (/Applications/…) FIRST, so they can't reach the token step on a Linux host —
# gateway (no such gate) is the representative test for the shared pattern.

# ────────────────────────────────────────────────────────────────────────────
echo "── service.sh (host-service dispatcher) ──"
# A throwaway repo layout: service.sh + src/common.sh (service.sh sources it to
# resolve BASE_PATH just before exec) + a plugin that ships a run.sh (echoes its
# forwarded args) and one that doesn't. No ./.env, so the validation/error paths
# never touch it and the exec path resolves BASE_PATH to $SVC/.dev-agent.
SVC="$WORK/svc"; mkdir -p "$SVC/src" "$SVC/plugins/withsvc" "$SVC/plugins/nosvc"
cp "$REPO/service.sh" "$SVC/service.sh"; cp "$REPO/src/common.sh" "$SVC/src/"
cat > "$SVC/plugins/withsvc/run.sh" <<'MOCK'
#!/bin/bash
echo "ran withsvc args=[$*] base=${BASE_PATH:+set}"
MOCK
chmod +x "$SVC/plugins/withsvc/run.sh"
: > "$SVC/plugins/nosvc/plugin.yml"
svc() { ( cd "$SVC" && bash service.sh "$@" ) ; }

out=$(svc 2>&1); rc=$?
assert_rc "no arg exits non-zero" 1 "$rc"
assert_contains "no arg lists services with a run.sh" "$out" "withsvc"
assert_absent "no arg omits plugins without a run.sh" "$out" "nosvc"

out=$(svc nonesuch 2>&1); rc=$?
assert_rc "unknown plugin exits non-zero" 1 "$rc"
assert_contains "unknown plugin names the missing dir" "$out" "no plugin named 'nonesuch'"

out=$(svc ../withsvc 2>&1); rc=$?
assert_rc "path-traversal name rejected before any fs lookup" 1 "$rc"
assert_contains "traversal name reported as invalid" "$out" "invalid plugin name"

out=$(svc nosvc 2>&1); rc=$?
assert_rc "plugin without run.sh exits non-zero" 1 "$rc"
assert_contains "plugin without run.sh explains why" "$out" "has no host service"

out=$(svc withsvc chrome --flag 2>&1); rc=$?
assert_rc "valid service execs run.sh (rc 0)" 0 "$rc"
assert_contains "dispatcher forwards extra args verbatim" "$out" "ran withsvc args=[chrome --flag]"
assert_contains "dispatcher exports BASE_PATH to the launcher" "$out" "base=set"

echo ""
if [ "$FAILURES" -gt 0 ]; then echo "FAILED: $FAILURES bash test(s)"; exit 1; fi
echo "all bash tests passed"
