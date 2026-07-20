# annotated-watch

An **env-only** plugin: one agent-scoped secret slot and **no MCP server**. It
exists solely to deliver a per-agent key into an agent's shim environment.

`ANNOTATED_WATCH_KEY` is the poll-scope key the `watch-vault` skill's background
monitor reads from the environment — there's nothing to wire.

```yaml
plugins: [annotated-watch]
agent_secrets:
  - {agent: claude, slot: ANNOTATED_WATCH_KEY, secret: OBSIDIAN_WATCH_KEY_me_claude}
```

This is proof that the general secret-slot mechanism is what "identities" always
were — a watch key is just an agent-scoped secret with no server.
