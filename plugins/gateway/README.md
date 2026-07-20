# gateway

A headless Playwright MCP gateway (Docker MCP gateway, `coding` profile).
**Remote** HTTP server on the Mac host, port **8811**. Nothing is baked.

```yaml
plugins: [gateway]
common_secrets: [MCP_GATEWAY_TOKEN]   # optional; the slot defaults to this same var
```

## Start the host service

```bash
./service.sh gateway        # leave it running (tmux or launchd)
```

First run self-generates `MCP_GATEWAY_TOKEN` into `secrets.env`. The token is
**env-scoped** — every agent presents the same value.

## Security posture

- Binds localhost only; containers reach it via `host.docker.internal`.
- Bearer token required (401 without it).
- Tool allowlist: Playwright `browser_*` only — no gateway-management tools, no
  `browser_run_code_unsafe`.
