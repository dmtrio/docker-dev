# serena

Semantic code retrieval + editing over LSP ([oraios/serena](https://github.com/oraios/serena)).
**Local** stdio server — baked into the image, runs inside the container, wired
into every installed MCP-capable agent. No secret, no host service.

```yaml
plugins: [serena]
```

## Notes

- **Rooted at `$PWD`**, not a hardcoded path — the server follows the session,
  so it reads/edits the checkout the agent was started in (main, or a worktree).
  Start agents inside a checkout; a non-Claude agent started elsewhere roots
  serena there.
- **Language servers download lazily** on first use per language. The base
  allowlist covers Python/TS/JS (github / npm / pythonhosted); this plugin adds
  `blob.core.windows.net` for the Azure-hosted ones (.NET, others). If another
  language's download is firewall-blocked, add the host from the error live:
  ```bash
  ./bin/allow-egress.sh dev-agent-<name> <host> --save yml
  ```
