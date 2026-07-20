#!/bin/bash
# up.sh <name> — declaratively create or update an agent dev container from
# containers/<name>.yml. Idempotent: edit the manifest, rerun, done.
#
# Kept:     the manifest (containers/*.yml) and ~/dev-agent/secrets.env
# Derived:  ~/dev-agent/keys/<name>/ (recomposed every run), the container,
#           generated .mcp.json / dev.code-workspace / workspace CLAUDE.md
# Survives: workspace volume (code), ~/dev-agent/artifacts/<name>/
#
# Requires: docker, yq (brew install yq / static binary on Linux), python3
# (stdlib only — owns ALL manifest validation/derivation via src/manifest.py
# and builds the wiring payload; yq only converts YAML→JSON. The wiring
# itself runs in-container via the baked-in src/wire_plugins.py).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCRIPT_DIR/common.sh"   # sources ./.env, sets BASE_PATH (the dev-agent home)

NAME="$1"
if [ -z "$NAME" ]; then
    echo "Usage: ./up.sh <name>    (reads $CONTAINERS_PATH/<name>.yml)"
    echo "Manifests:"
    for f in "$CONTAINERS_PATH"/*.yml; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .yml)
        [ "$n" = "TEMPLATE" ] && continue
        printf "  %s\n" "$n"
    done
    exit 1
fi

# CONTAINERS_PATH (resolved in common.sh) is where manifests live: the repo's
# containers/ by default, or $BASE_PATH/containers / a CONTAINERS_PATH override
# when you keep them in a private repo outside this one.
MANIFEST="$CONTAINERS_PATH/$NAME.yml"
[ -f "$MANIFEST" ] || { echo "Error: no manifest at $MANIFEST (cp $SCRIPT_DIR/containers/TEMPLATE.yml $MANIFEST)"; exit 1; }
command -v yq >/dev/null || { echo "Error: yq required (brew install yq)"; exit 1; }
# Host python3 (stdlib-only, builds the wiring payload): prefer the SYSTEM
# interpreter over whatever shim leads $PATH — pyenv/homebrew pythons can be
# present-but-broken (dyld: library not loaded) in ways `command -v` cannot
# see, so each candidate must actually RUN. Override with PYTHON3=/path.
if [ -z "${PYTHON3:-}" ]; then
    for cand in /usr/bin/python3 python3; do
        if "$cand" -c '' 2>/dev/null; then PYTHON3="$cand"; break; fi
    done
fi
[ -n "${PYTHON3:-}" ] && "$PYTHON3" -c '' 2>/dev/null \
    || { echo "Error: no working python3 (tried /usr/bin/python3 and PATH — broken pyenv/brew shim? Install Xcode CLT on macOS, or set PYTHON3=/path/to/python3)"; exit 1; }

mkdir -p "$BASE_PATH"   # create the dev-agent home now that we're proceeding
SHARED_PATH="$BASE_PATH/shared"
SECRETS_FILE="$BASE_PATH/secrets.env"
[ -f "$SECRETS_FILE" ] || { touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; }
. "$SECRETS_FILE"

# ── Read + validate manifest (src/manifest.py owns the rules) ────────────────
# yq only converts YAML→JSON here; every validation rule, default, and derived
# value lives in src/manifest.py (unit-tested table-driven — named errors
# instead of cryptic yq failures). Secret VALUES stay out of the call: it
# receives only the NAMES of the identity key vars that are set, plus
# NTFY_URL/NTFY_TOPIC which the manifest may route into the container.
SECRET_KEY_VARS=""
for v in $(compgen -v | grep -E '^OBSIDIAN_(WATCH_)?KEY_' || true); do
    if [ -n "${!v}" ]; then SECRET_KEY_VARS="${SECRET_KEY_VARS:+$SECRET_KEY_VARS }$v"; fi
done
DERIVED=$(
    {
        yq -o=json -I=0 "$MANIFEST"
        for f in "$SCRIPT_DIR/plugins"/*.yml; do
            [ -e "$f" ] || continue
            # '!' = unreadable. manifest.py errors on it ONLY when the
            # manifest lists that plugin — a broken/WIP file in plugins/
            # must not block bring-up of containers that never use it.
            DOC=$(yq -o=json -I=0 "$f" 2>/dev/null) \
                && [ "$(printf '%s\n' "$DOC" | wc -l)" -eq 1 ] || DOC='!'
            printf '%s\t%s\n' "$(basename "$f" .yml)" "$DOC"
        done
    } | SECRET_KEY_VARS="$SECRET_KEY_VARS" SECRETS_FILE="$SECRETS_FILE" \
        GIT_NAME_DEFAULT="$(git config --global user.name 2>/dev/null || true)" \
        GIT_EMAIL_DEFAULT="$(git config --global user.email 2>/dev/null || true)" \
        NTFY_URL="${NTFY_URL:-}" NTFY_TOPIC="${NTFY_TOPIC:-}" \
        "$PYTHON3" "$SCRIPT_DIR/src/manifest.py" --derive
)
eval "$DERIVED"

COMPOSE_FILES="-f $SCRIPT_DIR/docker-compose.local.yml"
[ -n "$SSH_PORT" ] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.ssh.yml"
[ "$REMOTE_MOSH" = "true" ] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.mosh.yml"

# ── Compose derived credentials (keys/<name>/ is rebuilt from scratch) ───────
KEYS_PATH="$BASE_PATH/keys/$NAME"
mkdir -p "$KEYS_PATH"; chmod 700 "$KEYS_PATH"
rm -f "$KEYS_PATH"/*.env

# One COMPLETE env file per shim agent (Plugins v2 Phase 3 — common.env retired).
# Each shim (baked into the image; SHIM_AGENTS must match the Dockerfile loop)
# sources only its own <agent>.env, so that file carries everything the agent
# sees. The composition logic lives in src/compose-keys.sh (sourced here, and
# unit-tested by tests/bash.test.sh) so the real code is exercised in tests, not
# mirrored; up.sh only routes the derived vars (NAMES) into it — the ${!source}
# value lookups happen against the secrets.env this shell already sourced.
SHIM_AGENTS="claude pi gemini cursor-agent codex"
. "$SCRIPT_DIR/src/compose-keys.sh"
compose_keys "$KEYS_PATH" "$SHIM_AGENTS" "$PLUGIN_ENV_SECRETS" "$AGENT_SECRETS"

# ── Host paths + platform ─────────────────────────────────────────────────────
ARTIFACTS_PATH="$BASE_PATH/artifacts/$NAME"
mkdir -p "$ARTIFACTS_PATH"
# Rules: RULES_PATH override (set in ./.env) → your existing $BASE_PATH/rules
# → the bundled repo rules. The bundled default makes a fresh clone runnable;
# point RULES_PATH at your own rules repo to override (the agent-conf usecase).
RULES_BUNDLED=0
if [ -z "${RULES_PATH:-}" ]; then
    if [ -d "$BASE_PATH/rules" ]; then RULES_PATH="$BASE_PATH/rules"
    else RULES_PATH="$SCRIPT_DIR/rules"; RULES_BUNDLED=1; fi
fi
[ -d "$RULES_PATH" ] || { echo "Error: RULES_PATH '$RULES_PATH' does not exist"; exit 1; }
# Resolve symlinks: Docker Desktop cannot use a symlink as a bind source
RULES_PATH="$(cd "$RULES_PATH" && pwd -P)"
# Keep an EXTERNAL rules repo current (merged rule PRs land here). Never pull
# the bundled copy — it lives inside THIS repo, so a pull would pull docker-dev.
# The flag is set where the fallback is chosen, so it's robust to symlinks that
# would make a post-hoc path comparison misfire.
[ "$RULES_BUNDLED" = 1 ] || git -C "$RULES_PATH" pull --ff-only -q 2>/dev/null || true

if [ "$(uname -s)" = "Linux" ]; then
    USER_UID="$(id -u)"; USER_GID="$(id -g)"
else
    USER_UID=1000; USER_GID=1000
fi

# ── SSH preflight check ──────────────────────────────────────────────────────
if [ -n "$SSH_PORT" ] && [ -z "${SSH_AUTHORIZED_KEY:-}" ]; then
    echo "Error: manifest has ssh.port but SSH_AUTHORIZED_KEY is missing from secrets.env"; exit 1
fi

# ── Shared network (all containers; single CIDR for VPN/tunnel targeting) ───
# One user-defined bridge with a stable subnet (override via DEV_AGENT_SUBNET
# in ./.env). Existing containers adopt it on their next recreate.
DESIRED_SUBNET="${DEV_AGENT_SUBNET:-172.30.0.0/24}"
if docker network inspect dev-agent-net >/dev/null 2>&1; then
    # The subnet is fixed at creation — warn loudly if the override drifted,
    # or the operator points their VPN route at a CIDR no container is on.
    ACTUAL_SUBNET=$(docker network inspect -f '{{(index .IPAM.Config 0).Subnet}}' dev-agent-net 2>/dev/null || true)
    if [ -n "$ACTUAL_SUBNET" ] && [ "$ACTUAL_SUBNET" != "$DESIRED_SUBNET" ]; then
        echo "  ⚠ dev-agent-net already exists with subnet $ACTUAL_SUBNET (config wants $DESIRED_SUBNET)."
        echo "    To change it: stop all dev-agent containers, 'docker network rm dev-agent-net', rerun up.sh."
    fi
else
    echo "Creating shared network dev-agent-net ($DESIRED_SUBNET)"
    # `|| inspect` tolerates losing a create race to a concurrent up.sh run.
    if ! docker network create --subnet "$DESIRED_SUBNET" dev-agent-net >/dev/null 2>&1 \
        && ! docker network inspect dev-agent-net >/dev/null 2>&1; then
        echo "Error: could not create dev-agent-net ($DESIRED_SUBNET) — the subnet may overlap an existing docker network."
        echo "Pick a free range via DEV_AGENT_SUBNET in ./.env (docker auto-allocates inside 172.17-172.31)."
        exit 1
    fi
fi

# ── Apply ─────────────────────────────────────────────────────────────────────
echo "Applying $MANIFEST → dev-agent-$NAME"
REMOTE_SUMMARY=""
[ "$REMOTE_TMUX" = "true" ] && REMOTE_SUMMARY="tmux"
[ "$REMOTE_MOSH" = "true" ] && REMOTE_SUMMARY="${REMOTE_SUMMARY:+$REMOTE_SUMMARY+}mosh"
[ -n "$REMOTE_NOTIFY" ]     && REMOTE_SUMMARY="${REMOTE_SUMMARY:+$REMOTE_SUMMARY+}$REMOTE_NOTIFY"
echo "  ports='${HOST_MCP_PORTS:-none}' egress='${EGRESS:-none}' plugins='${PLUGINS:-none}' remote='${REMOTE_SUMMARY:-none}' mem=$MEM_LIMIT"

CONTAINER_NAME="$NAME" \
USER_UID="$USER_UID" USER_GID="$USER_GID" \
RULES_PATH="$RULES_PATH" \
GIT_USER_NAME="$GIT_USER_NAME" GIT_USER_EMAIL="$GIT_USER_EMAIL" \
INSTALL_CLAUDE="$INSTALL_CLAUDE" INSTALL_CODEX="$INSTALL_CODEX" \
INSTALL_PI="$INSTALL_PI" INSTALL_GEMINI="$INSTALL_GEMINI" \
INSTALL_CURSOR="$INSTALL_CURSOR" INSTALL_AIDER="$INSTALL_AIDER" \
HOST_MCP_PORTS="$HOST_MCP_PORTS" EXTRA_ALLOWED_DOMAINS="$EGRESS" \
ALLOWED_CIDRS="$EGRESS_CIDRS" \
KEYS_PATH="$KEYS_PATH" ARTIFACTS_PATH="$ARTIFACTS_PATH" MEM_LIMIT="$MEM_LIMIT" \
SSH_PORT="$SSH_PORT" SSH_BIND="$SSH_BIND" SSH_AUTHORIZED_KEY="${SSH_AUTHORIZED_KEY:-}" \
REMOTE_TMUX="$REMOTE_TMUX" \
MOSH_PORTS="$MOSH_PORTS" MOSH_PORTS_DASH="$MOSH_PORTS_DASH" \
NTFY_URL="$CONTAINER_NTFY_URL" NTFY_TOPIC="$CONTAINER_NTFY_TOPIC" \
IMAGE_TAG="$NAME" \
docker compose -p "dev-agent-$NAME" $COMPOSE_FILES up -d --build

# ── Wait for entrypoint/firewall ──────────────────────────────────────────────
# Crash-loop detection compares against the restart count captured now (0 for
# a freshly (re)created container; the current value for a healthy no-op
# re-up). A rise DURING the wait = a crash loop this run — which also catches
# the SSH-missing-key case where 'firewall active' prints before the fatal
# exit (the marker alone would falsely read as success).
BASELINE_RESTARTS="$(docker inspect -f '{{.RestartCount}}' "dev-agent-$NAME" 2>/dev/null || echo 0)"
i=0
READY=false
while [ $i -lt 24 ]; do
    STATUS="$(docker inspect -f '{{.State.Status}}' "dev-agent-$NAME" 2>/dev/null || echo missing)"
    if [ "$STATUS" = "exited" ] || [ "$STATUS" = "missing" ] || [ "$STATUS" = "restarting" ]; then
        echo "Error: container failed to start. Logs:"
        docker logs "dev-agent-$NAME" 2>&1 | tail -20
        exit 1
    fi
    RESTART_COUNT="$(docker inspect -f '{{.RestartCount}}' "dev-agent-$NAME" 2>/dev/null || echo 0)"
    if [ "$RESTART_COUNT" -gt "$BASELINE_RESTARTS" ]; then
        echo "Error: container crash-loop detected (restarts rose to $RESTART_COUNT). Logs:"
        docker logs "dev-agent-$NAME" 2>&1 | tail -20
        exit 1
    fi
    if docker logs "dev-agent-$NAME" 2>&1 | grep -q "firewall active\|firewall DISABLED"; then
        # The marker persists in logs across restarts, so a crashing boot can
        # print it too. Confirm the container is actually STABLE: still running
        # and no new restart 2s later. A crash loop keeps incrementing, so this
        # catches a container that logged the marker then died.
        sleep 2
        CONFIRM_STATUS="$(docker inspect -f '{{.State.Status}}' "dev-agent-$NAME" 2>/dev/null || echo missing)"
        CONFIRM_RESTARTS="$(docker inspect -f '{{.RestartCount}}' "dev-agent-$NAME" 2>/dev/null || echo 0)"
        if [ "$CONFIRM_STATUS" != "running" ] || [ "$CONFIRM_RESTARTS" -gt "$BASELINE_RESTARTS" ]; then
            echo "Error: container crash-loop detected (unstable after readiness marker). Logs:"
            docker logs "dev-agent-$NAME" 2>&1 | tail -20
            exit 1
        fi
        READY=true
        break
    fi
    sleep 5
    i=$((i + 1))
done

if [ "$READY" = "false" ]; then
    echo "Error: container did not reach readiness (timeout). Logs:"
    docker logs "dev-agent-$NAME" 2>&1 | tail -20
    exit 1
fi

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

# ── Wire agent MCP configs (one exec into the baked-in Python module) ────────
# All the config-file surgery — Claude's .mcp.json generation + ~/.claude.json
# pre-approval, the per-agent agent-scoped server rendering + plugin merges with
# sidecar stale-tracking, codex's managed TOML block — lives in
# src/wire_plugins.py (baked into the image, unit-tested by
# tests/test_wire_plugins.py). The SAME file also builds the JSON payload
# (--build-payload, host python3), so the schema and strict boolean semantics
# live in one tested place; bash only routes env vars. Keys never enter the
# payload: they travel as docker-exec env vars the payload references by name —
# and only for cursor-agent/gemini/pi (claude expands the ${VAR} ref from its
# shim env; codex is a pending warning and ships no key at all).
#
# Build the per-agent inputs for agent-scoped SERVERS from AGENT_SECRETS. Only
# slots with an actual server (AGENT_SERVER_SLOTS) need wiring — an env-only
# slot (a watch key) was already delivered into <agent>.env above and has
# nothing to render. Triples are "agent:key_env:slot"; claude/codex carry an
# empty key_env (claude uses the ref, codex is warned).
IDENTITY_ENV=()
IDENTITY_AGENTS=""
i=0
while IFS=$'\t' read -r agent slot source; do
    [ -n "$agent" ] || continue
    case " $AGENT_SERVER_SLOTS " in *" $slot "*) ;; *) continue ;; esac
    case "$agent" in
        claude|codex)
            IDENTITY_AGENTS="${IDENTITY_AGENTS:+$IDENTITY_AGENTS }$agent::$slot" ;;
        *)
            IDENTITY_ENV+=(-e "IDENTITY_KEY_${i}=${!source}")
            IDENTITY_AGENTS="${IDENTITY_AGENTS:+$IDENTITY_AGENTS }$agent:IDENTITY_KEY_$i:$slot"
            i=$((i + 1)) ;;
    esac
done <<EOF
$AGENT_SECRETS
EOF

PAYLOAD=$(WIRE_CURSOR="$INSTALL_CURSOR" WIRE_GEMINI="$INSTALL_GEMINI" \
    WIRE_PI="$INSTALL_PI" WIRE_CODEX="$INSTALL_CODEX" \
    PLUGIN_MCP_ENTRIES="$PLUGIN_MCP_ENTRIES" \
    AGENT_SERVERS_JSON="$AGENT_SERVERS_JSON" IDENTITY_AGENTS="$IDENTITY_AGENTS" \
    "$PYTHON3" "$SCRIPT_DIR/src/wire_plugins.py" --build-payload)

printf '%s' "$PAYLOAD" | docker exec -i -u coder "${IDENTITY_ENV[@]}" "dev-agent-$NAME" \
    python3 /usr/local/lib/dev-agent/wire_plugins.py

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-$NAME is up (manifest: $MANIFEST)"
echo ""
echo "  VS Code / Cursor:  Dev Containers: Attach to Running Container"
echo "  Terminal:          docker exec -it -u coder dev-agent-$NAME bash"
echo "  Claude:            cd /workspace/main && claude"
[ -n "$SSH_PORT" ] && echo "  SSH:               ssh -p $SSH_PORT coder@$( [ "$SSH_BIND" = "127.0.0.1" ] && echo localhost || echo '<this-host>' )"
if [ "$REMOTE_TMUX" = "true" ] || [ "$REMOTE_MOSH" = "true" ]; then
    TUNNEL_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "dev-agent-$NAME" 2>/dev/null || true)"
    echo "  Remote (tunnel):   ${TUNNEL_IP:-<no ip>} — $( [ "$REMOTE_MOSH" = "true" ] && echo "mosh coder@ip (UDP $MOSH_PORTS_DASH)" || echo "ssh coder@ip" ) over your WireGuard/VPN"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
