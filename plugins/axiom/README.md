# axiom

[Axiom](https://axiom.co)'s **official remote MCP server** (`mcp.axiom.co`).
A **remote** HTTP server on a real internet host (reached via the egress
allowlist, so no `host_port` and no host service). It gives agents tools to
query your observability data with APL — run queries, list datasets, inspect
schemas, list saved queries, and read monitors.

## Secret model — env-scoped (shared token)

Unlike `obsidian-annotated` (agent-scoped, per-agent keys), Axiom uses **one
env-scoped token shared by all agents**, like `gateway`/`proxyman`. This is
deliberate: `src/manifest.py` currently only accepts `OBSIDIAN_KEY_*` /
`OBSIDIAN_WATCH_KEY_*` variables as `agent_secrets` sources, so an Axiom token
can't be bound per-agent today. Per the env-scoped wiring, the server is wired
into **Claude's `.mcp.json`** (with the `${AXIOM_TOKEN}` ref the shim expands);
cursor/gemini don't get remote-header plugins.

## Enable it

```yaml
plugins: [axiom]
common_secrets: [AXIOM_TOKEN]        # env-scoped: pass AXIOM_TOKEN through from secrets.env
                                     # or rename: {AXIOM_TOKEN: MY_AXIOM_VAR}
```

Then put the token in `secrets.env`:

```
AXIOM_TOKEN=xaat-xxxxxxxx…
```

Remote plugin ⇒ no image rebuild; just rerun `./up.sh <container>`.

## Token

Create one in the Axiom console under **Settings → API tokens**.

- A **scoped API token** (`xaat-…`) is org-bound and needs no org id — simplest
  for header auth, which is what this plugin uses
  (`Authorization: Bearer ${AXIOM_TOKEN}`).
- A **personal token** (`xapt-…`) also works but is tied to a user and may need
  an org id; prefer a scoped token for an agent.
- `mcp.axiom.co` also supports interactive **OAuth**, but that needs a browser
  callback — impractical for a headless container, which is why this plugin
  uses a static Bearer token (the same reason `obsidian-annotated`/`gateway`
  do).

## Tools

`queryApl`, `listDatasets`, `getDatasetSchema`, `getSavedQueries`,
`getMonitors`, `getMonitorsHistory`.

## Note

The older self-hosted Go server (`axiomhq/mcp-server-axiom`, local stdio,
`AXIOM_TOKEN` env) is **deprecated** in favor of this hosted server. If you ever
need the local stdio flavor instead, that'd be a `command:`-based plugin with an
`install:` block — not this one.
