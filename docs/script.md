# Scripts

Every script in this repo, grouped by when you reach for it. All are run from
the repo root on the host (macOS or Linux) unless noted — `up.sh` / `down.sh`
live at the root; the other host commands live in `bin/` (so you invoke them as
`bin/<name>.sh`). Names in `<>` are placeholders; `<name>` is a
manifest/container short name (the container itself is `dev-agent-<name>`).

The one non-script prerequisite: `secrets.env` holds every secret value (chmod
600, never mounted). By default it's the gitignored `./.dev-agent/secrets.env`;
copy `secrets.env.example` to fill it in. `up.sh` composes per-container
credentials from it according to each manifest.

All the scripts below source `src/common.sh` (not run directly), which resolves the
"dev-agent home" — where secrets/keys/artifacts live. It defaults to a
gitignored `./.dev-agent/`; override via `DEV_AGENT_HOME` / `RULES_PATH` /
`CONTAINERS_PATH` in a gitignored `./.env` at the repo root (keeps your own
setup working). `CONTAINERS_PATH` is where `containers/<name>.yml` manifests
are read from — it defaults to `$DEV_AGENT_HOME/containers` when that exists,
so your real manifests can live outside this repo.

---

## Before you create a container

Some plugins are backed by a service that runs on your Mac (the container
reaches it over `host.docker.internal`). Start the ones a container's manifest
lists **before** `./up.sh`, and leave them running (tmux or launchd):

```bash
./service.sh <name>   # execs plugins/<name>/run.sh; self-generates its token on first run
./service.sh          # lists the plugins that ship a host service
```

`service.sh` is deliberately separate from `up.sh` — `up.sh` recreates the
container (killing a running agent), so starting a host service is its own
root-level command that never touches docker. Which plugins need a service, and
the token each uses, are documented in `plugins/<name>/README.md`.

## Creating / updating a container

`up.sh` is the one entry point. It's declarative and idempotent: edit the
manifest, rerun, done.

- **`./up.sh <name>`** — create or update `dev-agent-<name>` from
  `containers/<name>.yml`. Composes `$DEV_AGENT_HOME/keys/<name>/` from `secrets.env`,
  builds the per-container image, waits for the firewall to come up, clones/inits
  the workspace, and generates each agent's MCP config. Re-run any time after
  editing the manifest or rotating a secret.

```bash
./up.sh my-app      # no args → lists available manifests
```

## While a container runs

Operate on a live container without a rebuild or restart.

- **`./bin/allow-egress.sh <container> <domain> [<domain> ...] [--save yml|firewall|none]`**
  — add domains to the running container's egress allowlist immediately. Appends
  `ipset=/<domain>/allowed-domains` zones to its `/etc/dnsmasq.conf` and reloads
  only dnsmasq (the ipset and iptables rules stay up). The live change is
  ephemeral; at the end it asks where to persist:
  `yml` → this manifest's `capabilities.egress` (next `./up.sh`),
  `firewall` → `src/init-firewall.sh` base zones (all containers, next build),
  `none` → live only. Validates every domain first.

  ```bash
  ./bin/allow-egress.sh my-app cdn.playwright.dev api.stripe.com
  ./bin/allow-egress.sh my-app api.stripe.com --save yml   # skip the prompt
  ```

- **`./bin/update-agent-keys.sh <container> <agent|common> <VAR> [value]`** — TEMPORARY
  override of one MCP credential for one agent, picked up the next time that agent
  starts (the shims read `~/.agent-keys` at launch). No arguments beyond the
  container name lists the current composed keys. Note: `$DEV_AGENT_HOME/keys/<name>/`
  is derived — the next `./up.sh <name>` wipes and recomposes it, so make durable
  changes in `secrets.env`/the manifest and use this only for quick experiments.

  ```bash
  ./bin/update-agent-keys.sh my-app pi OBSIDIAN_ANNOTATED_KEY   # prompts for the value
  ./bin/update-agent-keys.sh my-app                             # list keys
  ```

## Teardown & cleanup

- **`./down.sh <name> [--purge]`** — stop and remove the container. Default keeps
  the workspace volume (your code), so `./up.sh <name>` restores the container
  around it. `--purge` also deletes the volume, the per-container image, and the
  derived keys; the manifest, `secrets.env`, and `artifacts/<name>/` always
  survive.

  ```bash
  ./down.sh my-app            # stop, keep the code
  ./down.sh my-app --purge    # full teardown
  ```

---

## Inside the image (baked from `src/` — automatic, you don't run these)

The host commands above live in `bin/`; `src/` is internal source — the
`common.sh` those commands source, the host-side `manifest.py` / `wire_plugins.py`
`up.sh` calls, and the files below, which get baked into the image by the
`Dockerfile` and run themselves inside the container (listed for completeness).

- **`src/entrypoint.sh`** — the container's PID 1. Persists `~/.claude.json`, runs
  the firewall (fail-loud), applies git config, guarantees `/workspace/repos` and
  `/workspace/worktrees` exist, then either starts sshd (`SSH_ENABLED=true`) or
  idles for attach mode.
- **`src/init-firewall.sh`** — builds the default-deny egress allowlist at boot
  (GitHub IP ranges + dnsmasq-mirrored zones), verifies itself, and exits non-zero
  on failure so the container never runs with open egress. `bin/allow-egress.sh` edits
  the same zone list live; the base `ALLOWED_ZONES` here is the durable default.
- **`src/tmux.conf` / `src/tmux-landing.bashrc`** — remote access (RFC 04):
  mobile-friendly tmux defaults, and the guarded snippet that lands interactive
  SSH/mosh logins in the shared durable `agent` session.
- **`src/mosh-server-wrapper.sh`** — pins client-launched mosh servers to the
  firewalled/published UDP range.
- **`src/tmux-notify.sh`** — agent-blind idle notifier; fired by the tmux
  silence hook when `remote.notify: ntfy` is on, pushes to your ntfy topic
  unless a client is attached.
