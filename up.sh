#!/bin/bash
# up.sh <name> — declaratively create or update an agent dev container from
# containers/<name>.yml. Idempotent: edit the manifest, rerun, done.
#
# Kept:     the manifest (containers/*.yml) and ~/dev-agent/secrets.env
# Derived:  ~/dev-agent/keys/<name>/ (recomposed every run), the container,
#           generated .mcp.json / dev.code-workspace / workspace CLAUDE.md
# Survives: workspace volume (code), ~/dev-agent/artifacts/<name>/
#
# Requires: docker, yq (brew install yq / static binary on Linux), jq in image.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

NAME="$1"
if [ -z "$NAME" ]; then
    echo "Usage: ./up.sh <name>    (reads containers/<name>.yml)"
    echo "Manifests:"
    for f in "$SCRIPT_DIR/containers"/*.yml; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .yml)
        [ "$n" = "TEMPLATE" ] && continue
        printf "  %s\n" "$n"
    done
    exit 1
fi

MANIFEST="$SCRIPT_DIR/containers/$NAME.yml"
[ -f "$MANIFEST" ] || { echo "Error: no manifest at $MANIFEST (cp containers/TEMPLATE.yml)"; exit 1; }
command -v yq >/dev/null || { echo "Error: yq required (brew install yq)"; exit 1; }

BASE_PATH="${DEV_AGENT_HOME:-$HOME/dev-agent}"
SHARED_PATH="$BASE_PATH/shared"
SECRETS_FILE="$BASE_PATH/secrets.env"
[ -f "$SECRETS_FILE" ] || { touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; }
. "$SECRETS_FILE"

Y() { yq -r "$1 // \"\"" "$MANIFEST"; }

# ── Read manifest ─────────────────────────────────────────────────────────────
REPO_URL=$(Y '.repo')
FORGE=$(Y '.forge'); FORGE="${FORGE:-github}"
GIT_USER_NAME=$(Y '.git.name'); GIT_USER_NAME="${GIT_USER_NAME:-$(git config --global user.name 2>/dev/null || true)}"
GIT_USER_EMAIL=$(Y '.git.email'); GIT_USER_EMAIL="${GIT_USER_EMAIL:-$(git config --global user.email 2>/dev/null || true)}"
MEM_LIMIT=$(Y '.memory'); MEM_LIMIT="${MEM_LIMIT:-2g}"

case "$FORGE" in
    github) FORGE_AUTH_PATH="$SHARED_PATH/gh";    FORGE_AUTH_MOUNT="/home/coder/.config/gh" ;;
    gitea)  FORGE_AUTH_PATH="$SHARED_PATH/gitea"; FORGE_AUTH_MOUNT="/home/coder/.config/tea" ;;
    *) echo "Error: forge must be github or gitea"; exit 1 ;;
esac

has_tool() {
    yq "(.tools // [\"claude\",\"codex\",\"pi\",\"gemini\",\"cursor\",\"aider\"]) | contains([\"$1\"])" "$MANIFEST"
}
INSTALL_CLAUDE=$(has_tool claude)
INSTALL_CODEX=$(has_tool codex)
INSTALL_PI=$(has_tool pi)
INSTALL_GEMINI=$(has_tool gemini)
INSTALL_CURSOR=$(has_tool cursor)
INSTALL_AIDER=$(has_tool aider)

CAP_GATEWAY=$(yq '.capabilities.gateway // false' "$MANIFEST")
CAP_PROXYMAN=$(yq '.capabilities.proxyman // false' "$MANIFEST")
CAP_BROWSER=$(yq '.capabilities.browser // false' "$MANIFEST")
EGRESS=$(yq -r '(.capabilities.egress // []) | join(",")' "$MANIFEST")
OBS_AGENTS=$(yq -r '(.identities.obsidian // []) | join(" ")' "$MANIFEST")
WATCH_AGENTS=$(yq -r '(.identities.watch // []) | join(" ")' "$MANIFEST")

HOST_MCP_PORTS=""
[ "$CAP_GATEWAY" = "true" ]  && HOST_MCP_PORTS="$HOST_MCP_PORTS,8811"
[ "$CAP_PROXYMAN" = "true" ] && HOST_MCP_PORTS="$HOST_MCP_PORTS,8813"
[ "$CAP_BROWSER" = "true" ]  && HOST_MCP_PORTS="$HOST_MCP_PORTS,8814"
HOST_MCP_PORTS="${HOST_MCP_PORTS#,}"

# Obsidian identities imply the Annotated endpoint in the egress allowlist
if [ -n "$OBS_AGENTS" ] && ! echo ",$EGRESS," | grep -q ",mcp-obsidian.dmetr.io,"; then
    EGRESS="${EGRESS:+$EGRESS,}mcp-obsidian.dmetr.io"
fi

# ── Compose derived credentials (keys/<name>/ is rebuilt from scratch) ───────
KEYS_PATH="$BASE_PATH/keys/$NAME"
mkdir -p "$KEYS_PATH"; chmod 700 "$KEYS_PATH"
rm -f "$KEYS_PATH"/*.env

warn_missing() { echo "  ⚠ $1 not in secrets.env — $2 will not authenticate until set"; }

: > "$KEYS_PATH/common.env"
if [ "$CAP_GATEWAY" = "true" ]; then
    [ -n "${MCP_GATEWAY_TOKEN:-}" ] && echo "MCP_GATEWAY_TOKEN=$MCP_GATEWAY_TOKEN" >> "$KEYS_PATH/common.env" \
        || warn_missing MCP_GATEWAY_TOKEN "gateway (run run-gateway-coding.sh once)"
fi
if [ "$CAP_PROXYMAN" = "true" ]; then
    [ -n "${PROXYMAN_BRIDGE_KEY:-}" ] && echo "PROXYMAN_BRIDGE_KEY=$PROXYMAN_BRIDGE_KEY" >> "$KEYS_PATH/common.env" \
        || warn_missing PROXYMAN_BRIDGE_KEY "proxyman (run run-proxyman-bridge.sh once)"
fi
if [ "$CAP_BROWSER" = "true" ]; then
    [ -n "${RESEARCH_BROWSER_KEY:-}" ] && echo "RESEARCH_BROWSER_KEY=$RESEARCH_BROWSER_KEY" >> "$KEYS_PATH/common.env" \
        || warn_missing RESEARCH_BROWSER_KEY "browser (run run-research-browser.sh once)"
fi
[ -n "${GH_TOKEN:-}" ] && echo "GH_TOKEN=$GH_TOKEN" >> "$KEYS_PATH/common.env"
chmod 600 "$KEYS_PATH/common.env"

SAFE_NAME=$(echo "$NAME" | tr '-' '_')
for a in $OBS_AGENTS; do
    var="OBSIDIAN_KEY_${SAFE_NAME}_$(echo "$a" | tr '-' '_')"
    eval "v=\${$var:-}"
    if [ -n "$v" ]; then
        echo "OBSIDIAN_ANNOTATED_KEY=$v" >> "$KEYS_PATH/$a.env"
    else
        warn_missing "$var" "obsidian identity for $a"
    fi
done
for a in $WATCH_AGENTS; do
    var="OBSIDIAN_WATCH_KEY_${SAFE_NAME}_$(echo "$a" | tr '-' '_')"
    eval "v=\${$var:-}"
    if [ -n "$v" ]; then
        echo "ANNOTATED_WATCH_KEY=$v" >> "$KEYS_PATH/$a.env"
    else
        warn_missing "$var" "watch identity for $a"
    fi
done
for f in "$KEYS_PATH"/*.env; do [ -f "$f" ] && chmod 600 "$f"; done

# ── Host paths + platform ─────────────────────────────────────────────────────
ARTIFACTS_PATH="$BASE_PATH/artifacts/$NAME"
mkdir -p "$ARTIFACTS_PATH" "$SHARED_PATH/claude" "$SHARED_PATH/codex" "$FORGE_AUTH_PATH"

if [ "$(uname -s)" = "Linux" ]; then
    USER_UID="$(id -u)"; USER_GID="$(id -g)"
else
    USER_UID=1000; USER_GID=1000
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
echo "Applying containers/$NAME.yml → dev-agent-$NAME"
echo "  ports='${HOST_MCP_PORTS:-none}' egress='${EGRESS:-none}' mem=$MEM_LIMIT"

CONTAINER_NAME="$NAME" \
USER_UID="$USER_UID" USER_GID="$USER_GID" \
SHARED_PATH="$SHARED_PATH" \
FORGE_AUTH_PATH="$FORGE_AUTH_PATH" FORGE_AUTH_MOUNT="$FORGE_AUTH_MOUNT" \
GIT_USER_NAME="$GIT_USER_NAME" GIT_USER_EMAIL="$GIT_USER_EMAIL" \
INSTALL_CLAUDE="$INSTALL_CLAUDE" INSTALL_CODEX="$INSTALL_CODEX" \
INSTALL_PI="$INSTALL_PI" INSTALL_GEMINI="$INSTALL_GEMINI" \
INSTALL_CURSOR="$INSTALL_CURSOR" INSTALL_AIDER="$INSTALL_AIDER" \
HOST_MCP_PORTS="$HOST_MCP_PORTS" EXTRA_ALLOWED_DOMAINS="$EGRESS" \
KEYS_PATH="$KEYS_PATH" ARTIFACTS_PATH="$ARTIFACTS_PATH" MEM_LIMIT="$MEM_LIMIT" \
docker compose -p "dev-agent-$NAME" -f "$SCRIPT_DIR/docker-compose.local.yml" up -d --build

# ── Wait for entrypoint/firewall ──────────────────────────────────────────────
i=0
while [ $i -lt 24 ]; do
    STATUS="$(docker inspect -f '{{.State.Status}}' "dev-agent-$NAME" 2>/dev/null || echo missing)"
    if [ "$STATUS" = "exited" ] || [ "$STATUS" = "missing" ]; then
        echo "Error: container failed to start. Logs:"
        docker logs "dev-agent-$NAME" 2>&1 | tail -20
        exit 1
    fi
    docker logs "dev-agent-$NAME" 2>&1 | grep -q "firewall active\|firewall DISABLED" && break
    sleep 5
    i=$((i + 1))
done

# ── Bootstrap workspace (idempotent) ──────────────────────────────────────────
if [ -n "$REPO_URL" ]; then
    docker exec -u coder "dev-agent-$NAME" bash -c \
        "[ -d /workspace/main/.git ] || git clone '$REPO_URL' /workspace/main" \
        || echo "WARNING: clone failed (private repo? clone manually inside)"
else
    docker exec -u coder "dev-agent-$NAME" bash -c \
        "[ -d /workspace/main/.git ] || git init -b main /workspace/main"
fi

docker exec -u coder "dev-agent-$NAME" bash -c '
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

docker cp "$SCRIPT_DIR/workspace.CLAUDE.md" "dev-agent-$NAME:/workspace/CLAUDE.md"
docker exec "dev-agent-$NAME" chown coder:coder /workspace/CLAUDE.md

# ── Generate .mcp.json (Claude only; ${VAR} refs, values via shims) ──────────
# Regenerated on every up UNLESS the repo brought its own (no marker file).
HAS_OBSIDIAN=false
for a in $OBS_AGENTS; do [ "$a" = "claude" ] && HAS_OBSIDIAN=true; done

docker exec -u coder \
    -e WANT_GATEWAY="$CAP_GATEWAY" -e WANT_PROXYMAN="$CAP_PROXYMAN" \
    -e WANT_BROWSER="$CAP_BROWSER" -e WANT_OBSIDIAN="$HAS_OBSIDIAN" \
    "dev-agent-$NAME" bash -c '
if [ -f /workspace/main/.mcp.json ] && [ ! -f /workspace/.mcp.generated ]; then
    echo "  (repo ships its own .mcp.json — leaving it alone)"
    exit 0
fi
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
touch /workspace/.mcp.generated
echo "  ✓ .mcp.json generated ($(echo "$J" | jq -r ".mcpServers | keys | join(\", \")"))"
'

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-$NAME is up (manifest: containers/$NAME.yml)"
echo ""
echo "  VS Code / Cursor:  Dev Containers: Attach to Running Container"
echo "  Terminal:          docker exec -it -u coder dev-agent-$NAME bash"
echo "  Claude:            cd /workspace/main && claude"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
