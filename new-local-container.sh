#!/bin/bash
# new-local-container.sh
# Spins up a local Agent dev container (RFC 03: attach mode — no sshd/macvlan).
# Universal: macOS (Docker Desktop / OrbStack) and plain Linux Docker Engine.
# Bash 3.2 compatible (macOS default shell).
#
# Usage: ./new-local-container.sh [profile]
#   profile = a capability bundle from profiles/*.env (default, coding, ...)
#             defining host MCP ports, egress domains, and key prompts.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# ── Capability profile ────────────────────────────────────────────────────────
PROFILE="${1:-}"
if [ -z "$PROFILE" ]; then
    echo "Capability profiles:"
    for f in "$SCRIPT_DIR/profiles"/*.env; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .env)
        desc=$(sed -n '2s/^# *//p' "$f")
        printf "  %-12s %s\n" "$name" "$desc"
    done
    printf "Choose profile [default]: "
    read PROFILE
    PROFILE="${PROFILE:-default}"
fi

PROFILE_FILE="$SCRIPT_DIR/profiles/$PROFILE.env"
if [ ! -f "$PROFILE_FILE" ]; then
    echo "Error: unknown profile '$PROFILE' (no $PROFILE_FILE)"
    exit 1
fi
. "$PROFILE_FILE"
echo "Profile '$PROFILE': ports='${HOST_MCP_PORTS:-none}' domains='${EXTRA_ALLOWED_DOMAINS:-none}'"

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"
SHARED_PATH="$BASE_PATH/shared"

# ── Platform detection ────────────────────────────────────────────────────────
# Docker Desktop (macOS) maps bind-mount ownership transparently; plain Linux
# does not, so there the container user must match the host user.
if [ "$(uname -s)" = "Linux" ]; then
    USER_UID="$(id -u)"
    USER_GID="$(id -g)"
else
    USER_UID=1000
    USER_GID=1000
fi

# ── Container name ────────────────────────────────────────────────────────────
printf "Container name: "
read CONTAINER_NAME
CONTAINER_NAME=$(echo "$CONTAINER_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr -cd 'a-z0-9-')

if [ -z "$CONTAINER_NAME" ]; then
    echo "Error: invalid name"
    exit 1
fi

if docker ps -a --format '{{.Names}}' | grep -q "^dev-agent-$CONTAINER_NAME$"; then
    echo "Error: container 'dev-agent-$CONTAINER_NAME' already exists"
    exit 1
fi

# ── Repo ──────────────────────────────────────────────────────────────────────
printf "Repo URL to clone as /workspace/main (blank = git init): "
read REPO_URL

# ── Git forge ─────────────────────────────────────────────────────────────────
echo "Git forge:"
echo "  1) GitHub  (gh auth login)"
echo "  2) Gitea   (tea login add)"
printf "Choose [1]: "
read FORGE_CHOICE

case "${FORGE_CHOICE:-1}" in
    1)
        FORGE="github"
        FORGE_AUTH_PATH="$SHARED_PATH/gh"
        FORGE_AUTH_MOUNT="/home/coder/.config/gh"
        ;;
    2)
        FORGE="gitea"
        FORGE_AUTH_PATH="$SHARED_PATH/gitea"
        FORGE_AUTH_MOUNT="/home/coder/.config/tea"
        ;;
    *)
        echo "Error: invalid choice"
        exit 1
        ;;
esac

# ── Git identity (defaults from host git config) ─────────────────────────────
DEFAULT_NAME="$(git config --global user.name 2>/dev/null || true)"
DEFAULT_EMAIL="$(git config --global user.email 2>/dev/null || true)"
printf "Git user.name [%s]: " "$DEFAULT_NAME"
read GIT_USER_NAME
GIT_USER_NAME="${GIT_USER_NAME:-$DEFAULT_NAME}"
printf "Git user.email [%s]: " "$DEFAULT_EMAIL"
read GIT_USER_EMAIL
GIT_USER_EMAIL="${GIT_USER_EMAIL:-$DEFAULT_EMAIL}"

# AI tools, host MCP ports, and egress domains come from the profile.

# ── Per-agent MCP credentials (mounted at ~/.agent-keys, loaded by shims) ───
# common.env holds capability tokens shared by every agent in this container
# (gateway, bridges — auto-loaded when their port is granted). <agent>.env
# holds that agent's identity keys (e.g. its own Obsidian Annotated scoped
# key, for attribution). Update later with update-agent-keys.sh — takes
# effect on the agent's next start, no container restart needed.
KEYS_PATH="$BASE_PATH/keys/$CONTAINER_NAME"
mkdir -p "$KEYS_PATH"
chmod 700 "$KEYS_PATH"

# Artifacts outbox — survives all container/volume destruction, Mac-browsable
ARTIFACTS_PATH="$BASE_PATH/artifacts/$CONTAINER_NAME"
mkdir -p "$ARTIFACTS_PATH"

: > "$KEYS_PATH/common.env"
if echo ",$HOST_MCP_PORTS," | grep -q ",8811,"; then
    TOK="$(cat "$SHARED_PATH/gateway-coding.token" 2>/dev/null || true)"
    [ -n "$TOK" ] && echo "MCP_GATEWAY_TOKEN=$TOK" >> "$KEYS_PATH/common.env" \
        || echo "WARNING: port 8811 granted but $SHARED_PATH/gateway-coding.token missing"
fi
if echo ",$HOST_MCP_PORTS," | grep -q ",8813,"; then
    TOK="$(cat "$SHARED_PATH/proxyman-bridge.key" 2>/dev/null || true)"
    [ -n "$TOK" ] && echo "PROXYMAN_BRIDGE_KEY=$TOK" >> "$KEYS_PATH/common.env" \
        || echo "WARNING: port 8813 granted but $SHARED_PATH/proxyman-bridge.key missing"
fi
if echo ",$HOST_MCP_PORTS," | grep -q ",8814,"; then
    TOK="$(cat "$SHARED_PATH/research-browser.key" 2>/dev/null || true)"
    [ -n "$TOK" ] && echo "RESEARCH_BROWSER_KEY=$TOK" >> "$KEYS_PATH/common.env" \
        || echo "WARNING: port 8814 granted but $SHARED_PATH/research-browser.key missing (run run-research-browser.sh once)"
fi
chmod 600 "$KEYS_PATH/common.env"

HAS_OBSIDIAN=false
if [ "${PROMPT_OBSIDIAN_KEY:-false}" = "true" ]; then
    printf "Obsidian Annotated scoped key for the claude agent (blank = none): "
    read -s CLAUDE_OBSIDIAN_KEY
    echo ""
    if [ -n "$CLAUDE_OBSIDIAN_KEY" ]; then
        echo "OBSIDIAN_ANNOTATED_KEY=$CLAUDE_OBSIDIAN_KEY" > "$KEYS_PATH/claude.env"
        chmod 600 "$KEYS_PATH/claude.env"
        HAS_OBSIDIAN=true
    fi
    echo "(other agents: ./update-agent-keys.sh $CONTAINER_NAME pi OBSIDIAN_ANNOTATED_KEY ...)"
fi

# ── Ensure shared dirs exist ──────────────────────────────────────────────────
mkdir -p "$SHARED_PATH/claude" "$FORGE_AUTH_PATH"

# ── Launch ────────────────────────────────────────────────────────────────────
echo ""
echo "Spinning up dev-agent-$CONTAINER_NAME..."

CONTAINER_NAME="$CONTAINER_NAME" \
USER_UID="$USER_UID" \
USER_GID="$USER_GID" \
SHARED_PATH="$SHARED_PATH" \
FORGE_AUTH_PATH="$FORGE_AUTH_PATH" \
FORGE_AUTH_MOUNT="$FORGE_AUTH_MOUNT" \
GIT_USER_NAME="$GIT_USER_NAME" \
GIT_USER_EMAIL="$GIT_USER_EMAIL" \
INSTALL_CLAUDE="$INSTALL_CLAUDE" \
INSTALL_PI="$INSTALL_PI" \
INSTALL_GEMINI="$INSTALL_GEMINI" \
INSTALL_CURSOR="$INSTALL_CURSOR" \
INSTALL_AIDER="$INSTALL_AIDER" \
HOST_MCP_PORTS="$HOST_MCP_PORTS" \
EXTRA_ALLOWED_DOMAINS="$EXTRA_ALLOWED_DOMAINS" \
KEYS_PATH="$KEYS_PATH" \
ARTIFACTS_PATH="$ARTIFACTS_PATH" \
MEM_LIMIT="${MEM_LIMIT:-2g}" \
docker compose -p "dev-agent-$CONTAINER_NAME" -f "$SCRIPT_DIR/docker-compose.local.yml" up -d --build

# ── Wait for firewall/entrypoint to settle ────────────────────────────────────
echo "Waiting for container startup (firewall setup)..."
i=0
while [ $i -lt 24 ]; do
    STATUS="$(docker inspect -f '{{.State.Status}}' "dev-agent-$CONTAINER_NAME" 2>/dev/null || echo missing)"
    if [ "$STATUS" = "exited" ] || [ "$STATUS" = "missing" ]; then
        echo "Error: container failed to start. Logs:"
        docker logs "dev-agent-$CONTAINER_NAME" 2>&1 | tail -20
        exit 1
    fi
    if docker logs "dev-agent-$CONTAINER_NAME" 2>&1 | grep -q "firewall active\|firewall DISABLED"; then
        break
    fi
    sleep 5
    i=$((i + 1))
done

# ── Bootstrap workspace layout (RFC 03 worktree contract) ─────────────────────
echo "Bootstrapping /workspace layout..."

if [ -n "$REPO_URL" ]; then
    docker exec -u coder "dev-agent-$CONTAINER_NAME" bash -c \
        "[ -d /workspace/main/.git ] || git clone '$REPO_URL' /workspace/main" \
        || echo "WARNING: clone failed (private repo? run 'gh auth login' inside, then clone to /workspace/main)"
else
    docker exec -u coder "dev-agent-$CONTAINER_NAME" bash -c \
        "[ -d /workspace/main/.git ] || git init -b main /workspace/main"
fi

docker exec -u coder "dev-agent-$CONTAINER_NAME" bash -c '
mkdir -p /workspace/worktrees
if [ ! -f /workspace/dev.code-workspace ]; then
cat > /workspace/dev.code-workspace <<EOF
{
  "folders": [
    { "path": "main", "name": "main" }
  ],
  "settings": {}
}
EOF
fi
'

docker cp "$SCRIPT_DIR/workspace.CLAUDE.md" "dev-agent-$CONTAINER_NAME:/workspace/CLAUDE.md"
docker exec "dev-agent-$CONTAINER_NAME" chown coder:coder /workspace/CLAUDE.md

# ── Generate .mcp.json (Claude Code only; secrets stay as ${VAR} refs) ───────
# Entries are included only for capabilities this container was granted;
# the shims supply the actual values per agent at process start.
WANT_GATEWAY=false; WANT_PROXYMAN=false; WANT_BROWSER=false
echo ",$HOST_MCP_PORTS," | grep -q ",8811," && WANT_GATEWAY=true
echo ",$HOST_MCP_PORTS," | grep -q ",8813," && WANT_PROXYMAN=true
echo ",$HOST_MCP_PORTS," | grep -q ",8814," && WANT_BROWSER=true

docker exec -u coder \
    -e WANT_GATEWAY="$WANT_GATEWAY" -e WANT_PROXYMAN="$WANT_PROXYMAN" -e WANT_BROWSER="$WANT_BROWSER" -e WANT_OBSIDIAN="$HAS_OBSIDIAN" \
    "dev-agent-$CONTAINER_NAME" bash -c '
[ -f /workspace/main/.mcp.json ] && exit 0
J="{\"mcpServers\":{}}"
if [ "$WANT_GATEWAY" = "true" ]; then
  J=$(echo "$J" | jq ".mcpServers.coding = {type:\"http\",url:\"http://host.docker.internal:8811/mcp\",headers:{Authorization:\"Bearer \${MCP_GATEWAY_TOKEN}\"}}")
fi
if [ "$WANT_PROXYMAN" = "true" ]; then
  J=$(echo "$J" | jq ".mcpServers.proxyman = {type:\"http\",url:\"http://host.docker.internal:8813/mcp\",headers:{\"X-API-Key\":\"\${PROXYMAN_BRIDGE_KEY}\"}}")
fi
if [ "$WANT_BROWSER" = "true" ]; then
  J=$(echo "$J" | jq ".mcpServers.browser = {type:\"http\",url:\"http://host.docker.internal:8814/mcp\",headers:{\"X-API-Key\":\"\${RESEARCH_BROWSER_KEY}\"}}")
fi
if [ "$WANT_OBSIDIAN" = "true" ]; then
  J=$(echo "$J" | jq ".mcpServers.\"obsidian-annotated\" = {type:\"http\",url:\"https://mcp-obsidian.dmetr.io/mcp\",headers:{Authorization:\"Bearer \${OBSIDIAN_ANNOTATED_KEY}\"}}")
fi
echo "$J" | jq . > /workspace/main/.mcp.json
echo "✓ .mcp.json generated ($(echo "$J" | jq -r ".mcpServers | keys | join(\", \")"))"
'

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Container:  dev-agent-$CONTAINER_NAME"
echo "  Profile:    $PROFILE"
echo "  Forge:      $FORGE"
echo "  Firewall:   on (HOST_MCP_PORTS='${HOST_MCP_PORTS:-none}')"
echo ""
echo "  VS Code / Cursor:"
echo "    Dev Containers: Attach to Running Container → dev-agent-$CONTAINER_NAME"
echo "    then open /workspace/dev.code-workspace"
echo ""
echo "  Terminal:   docker exec -it -u coder dev-agent-$CONTAINER_NAME bash"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
