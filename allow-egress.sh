#!/bin/bash
# allow-egress.sh <container> <domain> [<domain> ...] [--save yml|firewall|none]
#
# Add domains to a running agent container's egress allowlist WITHOUT a rebuild
# or a container restart. Mirrors what init-firewall.sh does at boot: appends
# `ipset=/<domain>/allowed-domains` zones to the container's /etc/dnsmasq.conf
# and reloads dnsmasq (the resolver process only — the allowed-domains ipset and
# all iptables rules stay up), so the resolver starts mirroring each domain's
# IPs into the allowlist at lookup time.
#
# The live change is EPHEMERAL (lost when the container is recreated). At the
# end you're asked where to persist it:
#   yml       → containers/<name>.yml  capabilities.egress  (this container, next ./up.sh)
#   firewall  → init-firewall.sh base ALLOWED_ZONES         (ALL containers, next build)
#   none      → live only
# Pass --save <target> to skip the prompt.
#
#   ./allow-egress.sh coding-personal-site cdn.playwright.dev playwright.download.prss.microsoft.com
#
# Requires: docker; yq only for the `yml` save target.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ── Parse args ────────────────────────────────────────────────────────────────
SAVE=""          # yml | firewall | none | "" (ask)
RAW=""
DOMAINS=()
while [ $# -gt 0 ]; do
    case "$1" in
        --save) SAVE="${2:-}"; shift 2 ;;
        --save=*) SAVE="${1#--save=}"; shift ;;
        -h|--help)
            sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*) echo "Error: unknown flag '$1'"; exit 1 ;;
        *)
            if [ -z "$RAW" ]; then RAW="$1"; else DOMAINS+=("$1"); fi
            shift ;;
    esac
done

if [ -z "$RAW" ] || [ ${#DOMAINS[@]} -eq 0 ]; then
    echo "Usage: ./allow-egress.sh <container> <domain> [<domain> ...] [--save yml|firewall|none]"
    exit 1
fi
case "${SAVE:-}" in yml|firewall|none|"") ;; *) echo "Error: --save must be yml, firewall, or none"; exit 1 ;; esac

# ── Verify the container ──────────────────────────────────────────────────────
# Accept the short manifest name (coding-personal-site) or the full container
# name (dev-agent-coding-personal-site); normalise to both.
SHORT="${RAW#dev-agent-}"
CONTAINER="dev-agent-$SHORT"
MANIFEST="$SCRIPT_DIR/containers/$SHORT.yml"

command -v docker >/dev/null || { echo "Error: docker not found"; exit 1; }

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "Error: no container named '$CONTAINER'."
    echo "Existing dev-agent containers:"
    docker ps -a --filter "name=dev-agent-" --format '  {{.Names}} ({{.State}})' 2>/dev/null || true
    exit 1
fi
RUNNING="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null || echo false)"

# ── Validate every domain BEFORE touching anything ───────────────────────────
# Strict hostname syntax: labels of [A-Za-z0-9-] (no leading/trailing dash),
# 2+ label TLD. This also rejects shell/dnsmasq metacharacters, so the values
# are safe to pass through to the in-container config.
valid_domain() {
    printf '%s' "$1" | grep -qE '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$'
}
BAD=()
for d in "${DOMAINS[@]}"; do valid_domain "$d" || BAD+=("$d"); done
if [ ${#BAD[@]} -gt 0 ]; then
    echo "Error: not valid domain names: ${BAD[*]}"
    echo "(pass bare hostnames like cdn.playwright.dev — no scheme, path, or port)"
    exit 1
fi

echo "Container: $CONTAINER"
echo "Domains:   ${DOMAINS[*]}"
echo ""

# ── Apply live (no container restart) ─────────────────────────────────────────
# Domains are passed as positional args to an un-expanded (<<'EOF') script, so
# their values are never interpolated into the script text.
if [ "$RUNNING" = "true" ] && docker exec "$CONTAINER" test -f /etc/dnsmasq.conf 2>/dev/null; then
    echo "Applying live to $CONTAINER..."
    docker exec -i -u root "$CONTAINER" bash -s -- "${DOMAINS[@]}" <<'EOF'
set -e
CONF=/etc/dnsmasq.conf
changed=0
for d in "$@"; do
    if grep -q "ipset=/$d/allowed-domains" "$CONF"; then
        echo "  = $d already allowed"
    else
        echo "ipset=/$d/allowed-domains" >> "$CONF"
        echo "  + $d added"
        changed=1
    fi
done
if [ "$changed" = 1 ]; then
    # SIGHUP does NOT reload ipset= lines — dnsmasq must be relaunched. Only the
    # resolver bounces; the allowed-domains ipset and iptables rules persist.
    pkill -x dnsmasq || true
    for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x dnsmasq >/dev/null || break; done
    dnsmasq --conf-file="$CONF"
    for _ in 1 2 3 4 5 6 7 8 9 10; do dig +time=1 +tries=1 @127.0.0.1 api.github.com >/dev/null 2>&1 && break; done
fi
echo "  dnsmasq zones now: $(grep -c '^ipset=' "$CONF")"
echo "--- verify (resolve primes the ipset; https code is informational) ---"
for d in "$@"; do
    ips=$(dig +time=3 +tries=2 @127.0.0.1 "$d" +short | grep -E '^[0-9]+\.' | tr '\n' ' ')
    code=$(curl -s -o /dev/null -w '%{http_code}' --connect-timeout 8 "https://$d/" 2>/dev/null || echo 000)
    echo "  $d -> ip=[${ips:-none}] https=$code"
done
EOF
    echo ""
elif [ "$RUNNING" = "true" ]; then
    echo "⚠ $CONTAINER is running but has no /etc/dnsmasq.conf (firewall disabled?)."
    echo "  Egress is already open — nothing to apply live. You can still persist below."
    echo ""
else
    echo "⚠ $CONTAINER is not running — skipping the live change."
    echo "  Start it (./up.sh $SHORT) and rerun, or just persist below for next boot."
    echo ""
fi

# ── Persist permanently ───────────────────────────────────────────────────────
save_yml() {
    if [ ! -f "$MANIFEST" ]; then
        echo "  ✗ no manifest at $MANIFEST — cannot save to yml"; return 1
    fi
    if ! command -v yq >/dev/null; then
        echo "  ✗ yq not found — cannot save to yml (brew install yq)"; return 1
    fi
    for d in "${DOMAINS[@]}"; do
        D="$d" yq -i '.capabilities.egress = ((.capabilities.egress // []) + [env(D)] | unique)' "$MANIFEST"
    done
    echo "  ✓ added to $MANIFEST (capabilities.egress) — applies on next ./up.sh $SHORT"
}

save_firewall() {
    local FW="$SCRIPT_DIR/src/init-firewall.sh"
    [ -f "$FW" ] || { echo "  ✗ $FW not found"; return 1; }
    for d in "${DOMAINS[@]}"; do
        # Match a bare zone line (one domain per line inside ALLOWED_ZONES).
        if grep -qxE "[[:space:]]*$(printf '%s' "$d" | sed 's/[.]/\\./g')[[:space:]]*" "$FW"; then
            echo "  = $d already in init-firewall.sh"; continue
        fi
        # Insert before the closing quote of the ALLOWED_ZONES here-string.
        awk -v dom="$d" '
            $0 == "ALLOWED_ZONES=\"" { inblock=1; print; next }
            inblock && $0 == "\"" { print dom; inblock=0; print; next }
            { print }
        ' "$FW" > "$FW.tmp" && mv "$FW.tmp" "$FW"
        if grep -qxE "[[:space:]]*$(printf '%s' "$d" | sed 's/[.]/\\./g')[[:space:]]*" "$FW"; then
            echo "  + $d added to init-firewall.sh"
        else
            echo "  ✗ could not locate the ALLOWED_ZONES block in $FW — add '$d' by hand"
            rm -f "$FW.tmp"
        fi
    done
    echo "  ✓ base zones updated — applies to ALL containers on next build/restart"
}

if [ -z "$SAVE" ]; then
    echo "Persist permanently? (the live change above is lost when the container is recreated)"
    echo "  [y] manifest  containers/$SHORT.yml   → this container, next ./up.sh"
    echo "  [f] firewall  init-firewall.sh        → ALL containers, next build"
    echo "  [s] skip                              → live only"
    printf "Choice [y/f/s]: "
    read -r ans
    case "$ans" in
        y|Y) SAVE=yml ;;
        f|F) SAVE=firewall ;;
        *)   SAVE=none ;;
    esac
fi

case "$SAVE" in
    yml)      echo "Saving to manifest...";       save_yml ;;
    firewall) echo "Saving to base firewall...";  save_firewall ;;
    none)     echo "Not persisted (live only)." ;;
esac
