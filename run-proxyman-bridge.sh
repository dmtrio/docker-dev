#!/bin/bash
# run-proxyman-bridge.sh — expose Proxyman's stdio MCP server over
# streamable HTTP for dev containers (RFC 03 tier 2: direct host MCP).
#
# Proxyman's MCP is a stdio binary inside the app bundle, so containers
# can't reach it without a Mac-side bridge. This uses the Node mcp-proxy,
# chosen over supergateway because it can bind localhost-only AND require
# an API key on inbound requests.
#
# Run in tmux or wrap in launchd. Proxyman.app must be running.
# Containers need HOST_MCP_PORTS to include 8813 and an .mcp.json entry:
#   "url": "http://host.docker.internal:8813/mcp",
#   "headers": { "X-API-Key": "<contents of proxyman-bridge.key>" }

set -e

PROXYMAN_MCP="/Applications/Setapp/Proxyman.app/Contents/MacOS/mcp-server"
[ -x "$PROXYMAN_MCP" ] || PROXYMAN_MCP="/Applications/Proxyman.app/Contents/MacOS/mcp-server"
[ -x "$PROXYMAN_MCP" ] || { echo "ERROR: Proxyman mcp-server binary not found"; exit 1; }

SECRETS_FILE="${DEV_AGENT_HOME:-$HOME/dev-agent}/secrets.env"
[ -f "$SECRETS_FILE" ] || { mkdir -p "$(dirname "$SECRETS_FILE")"; touch "$SECRETS_FILE"; chmod 600 "$SECRETS_FILE"; }
. "$SECRETS_FILE"
if [ -z "${PROXYMAN_BRIDGE_KEY:-}" ]; then
    PROXYMAN_BRIDGE_KEY=$(openssl rand -hex 24)
    echo "PROXYMAN_BRIDGE_KEY=$PROXYMAN_BRIDGE_KEY" >> "$SECRETS_FILE"
    echo "Generated PROXYMAN_BRIDGE_KEY in $SECRETS_FILE"
fi

exec npx -y mcp-proxy \
    --host 127.0.0.1 \
    --port 8813 \
    --server stream \
    --apiKey "$PROXYMAN_BRIDGE_KEY" \
    -- "$PROXYMAN_MCP"
