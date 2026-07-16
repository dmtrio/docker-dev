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
CDD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ -f "$CDD_ROOT/.env" ]; then
    # Disable set -e around the source: a failing line INSIDE ./.env would
    # otherwise trip the caller's set -e and abort silently, before we could
    # report it. Capture the status, restore set -e, then fail loud with a
    # message (a broken ./.env is a real config error worth surfacing).
    set +e; . "$CDD_ROOT/.env"; _env_rc=$?; set -e
    [ "$_env_rc" -eq 0 ] || { echo "common.sh: ./.env exited non-zero ($_env_rc) — check $CDD_ROOT/.env" >&2; exit 1; }
fi
BASE_PATH="${DEV_AGENT_HOME:-$CDD_ROOT/.dev-agent}"
