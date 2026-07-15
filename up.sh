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
    github|gitea) ;; # informational; auth is per-container (GH_TOKEN or in-container login)
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
OBS_REFS=$(yq -r '(.identities.obsidian // []) | join(" ")' "$MANIFEST")
WATCH_REFS=$(yq -r '(.identities.watch // []) | join(" ")' "$MANIFEST")

# Identity refs are EXPLICIT secret-name suffixes: a ref R reads
# OBSIDIAN_KEY_R (or OBSIDIAN_WATCH_KEY_R) from secrets.env, and the agent
# it belongs to is R's suffix: _claude, _codex, _pi, _gemini, _cursor_agent.
agent_for_ref() {
    case "$1" in
        *_cursor_agent) echo "cursor-agent" ;;
        *_claude)       echo "claude" ;;
        *_codex)        echo "codex" ;;
        *_pi)           echo "pi" ;;
        *_gemini)       echo "gemini" ;;
        *) echo "" ;;
    esac
}

# Validate ALL identity refs before touching anything (hard fail on error)
IDENTITY_ERRORS=""
for ref in $OBS_REFS; do
    a=$(agent_for_ref "$ref")
    [ -z "$a" ] && IDENTITY_ERRORS="$IDENTITY_ERRORS
  obsidian ref '$ref': suffix is not a known agent (_claude/_codex/_pi/_gemini/_cursor_agent)"
    eval "v=\${OBSIDIAN_KEY_$ref:-}"
    [ -n "$a" ] && [ -z "$v" ] && IDENTITY_ERRORS="$IDENTITY_ERRORS
  obsidian ref '$ref': OBSIDIAN_KEY_$ref not found in $SECRETS_FILE"
done
for ref in $WATCH_REFS; do
    a=$(agent_for_ref "$ref")
    [ -z "$a" ] && IDENTITY_ERRORS="$IDENTITY_ERRORS
  watch ref '$ref': suffix is not a known agent (_claude/_codex/_pi/_gemini/_cursor_agent)"
    eval "v=\${OBSIDIAN_WATCH_KEY_$ref:-}"
    [ -n "$a" ] && [ -z "$v" ] && IDENTITY_ERRORS="$IDENTITY_ERRORS
  watch ref '$ref': OBSIDIAN_WATCH_KEY_$ref not found in $SECRETS_FILE"
done
if [ -n "$IDENTITY_ERRORS" ]; then
    echo "Error: manifest identity references failed validation:$IDENTITY_ERRORS"
    exit 1
fi

HOST_MCP_PORTS=""
[ "$CAP_GATEWAY" = "true" ]  && HOST_MCP_PORTS="$HOST_MCP_PORTS,8811"
[ "$CAP_PROXYMAN" = "true" ] && HOST_MCP_PORTS="$HOST_MCP_PORTS,8813"
[ "$CAP_BROWSER" = "true" ]  && HOST_MCP_PORTS="$HOST_MCP_PORTS,8814"
HOST_MCP_PORTS="${HOST_MCP_PORTS#,}"

# Obsidian identities imply the Annotated endpoint in the egress allowlist
if [ -n "$OBS_REFS" ] && ! echo ",$EGRESS," | grep -q ",mcp-obsidian.dmetr.io,"; then
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

# Identity refs were validated above — compose them (values checked, present)
for ref in $OBS_REFS; do
    a=$(agent_for_ref "$ref")
    eval "v=\$OBSIDIAN_KEY_$ref"
    echo "OBSIDIAN_ANNOTATED_KEY=$v" >> "$KEYS_PATH/$a.env"
done
for ref in $WATCH_REFS; do
    a=$(agent_for_ref "$ref")
    eval "v=\$OBSIDIAN_WATCH_KEY_$ref"
    echo "ANNOTATED_WATCH_KEY=$v" >> "$KEYS_PATH/$a.env"
done
for f in "$KEYS_PATH"/*.env; do [ -f "$f" ] && chmod 600 "$f"; done

# ── Host paths + platform ─────────────────────────────────────────────────────
ARTIFACTS_PATH="$BASE_PATH/artifacts/$NAME"
RULES_PATH="$BASE_PATH/rules"
mkdir -p "$ARTIFACTS_PATH"
[ -d "$RULES_PATH" ] || { echo "Error: $RULES_PATH missing — the global rules repo is required"; exit 1; }
# Keep rules current if the repo has a remote (merged rule PRs land here)
git -C "$RULES_PATH" pull --ff-only -q 2>/dev/null || true

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
RULES_PATH="$RULES_PATH" \
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
    # The bootstrap exec isn't shim-launched, so hand it the machine-user
    # token explicitly for private-repo clones over HTTPS.
    CLONE_ENV=""
    [ -n "${GH_TOKEN:-}" ] && CLONE_ENV="-e GH_TOKEN=$GH_TOKEN"
    docker exec $CLONE_ENV -u coder "dev-agent-$NAME" bash -c \
        "[ -d /workspace/main/.git ] || git clone '$REPO_URL' /workspace/main" \
        || echo "WARNING: clone failed — private repo needs either GH_TOKEN in secrets.env (machine user must have repo access) or a one-time 'gh auth login' in the container"
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

# ── Global rules fan-out (symlinks into the read-only /agent-rules mount) ────
# One AGENTS.md source; each tool's global file points at it. Symlinks into
# a mounted DIR survive host-side editor renames. Skills shared the same way.
docker exec -u coder "dev-agent-$NAME" bash -c '
mkdir -p /home/coder/.claude /home/coder/.codex /home/coder/.gemini
ln -sfn /agent-rules/AGENTS.md /home/coder/.claude/CLAUDE.md
ln -sfn /agent-rules/AGENTS.md /home/coder/.codex/AGENTS.md
ln -sfn /agent-rules/AGENTS.md /home/coder/.gemini/GEMINI.md
[ -e /home/coder/.claude/skills ] && [ ! -L /home/coder/.claude/skills ] || ln -sfn /agent-rules/skills /home/coder/.claude/skills
if [ ! -f /workspace/rules.local.md ]; then
cat > /workspace/rules.local.md <<EOF
# rules.local.md — container-local rule overrides

Rules that are global in spirit but specific to THIS project/container.
Not committed (lives outside the repo). Loaded by all agents alongside
/agent-rules/AGENTS.md. Precedence: repo rules > this file > global rules.
EOF
fi
echo "  ✓ global rules + skills linked (read-only; changes go via PR to the rules repo)"
'

# ── Generate .mcp.json (Claude only; ${VAR} refs, values via shims) ──────────
# Regenerated on every up UNLESS the repo brought its own (no marker file).
HAS_OBSIDIAN=false
for ref in $OBS_REFS; do [ "$(agent_for_ref "$ref")" = "claude" ] && HAS_OBSIDIAN=true; done

docker exec -u coder \
    -e WANT_GATEWAY="$CAP_GATEWAY" -e WANT_PROXYMAN="$CAP_PROXYMAN" \
    -e WANT_BROWSER="$CAP_BROWSER" -e WANT_OBSIDIAN="$HAS_OBSIDIAN" \
    "dev-agent-$NAME" bash -c '
set -e
if [ ! -d /workspace/main ]; then
    echo "  (skipping .mcp.json — /workspace/main missing; fix the clone and rerun up.sh)"
    exit 0
fi
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

# ── Per-agent MCP configs beyond Claude ──────────────────────────────────────
# Cursor and Gemini cannot reliably expand env vars in headers for remote
# servers, so their configs carry the literal key: container-local home
# files, mode 600, never inside the repo, regenerated from secrets.env on
# every up (rotation flows). pi needs the pi-mcp-adapter extension for its
# file to take effect. codex is SKIPPED: ~/.codex is a shared volume, so a
# per-container identity written there would leak across containers.
for ref in $OBS_REFS; do
    a=$(agent_for_ref "$ref")
    eval "v=\$OBSIDIAN_KEY_$ref"
    case "$a" in
        cursor-agent)
            docker exec -u coder -e K="$v" "dev-agent-$NAME" bash -c '
mkdir -p /home/coder/.cursor
jq -n --arg k "$K" "{mcpServers: {\"obsidian-annotated\": {url: \"https://mcp-obsidian.dmetr.io/mcp\", headers: {Authorization: (\"Bearer \" + \$k)}}}}" > /home/coder/.cursor/mcp.json
chmod 600 /home/coder/.cursor/mcp.json
echo "  ✓ cursor-agent MCP config (literal key: env interpolation broken for remote headers)"' ;;
        gemini)
            docker exec -u coder -e K="$v" "dev-agent-$NAME" bash -c '
mkdir -p /home/coder/.gemini
if [ -f /home/coder/.gemini/settings.json ]; then
  jq --arg k "$K" ".mcpServers[\"obsidian-annotated\"] = {httpUrl: \"https://mcp-obsidian.dmetr.io/mcp\", headers: {Authorization: (\"Bearer \" + \$k)}}" /home/coder/.gemini/settings.json > /tmp/g.json && mv /tmp/g.json /home/coder/.gemini/settings.json
else
  jq -n --arg k "$K" "{mcpServers: {\"obsidian-annotated\": {httpUrl: \"https://mcp-obsidian.dmetr.io/mcp\", headers: {Authorization: (\"Bearer \" + \$k)}}}}" > /home/coder/.gemini/settings.json
fi
chmod 600 /home/coder/.gemini/settings.json
echo "  ✓ gemini MCP config (literal key: header env expansion is an open FR)"' ;;
        pi)
            docker exec -u coder -e K="$v" "dev-agent-$NAME" bash -c '
mkdir -p /home/coder/.pi/agent
jq -n --arg k "$K" "{mcpServers: {\"obsidian-annotated\": {type: \"http\", url: \"https://mcp-obsidian.dmetr.io/mcp\", headers: {Authorization: (\"Bearer \" + \$k)}}}}" > /home/coder/.pi/agent/mcp.json
chmod 600 /home/coder/.pi/agent/mcp.json
echo "  ✓ pi MCP config written (NOTE: inert until pi-mcp-adapter extension is installed — pi has no built-in MCP)"' ;;
        codex)
            echo "  ⚠ codex obsidian identity not yet wired into ~/.codex/config.toml" \
                 "(now safely container-local after the credential split — pending" \
                 "verification of codex's remote-MCP config format). Key is available" \
                 "to codex processes as OBSIDIAN_ANNOTATED_KEY via its shim." ;;
    esac
done

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-$NAME is up (manifest: containers/$NAME.yml)"
echo ""
echo "  VS Code / Cursor:  Dev Containers: Attach to Running Container"
echo "  Terminal:          docker exec -it -u coder dev-agent-$NAME bash"
echo "  Claude:            cd /workspace/main && claude"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
