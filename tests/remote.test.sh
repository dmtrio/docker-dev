#!/bin/bash
# tests/remote.test.sh — host-runnable checks for the RFC 04 remote-access
# mechanism. Needs only yq (+ standard tools, no docker): validates the
# manifest plumbing expressions up.sh uses, the compose overlays, the
# firewall/wrapper port-range agreement, and pins mirrored expressions to
# the source files (drift guard). The end-to-end SSH/mosh/phone path is the
# manual smoke test (IMP 04 A5/B2 acceptance).

# SC2015 (`A && pass || fail` is not if-else): intentional — pass() is a
# bare echo and cannot fail, so the || arm only runs when the check fails.
# shellcheck disable=SC2015

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$SCRIPT_DIR"

command -v yq >/dev/null || { echo "SKIP: yq not installed"; exit 0; }

FAILURES=0
fail() { echo "  ✗ $1"; FAILURES=$((FAILURES + 1)); }
pass() { echo "  ✓ $1"; }

echo "── syntax"
for f in up.sh src/entrypoint.sh src/init-firewall.sh src/tmux-notify.sh src/mosh-server-wrapper.sh src/tmux-landing.bashrc; do
    bash -n "$f" && pass "bash -n $f" || fail "$f has syntax errors"
done

echo "── compose overlays"
for f in docker-compose.local.yml docker-compose.ssh.yml docker-compose.mosh.yml; do
    yq '.' "$f" >/dev/null 2>&1 && pass "$f parses" || fail "$f is not valid YAML"
done
[ "$(yq '.networks.default.name' docker-compose.local.yml)" = "dev-agent-net" ] \
    && pass "local compose joins the shared dev-agent-net bridge" \
    || fail "local compose is missing the shared-network config"
[ "$(yq '.networks.default.external' docker-compose.local.yml)" = "true" ] \
    && pass "shared network is external (created by up.sh, not compose)" \
    || fail "shared network must be external: true"
yq -r '.services.dev-agent.environment[]' docker-compose.ssh.yml | grep -q '^REMOTE_TMUX=' \
    && pass "ssh overlay passes REMOTE_TMUX" \
    || fail "ssh overlay is missing REMOTE_TMUX"
for var in NTFY_URL NTFY_TOPIC; do
    yq -r '.services.dev-agent.environment[]' docker-compose.ssh.yml | grep -q "^$var=" \
        && pass "ssh overlay passes $var" \
        || fail "ssh overlay is missing $var"
done

echo "── mosh port-range agreement (overlay = wrapper = firewall)"
OVERLAY_RANGE=$(yq -r '.services.dev-agent.environment[]' docker-compose.mosh.yml | sed -n 's/^MOSH_PORTS=//p')
[ "$OVERLAY_RANGE" = "60000:60010" ] \
    && pass "mosh overlay sets MOSH_PORTS=60000:60010" \
    || fail "mosh overlay MOSH_PORTS unexpected: '$OVERLAY_RANGE'"
grep -qF '60000:60010' src/mosh-server-wrapper.sh \
    && pass "mosh-server wrapper default matches the overlay range" \
    || fail "wrapper default range drifted from the overlay"
yq -r '.services.dev-agent.ports[]' docker-compose.mosh.yml | grep -qF '60000-60010:60000-60010/udp' \
    && pass "mosh overlay publishes the same UDP range" \
    || fail "mosh overlay UDP publish drifted from MOSH_PORTS"
if printf '%s' "$OVERLAY_RANGE" | grep -qE '^[0-9]+:[0-9]+$'; then
    pass "overlay range passes the firewall's MOSH_PORTS validation"
else
    fail "overlay range would be rejected by init-firewall.sh"
fi

echo "── manifest plumbing simulation (same expressions as up.sh)"
M=$(mktemp); trap 'rm -f "$M"' EXIT
printf 'ssh:\n  port: 2222\nremote:\n  tmux: true\n  mosh: true\n  notify: ntfy\n' > "$M"
[ "$(yq '.remote.tmux // false' "$M")" = "true" ]  && pass "remote.tmux reads back"  || fail "remote.tmux read broken"
[ "$(yq '.remote.mosh // false' "$M")" = "true" ]  && pass "remote.mosh reads back"  || fail "remote.mosh read broken"
[ "$(yq -r '.remote.notify // ""' "$M")" = "ntfy" ] && pass "remote.notify reads back" || fail "remote.notify read broken"
printf 'remote:\n  tmux: true\n' > "$M"
[ "$(yq -r '.ssh.port // ""' "$M")" = "" ] \
    && pass "remote-without-ssh is detectable (ssh.port empty)" \
    || fail "ssh.port unexpectedly present"

# ntfy host extraction (same sed as up.sh)
extract_host() { printf '%s' "$1" | sed -E 's|^[A-Za-z]+://||; s|/.*$||; s|:.*$||'; }
[ "$(extract_host 'https://ntfy.example.com')" = "ntfy.example.com" ] \
    && pass "ntfy host parsed from bare https URL" \
    || fail "host extraction broke on bare URL"
[ "$(extract_host 'http://ntfy.lan:8080/topic')" = "ntfy.lan" ] \
    && pass "ntfy host parsed from URL with port + path" \
    || fail "host extraction broke on port/path URL"

echo "── landing + notify wiring"
grep -qF 'tmux new-session -A -s agent' src/tmux-landing.bashrc \
    && pass "landing snippet attaches the shared 'agent' session" \
    || fail "landing snippet lost the new-session -A attach"
grep -qE 'sshd\|mosh-server' src/tmux-landing.bashrc \
    && pass "landing snippet gates on sshd/mosh-server parents" \
    || fail "landing snippet lost the parent-process gate"
grep -qF 'tmux-landing.bashrc' Dockerfile \
    && pass "Dockerfile installs + sources the landing snippet" \
    || fail "Dockerfile no longer wires tmux-landing.bashrc"
grep -qF '/usr/local/bin/tmux-notify.sh' src/tmux.conf \
    && pass "tmux.conf silence hook points at tmux-notify.sh" \
    || fail "tmux.conf hook target drifted"
grep -qF 'src/tmux-notify.sh /usr/local/bin/tmux-notify.sh' Dockerfile \
    && pass "Dockerfile installs tmux-notify.sh where the hook expects" \
    || fail "Dockerfile install path drifted from the tmux.conf hook"
grep -qF 'monitor-silence' src/tmux.conf \
    && pass "tmux.conf arms monitor-silence behind NTFY_URL" \
    || fail "tmux.conf lost the silence monitor"
grep -qF 'list-clients' src/tmux-notify.sh \
    && pass "notifier suppresses while a client is attached" \
    || fail "notifier lost attached-client suppression"

echo "── drift guard (expressions this suite mirrors must exist in the sources)"
while IFS=$'\t' read -r file expr; do
    [ -n "$expr" ] || continue
    grep -qF -- "$expr" "$file" \
        && pass "$file still contains: $expr" \
        || fail "$file no longer contains (update this suite!): $expr"
done <<'DRIFT'
up.sh	.remote.tmux // false
up.sh	.remote.mosh // false
up.sh	.remote.notify
up.sh	docker-compose.mosh.yml
up.sh	dev-agent-net
up.sh	s|^[A-Za-z]+://||; s|/.*$||; s|:.*$||
src/init-firewall.sh	^[0-9]+:[0-9]+$
src/init-firewall.sh	--dport "$MOSH_PORTS"
src/entrypoint.sh	REMOTE_TMUX MOSH_PORTS NTFY_URL NTFY_TOPIC CONTAINER_NAME
DRIFT

echo ""
if [ "$FAILURES" -gt 0 ]; then
    echo "FAILED: $FAILURES check(s)"
    exit 1
fi
echo "all checks passed"
