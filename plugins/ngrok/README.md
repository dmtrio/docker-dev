# ngrok

A **CLI plugin, not an MCP server.** ngrok is just a command-line app plus a
secret, so this plugin uses the server-less shape (like
[`annotated-watch`](../annotated-watch/README.md)) with an install block added:

- **`install:`** bakes the ngrok v3 static binary into the image at build time.
- **`secrets:`** delivers `NGROK_AUTHTOKEN` into each agent's shim environment.
  ngrok reads that variable natively — no `ngrok config add-authtoken` step.
- **`egress:`** allowlists `connect.ngrok-agent.com`, the agent's outbound
  tunnel connection at runtime.

Because it carries an `install:` block, ngrok is **baked into the shared image**:
enabling it in a new manifest needs an **image rebuild**, not just `./up.sh`.

## Enable it

```yaml
plugins: [ngrok]
common_secrets: [NGROK_AUTHTOKEN]   # binds the env-scoped slot to a secrets.env var
```

Add the token to `secrets.env`:

```
NGROK_AUTHTOKEN=2abc...your_token
```

Then rebuild the image and `./up.sh <container>`. Verify inside the container:

```bash
ngrok version          # binary is on PATH
ngrok http 3000        # authenticates from NGROK_AUTHTOKEN, tunnels a local port
```

## ⚠ Security posture — read before enabling

ngrok deliberately punches an **inbound** path from the public internet to a
local port. That is the opposite of this container's default design (an
egress-firewalled isolation box). The egress allowlist still governs the
outbound leg — the agent connects *out* to ngrok's edge, which proxies inbound
traffic back down the tunnel — but the net effect is that a local service
becomes publicly reachable for the tunnel's lifetime.

Enable ngrok only in containers where exposing a local port is an intentional
goal (e.g. sharing a dev server, receiving a webhook). It is not a general-use
plugin. The token in `secrets.env` is account-scoped; treat it like any other
credential.

## Per-agent tokens (optional)

The default (`scope: env`) shares one account token across all agents, which
matches ngrok's one-token-per-account free tier. For attribution with a paid
plan that issues multiple tokens, switch the slot to `scope: agent` and bind
per agent:

```yaml
plugins: [ngrok]
agent_secrets:
  - {agent: claude, slot: NGROK_AUTHTOKEN, secret: NGROK_AUTHTOKEN_claude}
```
