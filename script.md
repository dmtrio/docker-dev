# Scripts

Every script in this repo, grouped by when you reach for it. All are run from
the repo root on the host (macOS or Linux) unless noted. Names in `<>` are
placeholders; `<name>` is a manifest/container short name (the container itself
is `dev-agent-<name>`).

The one non-script prerequisite: `secrets.env` holds every secret value (chmod
600, never mounted). By default it's the gitignored `./.dev-agent/secrets.env`;
copy `secrets.env.example` to fill it in. `up.sh` composes per-container
credentials from it according to each manifest.

All the scripts below source `common.sh` (not run directly), which resolves the
"dev-agent home" — where secrets/keys/artifacts live. It defaults to a
gitignored `./.dev-agent/`; override via `DEV_AGENT_HOME` / `RULES_PATH` in a
gitignored `./.env` at the repo root (keeps your own setup working).

---

## Before you create a container

Host-side capability services. Start the ones a container's manifest grants
(`capabilities.gateway/proxyman/browser`) **before** `./up.sh`, and keep them
running for as long as the container runs — the container reaches them over
`host.docker.internal`. Each binds localhost only and self-generates its token
into `secrets.env` on first run. Run them in tmux (or wrap in launchd) so they
survive.

| Script | Serves | Port | Token (auto-seeded) |
| --- | --- | --- | --- |
| `run-gateway-coding.sh` | The `coding` MCP profile (headless Playwright) | 8811 | `MCP_GATEWAY_TOKEN` |
| `run-proxyman-bridge.sh` | Proxyman's stdio MCP over HTTP (Proxyman.app must be open) | 8813 | `PROXYMAN_BRIDGE_KEY` |
| `run-research-browser.sh [brave\|chrome]` | A watchable, isolated-profile research browser | 8814 | `RESEARCH_BROWSER_KEY` |

```bash
./run-gateway-coding.sh          # then leave it running
./run-research-browser.sh brave  # optional arg picks the browser (default: Brave, else Chrome)
```

## Creating / updating a container

`up.sh` is the one entry point. It's declarative and idempotent: edit the
manifest, rerun, done.

- **`./up.sh <name>`** — create or update `dev-agent-<name>` from
  `containers/<name>.yml`. Composes `~/dev-agent/keys/<name>/` from `secrets.env`,
  builds the per-container image, waits for the firewall to come up, clones/inits
  the workspace, and generates each agent's MCP config. Re-run any time after
  editing the manifest or rotating a secret.

```bash
./up.sh coding-personal-site      # no args → lists available manifests
```

## While a container runs

Operate on a live container without a rebuild or restart.

- **`./allow-egress.sh <container> <domain> [<domain> ...] [--save yml|firewall|none]`**
  — add domains to the running container's egress allowlist immediately. Appends
  `ipset=/<domain>/allowed-domains` zones to its `/etc/dnsmasq.conf` and reloads
  only dnsmasq (the ipset and iptables rules stay up). The live change is
  ephemeral; at the end it asks where to persist:
  `yml` → this manifest's `capabilities.egress` (next `./up.sh`),
  `firewall` → `init-firewall.sh` base zones (all containers, next build),
  `none` → live only. Validates every domain first.

  ```bash
  ./allow-egress.sh coding-personal-site cdn.playwright.dev api.stripe.com
  ./allow-egress.sh coding-personal-site api.stripe.com --save yml   # skip the prompt
  ```

- **`./update-agent-keys.sh <container> <agent|common> <VAR> [value]`** — TEMPORARY
  override of one MCP credential for one agent, picked up the next time that agent
  starts (the shims read `~/.agent-keys` at launch). No arguments beyond the
  container name lists the current composed keys. Note: `~/dev-agent/keys/<name>/`
  is derived — the next `./up.sh <name>` wipes and recomposes it, so make durable
  changes in `secrets.env`/the manifest and use this only for quick experiments.

  ```bash
  ./update-agent-keys.sh coding-personal-site pi OBSIDIAN_ANNOTATED_KEY   # prompts for the value
  ./update-agent-keys.sh coding-personal-site                             # list keys
  ```

## Teardown & cleanup

- **`./down.sh <name> [--purge]`** — stop and remove the container. Default keeps
  the workspace volume (your code), so `./up.sh <name>` restores the container
  around it. `--purge` also deletes the volume, the per-container image, and the
  derived keys; the manifest, `secrets.env`, and `artifacts/<name>/` always
  survive.

  ```bash
  ./down.sh coding-personal-site            # stop, keep the code
  ./down.sh coding-personal-site --purge    # full teardown
  ```

---

## Inside the image (`src/` — automatic, you don't run these)

These live in `src/`, get baked into the image by the `Dockerfile`, and run
themselves inside the container; listed for completeness.

- **`src/entrypoint.sh`** — the container's PID 1. Persists `~/.claude.json`, runs
  the firewall (fail-loud), applies git config, guarantees `/workspace/main`
  exists, then either starts sshd (`SSH_ENABLED=true`) or idles for attach mode.
- **`src/init-firewall.sh`** — builds the default-deny egress allowlist at boot
  (GitHub IP ranges + dnsmasq-mirrored zones), verifies itself, and exits non-zero
  on failure so the container never runs with open egress. `allow-egress.sh` edits
  the same zone list live; the base `ALLOWED_ZONES` here is the durable default.
