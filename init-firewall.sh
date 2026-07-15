#!/bin/bash
# init-firewall.sh — egress allowlist for agent dev containers.
# Adapted from anthropics/claude-code .devcontainer/init-firewall.sh.
#
# Default-denies all outbound traffic except an ipset allowlist (GitHub IP
# ranges + resolved domains), DNS, outbound SSH, and loopback. Verifies
# itself at the end and exits non-zero on any failure — the entrypoint
# treats that as fatal so the container never runs with open egress.
#
# Requires: NET_ADMIN + NET_RAW capabilities; iptables, ipset, dig, jq,
# aggregate, curl (installed in the Dockerfile).
#
# Env:
#   EXTRA_ALLOWED_DOMAINS  comma/space-separated extra domains to allow
#   HOST_MCP_PORTS         comma/space-separated TCP ports on
#                          host.docker.internal to open (MCP servers on the
#                          host). Unset = host unreachable.

set -euo pipefail
IFS=$'\n\t'

# 1. Extract Docker DNS info BEFORE any flushing
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# Flush existing rules and delete existing ipsets
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Selectively restore ONLY internal Docker DNS resolution
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# First allow DNS and localhost before any restrictions
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
# Outbound SSH (git over ssh)
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
# Localhost
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Create ipset with CIDR support
ipset create allowed-domains hash:net

# Fetch GitHub meta information and aggregate + add their IP ranges
echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi

if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

# Baseline allowed domains:
#   - Claude Code: api + auth + telemetry
#   - npm registry, nodejs.org (fnm runtime Node downloads)
#   - PyPI (pip/pipenv/uv)
#   - GitHub raw/release assets (not all covered by meta ranges)
#   - Ubuntu apt mirrors (ports.ubuntu.com is the arm64 mirror)
#   - VS Code server download (Dev Containers attach / Remote SSH)
ALLOWED_DOMAINS="
registry.npmjs.org
api.anthropic.com
console.anthropic.com
claude.ai
pi.dev
cursor.com
api2.cursor.sh
downloads.cursor.com
sentry.io
statsig.anthropic.com
statsig.com
nodejs.org
pypi.org
files.pythonhosted.org
raw.githubusercontent.com
objects.githubusercontent.com
archive.ubuntu.com
security.ubuntu.com
ports.ubuntu.com
marketplace.visualstudio.com
update.code.visualstudio.com
vscode.download.prss.microsoft.com
"

# Per-container additions
if [ -n "${EXTRA_ALLOWED_DOMAINS:-}" ]; then
    echo "Adding extra allowed domains: $EXTRA_ALLOWED_DOMAINS"
    ALLOWED_DOMAINS="$ALLOWED_DOMAINS
$(echo "$EXTRA_ALLOWED_DOMAINS" | tr ', ' '\n\n')"
fi

for domain in $ALLOWED_DOMAINS; do
    [ -z "$domain" ] && continue
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done < <(echo "$ips")
done

# Get host IP from default route
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi

HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"

# INBOUND from the host network stays open (published ports arrive via the
# gateway proxy). OUTBOUND to the host network is deliberately NOT opened
# wholesale — on plain Linux the gateway IS the host, and a blanket rule
# would defeat the HOST_MCP_PORTS opt-in below.
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT

# Set default policies to DROP first
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Allow established connections for already approved traffic
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow outbound traffic to allowed domains
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# Host MCP opt-in: open ONLY the listed TCP ports on host.docker.internal
if [ -n "${HOST_MCP_PORTS:-}" ]; then
    HOST_GW_IP=$(getent ahostsv4 host.docker.internal | awk 'NR==1{print $1}' || true)
    if [ -z "$HOST_GW_IP" ]; then
        echo "ERROR: HOST_MCP_PORTS set but host.docker.internal does not resolve"
        exit 1
    fi
    for port in $(echo "$HOST_MCP_PORTS" | tr ', ' '\n\n'); do
        [ -z "$port" ] && continue
        if [[ ! "$port" =~ ^[0-9]+$ ]]; then
            echo "ERROR: Invalid port in HOST_MCP_PORTS: $port"
            exit 1
        fi
        echo "Allowing host MCP port $HOST_GW_IP:$port"
        iptables -A OUTPUT -d "$HOST_GW_IP" -p tcp --dport "$port" -j ACCEPT
    done
fi

# Explicitly REJECT all other outbound traffic for immediate feedback
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

echo "Firewall configuration complete"
echo "Verifying firewall rules..."
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "Firewall verification passed - unable to reach https://example.com as expected"
fi

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "Firewall verification passed - able to reach https://api.github.com as expected"
fi
