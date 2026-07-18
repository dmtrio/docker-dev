#!/bin/bash
# up.sh <name> — declaratively create or update an agent dev container from
# containers/<name>.yml. Idempotent: edit the manifest, rerun, done.
#
# Kept:     the manifest (containers/*.yml) and ~/dev-agent/secrets.env
# Derived:  ~/dev-agent/keys/<name>/ (recomposed every run), the container,
#           generated .mcp.json / dev.code-workspace / workspace CLAUDE.md
# Survives: workspace volume (code), ~/dev-agent/artifacts/<name>/
#
# Requires: docker, yq (brew install yq / static binary on Linux); the config
# wiring runs in-container via the baked-in src/wire_plugins.py (python3).

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
. "$SCRIPT_DIR/common.sh"   # sources ./.env, sets BASE_PATH (the dev-agent home)

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

mkdir -p "$BASE_PATH"   # create the dev-agent home now that we're proceeding
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
EGRESS_CIDRS=$(yq -r '(.capabilities.egress_cidrs // []) | join(",")' "$MANIFEST")

# Plugins: baked-in local stdio MCP tools, one plugins/<name>.yml each (see
# that dir). Binaries are baked into the image at build; listing a name here
# only WIRES it for this container (mcp entry + egress). Validate every name
# before touching anything: names become file paths, so restrict the charset,
# and a listed plugin without a file is a manifest typo — hard-fail.
# The tag check catches the natural scalar typo (plugins: serena), which
# would otherwise die inside yq's join() with a cryptic error.
if [ "$(yq '.plugins // [] | tag' "$MANIFEST")" != "!!seq" ]; then
    echo "Error: manifest plugins: must be a list, e.g. plugins: [serena]"; exit 1
fi
PLUGINS=$(yq -r '(.plugins // []) | join(" ")' "$MANIFEST")
PLUGIN_ERRORS=""
for p in $PLUGINS; do
    if ! printf '%s' "$p" | grep -qE '^[A-Za-z0-9_-]+$'; then
        PLUGIN_ERRORS="$PLUGIN_ERRORS
  plugin '$p': illegal characters (allowed: letters, digits, underscore, dash)"
        continue
    fi
    if [ ! -f "$SCRIPT_DIR/plugins/$p.yml" ]; then
        PLUGIN_ERRORS="$PLUGIN_ERRORS
  plugin '$p': no plugin file at plugins/$p.yml"
    fi
done
if [ -n "$PLUGIN_ERRORS" ]; then
    echo "Error: manifest plugins failed validation:$PLUGIN_ERRORS"
    exit 1
fi

# Optional ssh: section — same image/manifest everywhere; SSH is just a
# deploy capability (homelab/VPS editor access via Remote-SSH).
SSH_PORT=$(Y '.ssh.port')
SSH_BIND=$(Y '.ssh.bind'); SSH_BIND="${SSH_BIND:-127.0.0.1}"
COMPOSE_FILES="-f $SCRIPT_DIR/docker-compose.local.yml"
[ -n "$SSH_PORT" ] && COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.ssh.yml"
# (the missing-key case is a hard failure just before compose up, below)
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

# Validate ALL identity refs before touching anything (hard fail on error).
# Refs must be [A-Za-z0-9_] only — they become bash var-name suffixes, so a
# dash (parsed as the ${var-default} operator) or $(...) would corrupt the
# lookup or execute code. Values are read with indirect expansion, never eval.
IDENTITY_ERRORS=""
check_ref() {  # kind  secret_prefix  ref
    local kind="$1" prefix="$2" ref="$3" var val
    if ! printf '%s' "$ref" | grep -qE '^[A-Za-z0-9_]+$'; then
        IDENTITY_ERRORS="$IDENTITY_ERRORS
  $kind ref '$ref': illegal characters (allowed: letters, digits, underscore)"
        return
    fi
    if [ -z "$(agent_for_ref "$ref")" ]; then
        IDENTITY_ERRORS="$IDENTITY_ERRORS
  $kind ref '$ref': suffix is not a known agent (_claude/_codex/_pi/_gemini/_cursor_agent)"
        return
    fi
    var="${prefix}_${ref}"; val="${!var:-}"
    if [ -z "$val" ]; then
        IDENTITY_ERRORS="$IDENTITY_ERRORS
  $kind ref '$ref': ${var} not found in $SECRETS_FILE"
    fi
    return 0  # never let a false test become the function's exit (set -e)
}
for ref in $OBS_REFS;   do check_ref obsidian OBSIDIAN_KEY "$ref"; done
for ref in $WATCH_REFS; do check_ref watch OBSIDIAN_WATCH_KEY "$ref"; done
if [ -n "$IDENTITY_ERRORS" ]; then
    echo "Error: manifest identity references failed validation:$IDENTITY_ERRORS"
    exit 1
fi

HOST_MCP_PORTS=""
[ "$CAP_GATEWAY" = "true" ]  && HOST_MCP_PORTS="$HOST_MCP_PORTS,8811"
[ "$CAP_PROXYMAN" = "true" ] && HOST_MCP_PORTS="$HOST_MCP_PORTS,8813"
[ "$CAP_BROWSER" = "true" ]  && HOST_MCP_PORTS="$HOST_MCP_PORTS,8814"
HOST_MCP_PORTS="${HOST_MCP_PORTS#,}"

# Append a domain to EGRESS if not already present. -F: the domain is a
# literal, not a regex — an unescaped dot would let lookalike entries
# (api-foo.com vs api.foo.com) falsely satisfy the check and silently drop
# the real domain from the firewall list.
add_egress_domain() {
    echo ",$EGRESS," | grep -qF ",$1," || EGRESS="${EGRESS:+$EGRESS,}$1"
}

# Obsidian identities imply the Annotated endpoint in the egress allowlist
[ -n "$OBS_REFS" ] && add_egress_domain mcp-obsidian.dmetr.io

# Fold each enabled plugin's egress into the firewall list, and collect its
# mcp block as one-line JSON (host side only extracts — the merges into the
# agent configs run in-container via wire_plugins.py, keeping the host
# dependency at just yq). Entries accumulate newline-separated; the payload
# assembly below joins them into a JSON array.
# Egress entries are validated as bare hostnames (same rule as
# allow-egress.sh): junk would otherwise ride into dnsmasq.conf and
# crash-loop the container at boot with only a generic firewall error.
# set -f: the unquoted expansion must not glob a wildcard entry like
# *.foo.com against the CWD — let it reach validation and fail by name.
#
# The mcp server entries are validated here too (still yq-only, and BEFORE
# the image build so a bad manifest fails in seconds, not minutes):
# - names must be [A-Za-z0-9_-]: they are wired as bare TOML keys into
#   codex's config.toml, where a dot or space breaks the whole file;
# - generated server names are reserved — the per-agent merges below are
#   last-wins, so a plugin adopting e.g. obsidian-annotated would silently
#   shadow a pre-approved or identity-bearing entry (including identities
#   the Claude-path collision check never sees, like a cursor-only ref);
# - entries carry ONLY command + args, so every agent — including codex's
#   TOML rendering, which knows exactly those two fields — wires the exact
#   same server (a field like env: silently working in four agents and
#   dropped in the fifth is worse than an error here);
# - a server name defined by two enabled plugins would last-wins-merge
#   silently in the agent configs, so duplicates hard-fail (wire_plugins.py
#   re-checks this in-container, but failing here is faster: BEFORE the
#   image build, not minutes into it).
PLUGIN_MCP_ENTRIES=""
PLUGIN_MCP_NAMES=""
set -f
for p in $PLUGINS; do
    for d in $(yq -r '(.egress // []) | join(" ")' "$SCRIPT_DIR/plugins/$p.yml"); do
        if ! printf '%s' "$d" | grep -qE '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$'; then
            echo "Error: plugin '$p' egress entry '$d' is not a bare hostname (no scheme, path, port, or wildcard — a domain already covers its subdomains)"
            exit 1
        fi
        add_egress_domain "$d"
    done
    MCP_ROWS=$(yq -r '(.mcp // {}) | to_entries[] | [.key, (.value.command | type), ([.value | keys | .[] | select(. != "command" and . != "args")] | join(","))] | @tsv' "$SCRIPT_DIR/plugins/$p.yml")
    while IFS=$'\t' read -r n ctype extra; do
        [ -n "$n" ] || continue
        if ! printf '%s' "$n" | grep -qE '^[A-Za-z0-9_-]+$'; then
            echo "Error: plugin '$p' mcp server '$n': illegal characters in name (allowed: letters, digits, underscore, dash — it becomes a TOML/JSON key)"; exit 1
        fi
        case "$n" in coding|proxyman|browser|obsidian-annotated)
            echo "Error: plugin '$p' mcp server '$n': name is reserved for generated servers"; exit 1 ;;
        esac
        if [ "$ctype" != "!!str" ]; then
            echo "Error: plugin '$p' mcp server '$n': command must be a string (local stdio server)"; exit 1
        fi
        if [ -n "$extra" ]; then
            echo "Error: plugin '$p' mcp server '$n': unsupported field(s): $extra (only command and args are wired, identically for every agent)"; exit 1
        fi
        if printf '%s' " $PLUGIN_MCP_NAMES " | grep -qF " $n "; then
            echo "Error: multiple enabled plugins define the same MCP server name: $n"; exit 1
        fi
        PLUGIN_MCP_NAMES="${PLUGIN_MCP_NAMES:+$PLUGIN_MCP_NAMES }$n"
    done <<< "$MCP_ROWS"
    PLUGIN_MCP_ENTRIES="$PLUGIN_MCP_ENTRIES$(yq -o=json -I=0 '.mcp // {}' "$SCRIPT_DIR/plugins/$p.yml")
"
done
set +f

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

# Identity refs were validated above — compose them (indirect expansion, no eval)
for ref in $OBS_REFS; do
    a=$(agent_for_ref "$ref"); var="OBSIDIAN_KEY_${ref}"
    echo "OBSIDIAN_ANNOTATED_KEY=${!var}" >> "$KEYS_PATH/$a.env"
done
for ref in $WATCH_REFS; do
    a=$(agent_for_ref "$ref"); var="OBSIDIAN_WATCH_KEY_${ref}"
    echo "ANNOTATED_WATCH_KEY=${!var}" >> "$KEYS_PATH/$a.env"
done
for f in "$KEYS_PATH"/*.env; do [ -f "$f" ] && chmod 600 "$f"; done

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

# ── Apply ─────────────────────────────────────────────────────────────────────
echo "Applying containers/$NAME.yml → dev-agent-$NAME"
echo "  ports='${HOST_MCP_PORTS:-none}' egress='${EGRESS:-none}' plugins='${PLUGINS:-none}' mem=$MEM_LIMIT"

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
# pre-approval, the cursor/gemini/pi identity + plugin merges with sidecar
# stale-tracking, codex's managed TOML block — lives in src/wire_plugins.py
# (baked into the image, unit-tested by tests/test_wire_plugins.py). It reads
# ONE JSON payload on stdin. Identity keys never enter the payload: they
# travel as docker-exec env vars the payload references by name.
HAS_OBSIDIAN=false
for ref in $OBS_REFS; do [ "$(agent_for_ref "$ref")" = "claude" ] && HAS_OBSIDIAN=true; done

IDENTITY_ENV=()
IDENTITIES_JSON=""
i=0
for ref in $OBS_REFS; do
    a=$(agent_for_ref "$ref"); var="OBSIDIAN_KEY_${ref}"
    IDENTITY_ENV+=(-e "IDENTITY_KEY_${i}=${!var}")
    IDENTITIES_JSON="${IDENTITIES_JSON:+$IDENTITIES_JSON,}{\"agent\":\"$a\",\"key_env\":\"IDENTITY_KEY_$i\"}"
    i=$((i + 1))
done

# Safe to assemble with printf: the plugin entries are one-line JSON objects
# (yq -o=json -I=0 above, newline-separated — paste joins them into a JSON
# array), the booleans are yq true/false output, and agent names come from
# the fixed agent_for_ref case list. Nothing free-form is interpolated.
PLUGIN_ENTRIES_JSON=$(printf '%s' "$PLUGIN_MCP_ENTRIES" | paste -sd, -)
PAYLOAD=$(printf '{"wire":{"cursor":%s,"gemini":%s,"pi":%s,"codex":%s},"capabilities":{"gateway":%s,"proxyman":%s,"browser":%s,"obsidian":%s},"plugin_mcp_entries":[%s],"identities":[%s]}' \
    "$INSTALL_CURSOR" "$INSTALL_GEMINI" "$INSTALL_PI" "$INSTALL_CODEX" \
    "$CAP_GATEWAY" "$CAP_PROXYMAN" "$CAP_BROWSER" "$HAS_OBSIDIAN" \
    "$PLUGIN_ENTRIES_JSON" "$IDENTITIES_JSON")

printf '%s' "$PAYLOAD" | docker exec -i -u coder "${IDENTITY_ENV[@]}" "dev-agent-$NAME" \
    python3 /usr/local/lib/dev-agent/wire_plugins.py

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  dev-agent-$NAME is up (manifest: containers/$NAME.yml)"
echo ""
echo "  VS Code / Cursor:  Dev Containers: Attach to Running Container"
echo "  Terminal:          docker exec -it -u coder dev-agent-$NAME bash"
echo "  Claude:            cd /workspace/main && claude"
[ -n "$SSH_PORT" ] && echo "  SSH:               ssh -p $SSH_PORT coder@$( [ "$SSH_BIND" = "127.0.0.1" ] && echo localhost || echo '<this-host>' )"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
