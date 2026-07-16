# Tips

## Update container memory

The durable way: set `memory:` in `containers/<name>.yml` and rerun
`./up.sh <name>` — the manifest is the source of truth, and anything set
another way is overwritten on the next up.

For a **temporary** bump on a running container without a restart
(reverts on the next `up.sh`):

```bash
# Set a specific limit (containers are named dev-agent-<name>)
docker update --memory 12g --memory-swap 12g dev-agent-<name>

# Check current limit (returns bytes, 0 = unlimited)
docker inspect dev-agent-<name> --format '{{.HostConfig.Memory}}'
```
