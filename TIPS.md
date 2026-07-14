# Tips

## Update container memory without restarting

`docker update` works on running containers — no downtime required.

```bash
# Set a specific limit
docker update --memory 4g --memory-swap 4g <container_name>

# Remove the limit (unlimited)
docker update --memory 0 --memory-swap 0 <container_name>

# Check current limit (returns bytes, 0 = unlimited)
docker inspect <container_name> --format '{{.HostConfig.Memory}}'
```
