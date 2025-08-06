### Igra Public Testnet — Quick Start

#### Prerequisites
- Docker and Docker Compose installed
- AMD64 or ARM64 machine
- 16GB+ RAM
- Git and SSH access to github.com

#### Steps

1) Configure environment
```bash
cp .env.backend.example .env
```

Update `HEALTH_CHECK_API_KEY` and `NODE_ID` in `.env` with your API key and node id that was provided to you and your node name of your choice.

2) Initialize repositories and images
```bash
./setup-repos.sh
```

3) Start Kaspa and wait for full sync
```bash
docker compose --profile kaspad up -d
docker compose logs -f kaspad  # wait until IDB progress reaches 100%
```

4) Provide execution-layer artifacts
- Place downloaded `genesis.template.json` and `run-igra-dev-el.sh` into `build/repos/execution-layer/`

5) Make execution-layer script executable
```bash
chmod +x build/repos/execution-layer/run-igra-dev-el.sh
```

6) Generate JWT secret
```bash
openssl rand -hex 32 > keys/jwt.hex
```

7) Place the database backup
```bash
mkdir -p ~/.backups/viaduct-backups/
# Place your downloaded backup archive *.gz into ~/.backups/viaduct-backups/
```

8) Restore the database
```bash
./scripts/backup/restore.sh viaduct
```

9) Start backend services
```bash
docker compose --profile backend up -d
```

10)  Monitor initial sync and block building
```bash
# General logs
docker compose logs -f

# Track block-builder progress
docker logs -f block-builder
# Optional analyzer
docker run -i --rm --entrypoint /app/reorg_analyzer igranetwork/block-builder:latest
```

#### Common issues
- Viaduct exits immediately:
  ```
  viaduct  | [.... INFO  viaduct::uni_storage] Starting to handle notifications
  viaduct exited with code 0
  ```
  - Kaspa is not fully synced yet. Wait for `IDB: 100%` in Kaspad logs, then start backend again.
- Permission error on execution-layer startup:
```bash
chmod +x build/repos/execution-layer/run-igra-dev-el.sh
```
