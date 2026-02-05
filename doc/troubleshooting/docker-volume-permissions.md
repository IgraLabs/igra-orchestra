# Fix: Docker Volume Permission Denied (Non-Root User)

Symptom:
- Container logs: `Permission denied` errors when writing to `/app/data/` or `/app/logs/`
- kaspad: `panicked at database/src/db/conn_builder.rs` with permission denied
- Other services failing to write to mounted volumes

Cause:
- Dockerfiles using non-root users (e.g., `kaspa` with UID 1000)
- Existing volume data owned by root from previous container runs
- Docker Compose prefixes volume names with project name (e.g., `igra-orchestra-testnet_kaspad_data`)

Diagnosis:
```bash
# Find the actual volume name used by docker compose
docker volume ls | grep -i kaspa

# Check permissions inside the volume
docker run --rm -v <actual_volume_name>:/data alpine ls -laR /data
```

Quick fix:
```bash
# 1. Stop the container
docker stop kaspad

# 2. Find the correct volume name (docker compose adds project prefix)
docker volume ls | grep kaspad
# Example output:
# local     igra-orchestra-testnet_kaspad_data  <-- use this one
# local     kaspad_data                          <-- NOT this one

# 3. Fix permissions on the CORRECT volume
docker run --rm -v igra-orchestra-testnet_kaspad_data:/data alpine chown -R 1000:1000 /data

# 4. Also fix logs directory if bind-mounted
sudo chown -R 1000:1000 ./logs/

# 5. Restart
docker compose up -d kaspad
```

Notes:
- UID 1000 matches the `kaspa` user in the Dockerfile
- Volume names follow pattern: `<project-name>_<volume-name>`
- Project name comes from directory name or `COMPOSE_PROJECT_NAME` env var
- Bind mounts (like `./logs/`) need host permissions fixed directly
