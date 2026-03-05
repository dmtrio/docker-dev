# UNUSED FILE
# UNUSED FILE
# UNUSED FILE
# UNUSED FILE
# UNUSED FILE
# UNUSED FILE
# Left as reference

#!/bin/bash
# bootstrap.sh
# Run this ONCE on your Unraid host before spinning up any containers.
# Creates the macvlan network and shared volumes that all containers use.

set -e

echo "╔══════════════════════════════════════════╗"
echo "║     Claude Dev Container Bootstrap       ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ── macvlan network ───────────────────────────────────────────────────────────
# Containers will appear as real hosts on your VLAN, accessible from your
# MacBook and any other device on the network.
#
# parent:   br0         — Unraid's bridge interface
# subnet:   matches your VLAN subnet
# gateway:  your router/VLAN gateway
# ip-range: the slice of IPs reserved for containers (keep out of DHCP pool)

NETWORK_NAME="claude-macvlan"
PARENT_IFACE="br0"
SUBNET="192.168.35.0/24"      # Your full VLAN subnet
GATEWAY="192.168.35.1"        # Your router/gateway IP — update if different
IP_RANGE="192.168.35.80/28"   # Container pool: .80–.95 (adjust to taste)

if docker network inspect "$NETWORK_NAME" &>/dev/null; then
    echo "✓ Network '$NETWORK_NAME' already exists"
else
    docker network create \
        --driver macvlan \
        --subnet "$SUBNET" \
        --gateway "$GATEWAY" \
        --ip-range "$IP_RANGE" \
        --opt parent="$PARENT_IFACE" \
        "$NETWORK_NAME"
    echo "✓ Created macvlan network '$NETWORK_NAME'"
    echo "  Parent:   $PARENT_IFACE"
    echo "  Subnet:   $SUBNET"
    echo "  Gateway:  $GATEWAY"
    echo "  IP pool:  $IP_RANGE"
fi

echo ""

# ── Shared volumes ────────────────────────────────────────────────────────────
for vol in claude-auth gh-auth claude-vscode-server; do
    if docker volume inspect "$vol" &>/dev/null; then
        echo "✓ Volume '$vol' already exists"
    else
        docker volume create "$vol"
        echo "✓ Created volume '$vol'"
    fi
done

echo ""
echo "Bootstrap complete. You can now run new-container.sh to spin up containers."
echo ""
echo "Note: Your MacBook can SSH directly to container IPs (192.168.35.80-95)."
echo "      The Unraid host itself cannot reach macvlan containers directly."
echo "      Use a container or your MacBook to reach them instead."
