#!/bin/bash
# new-container.sh
# Spins up a new isolated Claude Code dev container on the macvlan network.
# Each container gets a name, a static VLAN IP, and its own /workspace.
#
# Usage:
#   ./new-container.sh                                        # interactive prompts
#   ./new-container.sh --name personal-site --path /mnt/user/dev/personal-site
#   ./new-container.sh --name api --path /mnt/user/dev/api --ip 192.168.35.81

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
IP_REGISTRY="$SCRIPT_DIR/.ip-registry"
SSH_CONFIG="$HOME/.ssh/config"

# IP pool — must match what was set in bootstrap.sh
IP_POOL_START=80
IP_POOL_END=90
IP_PREFIX="192.168.35"

# ── Load .env ─────────────────────────────────────────────────────────────────
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env not found. Copy .env.example to .env and fill in values."
    exit 1
fi
source "$ENV_FILE"

# ── Parse args ────────────────────────────────────────────────────────────────
CONTAINER_NAME=""
PROJECT_PATH=""
CONTAINER_IP=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --name) CONTAINER_NAME="$2"; shift 2 ;;
        --path) PROJECT_PATH="$2"; shift 2 ;;
        --ip)   CONTAINER_IP="$2"; shift 2 ;;
        *) echo "Unknown arg: $1"; exit 1 ;;
    esac
done

# ── Prompt if not provided ────────────────────────────────────────────────────
if [ -z "$CONTAINER_NAME" ]; then
    read -p "Container name (e.g. personal-site, api): " CONTAINER_NAME
fi

# Sanitize: lowercase, hyphens only
CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cd 'a-z0-9-')

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: invalid container name"
    exit 1
fi

if grep -q "^$CONTAINER_NAME " "$IP_REGISTRY" 2>/dev/null; then
    echo "Error: container '$CONTAINER_NAME' already exists"
    echo "Run ./list-containers.sh to see existing containers"
    exit 1
fi

if [ -z "$PROJECT_PATH" ]; then
    read -p "Project path on Unraid (e.g. /mnt/user/dev/personal-site): " PROJECT_PATH
fi

if [ ! -d "$PROJECT_PATH" ]; then
    read -p "Path '$PROJECT_PATH' doesn't exist. Create it? [y/N] " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        mkdir -p "$PROJECT_PATH"
        echo "✓ Created $PROJECT_PATH"
    else
        echo "Aborted."
        exit 1
    fi
fi

# ── Assign next available IP ──────────────────────────────────────────────────
if [ -z "$CONTAINER_IP" ]; then
    touch "$IP_REGISTRY"
    for octet in $(seq $IP_POOL_START $IP_POOL_END); do
        CANDIDATE="$IP_PREFIX.$octet"
        if ! grep -q "$CANDIDATE" "$IP_REGISTRY" 2>/dev/null; then
            CONTAINER_IP="$CANDIDATE"
            break
        fi
    done

    if [ -z "$CONTAINER_IP" ]; then
        echo "Error: IP pool exhausted ($IP_PREFIX.$IP_POOL_START–$IP_POOL_END)"
        exit 1
    fi
fi

# ── Register ──────────────────────────────────────────────────────────────────
echo "$CONTAINER_NAME $CONTAINER_IP $PROJECT_PATH" >> "$IP_REGISTRY"

# ── Write per-container .env ──────────────────────────────────────────────────
CONTAINER_DIR="$SCRIPT_DIR/instances/$CONTAINER_NAME"
mkdir -p "$CONTAINER_DIR"

cat > "$CONTAINER_DIR/.env" <<EOF
CONTAINER_NAME=$CONTAINER_NAME
CONTAINER_IP=$CONTAINER_IP
PROJECT_PATH=$PROJECT_PATH
AUTHORIZED_KEY=$AUTHORIZED_KEY
GIT_USER_NAME=${GIT_USER_NAME:-Demetrio}
GIT_USER_EMAIL=${GIT_USER_EMAIL:-}
EOF

# Symlink shared files into instance dir
ln -sf "$SCRIPT_DIR/docker-compose.yml" "$CONTAINER_DIR/docker-compose.yml"
ln -sf "$SCRIPT_DIR/Dockerfile" "$CONTAINER_DIR/Dockerfile"
ln -sf "$SCRIPT_DIR/entrypoint.sh" "$CONTAINER_DIR/entrypoint.sh"

# ── Build and start ───────────────────────────────────────────────────────────
echo ""
echo "Spinning up claude-dev-$CONTAINER_NAME ($CONTAINER_IP)..."
cd "$CONTAINER_DIR"
docker compose --env-file .env up -d --build

# ── Add SSH config entry on this machine ─────────────────────────────────────
# Note: run this same block on your MacBook too, or copy the ssh config
if ! grep -q "Host $CONTAINER_NAME" "$SSH_CONFIG" 2>/dev/null; then
    cat >> "$SSH_CONFIG" <<EOF

# claude-dev-$CONTAINER_NAME
Host $CONTAINER_NAME
    HostName $CONTAINER_IP
    User coder
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    echo "✓ Added SSH config entry for $CONTAINER_NAME"
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Container:    claude-dev-$CONTAINER_NAME"
echo "  IP:           $CONTAINER_IP"
echo "  Hostname:     $CONTAINER_NAME"
echo "  Project:      $PROJECT_PATH"
echo ""
echo "  From your MacBook, add to ~/.ssh/config:"
echo ""
echo "    Host $CONTAINER_NAME"
echo "        HostName $CONTAINER_IP"
echo "        User coder"
echo "        StrictHostKeyChecking no"
echo ""
echo "  Then connect:"
echo "    ssh $CONTAINER_NAME"
echo "    VS Code → Remote SSH → $CONTAINER_NAME"
echo ""
echo "  First time in the container:"
echo "    claude          ← login to Anthropic"
echo "    gh auth login   ← login to GitHub"
echo ""
echo "  Dev servers will be reachable at:"
echo "    http://$CONTAINER_IP:<port>"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
