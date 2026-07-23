## Axiom (observability data)

The `axiom` MCP server queries this org's Axiom data (logs, traces, events).
Reach for it when a question is about production telemetry: error rates, request
volumes, latency, log lookups, what a service was doing at a time.

- **Discover before querying.** Call `listDatasets`, then `getDatasetSchema` on
  the target dataset — field names and types vary per dataset; don't guess them.
- **Query with APL** via `queryApl`. APL is Axiom's pipe-based language, e.g.
  `['dataset'] | where status >= 500 | summarize count() by bin(_time, 5m)`.
  Dataset names are quoted in brackets; `_time` is the timestamp field.
- **Bound every query by time and rows** — add a `_time` filter and a `| limit`
  so an exploratory query can't scan or return the whole dataset.
- `getSavedQueries` surfaces queries the team already trusts — prefer adapting
  one over inventing a query from scratch. `getMonitors` / `getMonitorsHistory`
  cover alerting config and its firing history.
- It's **read-only** — it queries data, it can't ingest or change anything.
