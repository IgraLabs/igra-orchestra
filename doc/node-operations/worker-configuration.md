# Worker Configuration

Each orchestra node runs paired RPC provider + KasWallet worker services. The number of worker pairs is controlled by the `NUM_WORKERS` environment variable and the Docker Compose profile.

| Variable | Default | Range | Description |
|----------|---------|-------|-------------|
| `NUM_WORKERS` | `5` | `1-20` | Number of RPC/KasWallet worker pairs for the setup script |

**Profiles:** `frontend-w1` through `frontend-w20` — each profile starts that many worker pairs. All profiles are available; use the one matching your desired worker count.

```bash
# Start with 20 workers
NUM_WORKERS=20 ./scripts/setup-mainnet.sh

# Or manually with docker compose
docker compose --profile backend --profile frontend-w20 up -d
```
