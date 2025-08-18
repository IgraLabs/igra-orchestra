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

Update `NODE_ID` in `.env` with your node name.

2) Initialize repositories and images
```bash
chmod +x setup-repos.sh
./setup-repos.sh --dev
```

3) Start Kaspa and wait for full sync
```bash
docker compose --profile kaspad up -d
```

Usually it takes 4-6 hours to sync depending on the machine and network speed. You can check the sync progress with `docker compose logs -f kaspad` and wait until `IDB: 100%` is reached.

4) Make execution-layer script executable
```bash
chmod +x build/repos/execution-layer/run-igra-dev-el.sh
```

5) Generate JWT secret
```bash
openssl rand -hex 32 > keys/jwt.hex
```

6) Download the latest database backup from S3
```bash
chmod +x scripts/backup/download-from-s3.sh
./scripts/backup/download-from-s3.sh viaduct
```

7) Restore the database
```bash
chmod +x scripts/backup/restore.sh
./scripts/backup/restore.sh viaduct
# or you can pass the backup file path, for example:
./scripts/backup/restore.sh viaduct ~/.backups/viaduct-backups/igra-orchestra-testnet_viaduct_data_20250818_190105.tar.gz
```

8) Start backend services
```bash
docker compose --profile backend up -d --pull always
```

9)   Monitor initial sync and block building
```bash
# General logs
docker compose logs -f

# Track block-builder progress
docker logs -f block-builder
# Optional analyzer
docker logs -f block-builder | docker run -i --rm --entrypoint /app/reorg_analyzer igranetwork/block-builder:latest
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
