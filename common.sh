#!/bin/bash
# common.sh — shared host-side config. NOT run directly; sourced by the repo's
# scripts (up.sh, down.sh, run-*.sh, update-agent-keys.sh). Resolves where
# secrets, keys, and artifacts live ("the dev-agent home") with two overrides,
# so a fresh clone is self-contained but your own setup keeps working:
#   1. ./.env at the repo root (gitignored) — set DEV_AGENT_HOME / RULES_PATH there
#   2. the DEV_AGENT_HOME environment variable
# Default: a gitignored ./.dev-agent inside this repo.

CDD_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
[ -f "$CDD_ROOT/.env" ] && . "$CDD_ROOT/.env"
BASE_PATH="${DEV_AGENT_HOME:-$CDD_ROOT/.dev-agent}"
mkdir -p "$BASE_PATH"
