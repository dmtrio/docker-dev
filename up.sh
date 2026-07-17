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

# Optional remote: section (RFC 04) — extends ssh: with a durable tmux
# session, mosh (UDP, mobile-resilient), and idle notifications. All of it
# rides the SSH login path, so remote.* without ssh.port is a manifest error.
REMOTE_TMUX=$(yq '.remote.tmux // false' "$MANIFEST")
REMOTE_MOSH=$(yq '.remote.mosh // false' "$MANIFEST")
REMOTE_NOTIFY=$(Y '.remote.notify')
if [ "$REMOTE_TMUX" = "true" ] || [ "$REMOTE_MOSH" = "true" ] || [ -n "$REMOTE_NOTIFY" ]; then
    [ -n "$SSH_PORT" ] || { echo "Error: manifest has remote: but no ssh: section — remote access rides the SSH login path (add ssh.port)"; exit 1; }
fi
case "$REMOTE_NOTIFY" in
    ""|ntfy) ;;
    *) echo "Error: remote.notify must be 'ntfy' (got '$REMOTE_NOTIFY')"; exit 1 ;;
esac
# The whole notify chain lives inside the tmux server that only remote.tmux
# auto-starts — notify without tmux would be a notifier that never fires.
if [ -n "$REMOTE_NOTIFY" ] && [ "$REMOTE_TMUX" != "true" ]; then
    echo "Error: remote.notify requires remote.tmux: true (the idle monitor runs inside the tmux session)"; exit 1
fi

# mosh gets its own overlay: the UDP range publish must not exist for
# containers that didn't opt in (compose can't publish conditionally).
# The range is per-manifest (remote.mosh_ports, START:END) because the host
# publish is per-host-port — two mosh containers on one host need disjoint
# ranges, exactly like ssh.port. up.sh is the single source: the overlay's
# publish + env, the in-image wrapper, and the firewall all derive from it.
MOSH_PORTS=""
MOSH_PORTS_DASH=""
if [ "$REMOTE_MOSH" = "true" ]; then
    MOSH_PORTS=$(Y '.remote.mosh_ports'); MOSH_PORTS="${MOSH_PORTS:-60000:60010}"
    if ! printf '%s' "$MOSH_PORTS" | grep -qE '^[0-9]{1,5}:[0-9]{1,5}$'; then
        echo "Error: remote.mosh_ports must be START:END (got '$MOSH_PORTS')"; exit 1
    fi
    MOSH_LO="${MOSH_PORTS%%:*}"; MOSH_HI="${MOSH_PORTS##*:}"
    if [ "$MOSH_LO" -gt "$MOSH_HI" ] || [ "$MOSH_HI" -gt 65535 ] || [ "$MOSH_LO" -lt 1024 ]; then
        echo "Error: remote.mosh_ports '$MOSH_PORTS' out of range (need 1024 <= START <= END <= 65535)"; exit 1
    fi
    MOSH_PORTS_DASH="$MOSH_LO-$MOSH_HI"
    COMPOSE_FILES="$COMPOSE_FILES -f $SCRIPT_DIR/docker-compose.mosh.yml"
fi
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
# mcp block as one-line JSON (host side only extracts — the additive merge
# into .mcp.json runs in-container with jq, keeping the host dependency at
# just yq). Entries accumulate newline-separated for a later `jq -s add`.
# Egress entries are validated as bare hostnames (same rule as
# allow-egress.sh): junk would otherwise ride into dnsmasq.conf and
# crash-loop the container at boot with only a generic firewall error.
# set -f: the unquoted expansion must not glob a wildcard entry like
# *.foo.com against the CWD — let it reach validation and fail by name.
PLUGIN_MCP_ENTRIES=""
set -f
for p in $PLUGINS; do
    for d in $(yq -r '(.egress // []) | join(" ")' "$SCRIPT_DIR/plugins/$p.yml"); do
        if ! printf '%s' "$d" | grep -qE '^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z][A-Za-z0-9-]{0,61}[A-Za-z0-9]$'; then
            echo "Error: plugin '$p' egress entry '$d' is not a bare hostname (no scheme, path, port, or wildcard — a domain already covers its subdomains)"
            exit 1
        fi
        add_egress_domain "$d"
    done
    PLUGIN_MCP_ENTRIES="$PLUGIN_MCP_ENTRIES$(yq -o=json -I=0 '.mcp // {}' "$SCRIPT_DIR/plugins/$p.yml")
"
done
set +f

# remote.notify: ntfy implies the ntfy host in the egress allowlist (RFC 04).
# Hard-fail on a missing URL: an explicitly requested notifier that silently
# does nothing is worse than a refused apply. -F: host is a literal, not a regex.
CONTAINER_NTFY_URL=""; CONTAINER_NTFY_TOPIC=""
if [ "$REMOTE_NOTIFY" = "ntfy" ]; then
    [ -n "${NTFY_URL:-}" ] || { echo "Error: manifest has remote.notify: ntfy but NTFY_URL is missing from $SECRETS_FILE"; exit 1; }
    # The value travels via /etc/environment, whose PAM parser truncates at
    # '#' and strips quotes — refuse values that would be silently mangled.
    case "$NTFY_URL" in
        *'#'*|*'"'*|*"'"*) echo "Error: NTFY_URL must be a bare origin (no '#', quotes) — put the topic in NTFY_TOPIC"; exit 1 ;;
    esac
    # Host = URL minus scheme, path, userinfo, port (in that order — the
    # path strip must precede the userinfo strip so an '@' in a path can't
    # masquerade as userinfo).
    NTFY_HOST=$(printf '%s' "$NTFY_URL" | sed -E 's|^[A-Za-z]+://||; s|/.*$||; s|^.*@||; s|:[0-9]+$||')
    [ -n "$NTFY_HOST" ] || { echo "Error: cannot parse a host from NTFY_URL '$NTFY_URL'"; exit 1; }
    if printf '%s' "$NTFY_HOST" | grep -qE '^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$'; then
        # IP literal: the domain allowlist is dnsmasq-driven (IPs enter the
        # ipset only via observed DNS answers), so an IP host must go through
        # the CIDR path or the push is silently firewalled.
        echo ",$EGRESS_CIDRS," | grep -qF ",$NTFY_HOST/32," \
            || EGRESS_CIDRS="${EGRESS_CIDRS:+$EGRESS_CIDRS,}$NTFY_HOST/32"
    else
        echo ",$EGRESS," | grep -qF ",$NTFY_HOST," \
            || EGRESS="${EGRESS:+$EGRESS,}$NTFY_HOST"
    fi
    CONTAINER_NTFY_URL="$NTFY_URL"
    CONTAINER_NTFY_TOPIC="${NTFY_TOPIC:-}"
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
echo "Applying containers/$NAME.yml → dev-agent-$NAME"
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

# ── Generate .mcp.json (Claude only; ${VAR} refs, values via shims) ──────────
# Regenerated on every up UNLESS the repo brought its own (no marker file).
HAS_OBSIDIAN=false
for ref in $OBS_REFS; do [ "$(agent_for_ref "$ref")" = "claude" ] && HAS_OBSIDIAN=true; done

docker exec -u coder \
    -e WANT_GATEWAY="$CAP_GATEWAY" -e WANT_PROXYMAN="$CAP_PROXYMAN" \
    -e WANT_BROWSER="$CAP_BROWSER" -e WANT_OBSIDIAN="$HAS_OBSIDIAN" \
    -e PLUGIN_MCP="$PLUGIN_MCP_ENTRIES" \
    "dev-agent-$NAME" bash -c '
set -e
# Gate on the repo (.git), not just the dir: the entrypoint always creates an
# empty /workspace/main so editors can attach, but on a failed private-repo
# clone it stays empty and .git-less. Writing .mcp.json there would make the
# dir non-empty and break the clone retry on the next up.sh run — so skip.
if [ ! -d /workspace/main/.git ]; then
    echo "  (skipping .mcp.json — /workspace/main has no repo yet; fix the clone and rerun up.sh)"
    exit 0
fi
if [ -f /workspace/main/.mcp.json ] && [ ! -f /workspace/.mcp.generated ]; then
    echo "  (repo ships its own .mcp.json — leaving it alone; manifest capabilities/plugins are NOT merged into it)"
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
# Plugins: PLUGIN_MCP is newline-separated one-line JSON objects (one per
# enabled plugin, extracted host-side with yq). Slurp-add merges them into a
# single object, then fold that into mcpServers additively. Both merges are
# last-wins, so name collisions — two plugins sharing a server name, or a
# plugin shadowing a generated capability server (and inheriting its
# pre-approval) — must hard-fail instead of silently replacing an entry.
if [ -n "$PLUGIN_MCP" ]; then
  DUP=$(printf "%s" "$PLUGIN_MCP" | jq -rs "[.[] | keys[]] | group_by(.) | map(select(length > 1) | .[0]) | join(\", \")")
  if [ -n "$DUP" ]; then
    echo "Error: multiple enabled plugins define the same MCP server name(s): $DUP"; exit 1
  fi
  PLUGINS_OBJ=$(printf "%s" "$PLUGIN_MCP" | jq -s "add // {}")
  CLASH=$(echo "$J" | jq -r --argjson p "$PLUGINS_OBJ" "(.mcpServers | keys) as \$k | \$p | keys | map(select(. as \$n | \$k | index(\$n))) | join(\", \")")
  if [ -n "$CLASH" ]; then
    echo "Error: plugin MCP server name(s) collide with generated servers: $CLASH"; exit 1
  fi
  J=$(echo "$J" | jq --argjson p "$PLUGINS_OBJ" ".mcpServers += \$p")
fi
echo "$J" | jq . > /workspace/main/.mcp.json
touch /workspace/.mcp.generated
echo "  ✓ .mcp.json generated ($(echo "$J" | jq -r ".mcpServers | keys | join(\", \")"))"
'

# ── Pre-approve the generated MCP servers for Claude ─────────────────────────
# Approval state lives in ~/.claude.json; since we generated .mcp.json from
# the manifest, its servers are approved by construction. Merge, don't clobber.
docker exec -u coder "dev-agent-$NAME" bash -c '
[ -f /workspace/main/.mcp.json ] || exit 0
SERVERS=$(jq -c "[.mcpServers | keys[]]" /workspace/main/.mcp.json)
[ -f /home/coder/.claude.json ] || echo "{}" > /home/coder/.claude.json
jq --argjson s "$SERVERS" ".projects[\"/workspace/main\"].enabledMcpjsonServers = \$s | .projects[\"/workspace/main\"].hasTrustDialogAccepted = true" \
    /home/coder/.claude.json > /tmp/cj.json && cat /tmp/cj.json > /home/coder/.claude.json && rm -f /tmp/cj.json
echo "  ✓ MCP servers pre-approved for claude ($(echo "$SERVERS" | jq -r "join(\", \")"))"
'

# ── Per-agent MCP configs beyond Claude ──────────────────────────────────────
# Cursor and Gemini cannot reliably expand env vars in headers for remote
# servers, so their configs carry the literal key: container-local home
# files, mode 600, never inside the repo, regenerated from secrets.env on
# every up (rotation flows). pi needs the pi-mcp-adapter extension for its
# file to take effect. codex is SKIPPED for now: ~/.codex is container-local
# (per-container volume), but its remote-MCP config.toml format is unverified.
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
[ -n "$SSH_PORT" ] && echo "  SSH:               ssh -p $SSH_PORT coder@$( [ "$SSH_BIND" = "127.0.0.1" ] && echo localhost || echo '<this-host>' )"
if [ "$REMOTE_TMUX" = "true" ] || [ "$REMOTE_MOSH" = "true" ]; then
    TUNNEL_IP="$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "dev-agent-$NAME" 2>/dev/null || true)"
    echo "  Remote (tunnel):   ${TUNNEL_IP:-<no ip>} — $( [ "$REMOTE_MOSH" = "true" ] && echo "mosh coder@ip (UDP $MOSH_PORTS_DASH)" || echo "ssh coder@ip" ) over your WireGuard/VPN"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
