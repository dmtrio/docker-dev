# proxyman

Bridges [Proxyman](https://proxyman.io)'s stdio MCP server over HTTP for
containers (traffic capture). **Remote** HTTP server on the Mac host, port
**8813**. Nothing is baked.

```yaml
plugins: [proxyman]
```

## Start the host service

```bash
./service.sh proxyman      # Proxyman.app must be running; leave it up (tmux/launchd)
```

First run self-generates `PROXYMAN_BRIDGE_KEY` into `secrets.env` (env-scoped —
shared by all agents). The bridge binds localhost only and requires the key on
inbound requests.
