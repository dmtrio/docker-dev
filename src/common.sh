#!/bin/bash
# common.sh — shared host-side config. NOT run directly; sourced by the repo's
# scripts (up.sh, down.sh, run-*.sh, update-agent-keys.sh). Resolves where
# secrets, keys, and artifacts live ("the dev-agent home") with two overrides,
# so a fresh clone is self-contained but your own setup keeps working:
#   1. ./.env at the repo root (gitignored) — set DEV_AGENT_HOME / RULES_PATH there
#   2. the DEV_AGENT_HOME environment variable
# Default: a gitignored ./.dev-agent inside this repo.

# Pure config resolution — no filesystem side effects, so sourcing this on a
# usage/error path (e.g. `./up.sh` with no args) creates nothing. Callers
# `mkdir -p "$BASE_PATH"` themselves once they've decided to proceed.
# This file lives in src/; the repo root (where ./.env and ./.dev-agent live)
# is its PARENT directory.
CDD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
if [ -f "$CDD_ROOT/.env" ]; then
    # Disable errexit around the source: a failing line INSIDE ./.env would
    # otherwise trip the caller's set -e and abort silently before we report
    # it. Save and RESTORE the caller's exact errexit state (don't force it
    # on), then fail loud on a broken ./.env — a real config error.
    case $- in *e*) _had_e=1;; *) _had_e=0;; esac
    set +e; . "$CDD_ROOT/.env"; _env_rc=$?
    [ "$_had_e" = 1 ] && set -e
    [ "$_env_rc" -eq 0 ] || { echo "common.sh: ./.env exited non-zero ($_env_rc) — check $CDD_ROOT/.env" >&2; exit 1; }
    unset _had_e _env_rc
fi
BASE_PATH="${DEV_AGENT_HOME:-$CDD_ROOT/.dev-agent}"

# Where container manifests are read from (up.sh, allow-egress.sh). Same
# override philosophy as RULES_PATH: an explicit CONTAINERS_PATH (env or ./.env)
# wins; otherwise prefer a per-setup $BASE_PATH/containers when it exists — so
# your real, semi-private manifests (private repo URLs, LAN subnets, identity
# naming) live OUTSIDE this repo, e.g. as their own private git repo at
# ~/dev-agent/containers — and fall back to the repo's containers/ (which ships
# only TEMPLATE.yml). A [ -d ] read only; still no filesystem side effects.
if [ -z "${CONTAINERS_PATH:-}" ]; then
    if [ -d "$BASE_PATH/containers" ]; then
        CONTAINERS_PATH="$BASE_PATH/containers"
    else
        CONTAINERS_PATH="$CDD_ROOT/containers"
    fi
fi
