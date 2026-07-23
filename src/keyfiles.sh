#!/bin/bash
# src/keyfiles.sh — host-side key-file composition, sourced by up.sh and
# unit-tested by tests/bash.test.sh. NOT baked into the image (runs on the host,
# unlike wire_plugins.py). Extracted from up.sh so the real composition logic is
# executable in tests, not just mirrored.
#
# Writes ONE COMPLETE env file per shim agent (Plugins v2 Phase 3 — common.env
# retired): the env-scoped secrets shared by all agents, then each bound agent's
# own agent-scoped secrets appended last (so they override a shared value at
# compose time, not via shim source order). `cat <agent>.env` is then the full
# audit of exactly what that agent sees.
#
# The VALUES come from the current environment via indirect expansion
# (${!source}); the caller sources secrets.env. This file, like the Python
# modules, only ever handles NAMES in its arguments — never values.

warn_missing() { echo "  ⚠ $1 not in secrets.env — $2 will not authenticate until set"; }

# write_keyfiles <keys_dir> <shim_agents> <plugin_env_secrets> <agent_secrets> [<git_org_tokens>]
#   keys_dir            already exists, mode 700, wiped of *.env by the caller
#   shim_agents         space-separated agent names (match the Dockerfile shims)
#   plugin_env_secrets  SLOT<TAB>SOURCE<TAB>HINT per line (env-scoped, from manifest.py)
#   agent_secrets       AGENT<TAB>SLOT<TAB>SOURCE per line (agent-scoped, from manifest.py)
#   git_org_tokens      OWNER<TAB>CANONICAL<TAB>SOURCE per line (per-org, from manifest.py)
# Reads GH_TOKEN and every SOURCE var from the environment (indirect expansion).
write_keyfiles() {
    local keys_dir="$1" shim_agents="$2" plugin_env_secrets="$3" agent_secrets="$4" git_org_tokens="${5:-}"
    local shared="" slot src hint agent a f owner canonical

    # Shared block: env-scoped plugin secrets + GH_TOKEN, built once. The
    # heredoc keeps the loop in this shell so the warns aren't lost to a pipe
    # subshell.
    while IFS=$'\t' read -r slot src hint; do
        [ -n "$slot" ] || continue
        if [ -n "${!src:-}" ]; then
            shared="${shared}${slot}=${!src}"$'\n'
        else
            warn_missing "$src" "$hint"
        fi
    done <<EOF
$plugin_env_secrets
EOF
    [ -n "${GH_TOKEN:-}" ] && shared="${shared}GH_TOKEN=$GH_TOKEN"$'\n'

    # Per-org tokens sit in the shared block alongside GH_TOKEN, one canonical
    # GH_TOKEN_<owner>=<value> per line, so git-credential-org can route by
    # owner. No warn_missing: a per-org source var absent from secrets.env is a
    # hard error in manifest.py (like agent_secrets), so it can't reach here.
    while IFS=$'\t' read -r owner canonical src; do
        [ -n "$owner" ] || continue
        shared="${shared}${canonical}=${!src}"$'\n'
    done <<EOF
$git_org_tokens
EOF

    # Fan the shared block out to every shim agent. chmod 600 as each file is
    # created — it already holds secret values, so don't leave it at the umask
    # default even for the window until the trailing chmod.
    for a in $shim_agents; do
        printf '%s' "$shared" > "$keys_dir/$a.env"; chmod 600 "$keys_dir/$a.env"
    done

    # Append each bound agent's own agent-scoped secrets (after the shared
    # block, so they win on a name collision). No warn_missing here — unlike
    # the shared slots above, an agent_secrets source var that isn't in
    # secrets.env is a hard error in manifest.py, so it can't reach this loop.
    while IFS=$'\t' read -r agent slot src; do
        [ -n "$agent" ] || continue
        echo "$slot=${!src}" >> "$keys_dir/$agent.env"
    done <<EOF
$agent_secrets
EOF

    for f in "$keys_dir"/*.env; do [ -f "$f" ] && chmod 600 "$f"; done
}
