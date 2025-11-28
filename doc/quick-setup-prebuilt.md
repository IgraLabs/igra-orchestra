### Igra Public Testnet — Quick Start

#### Prerequisites
- Docker and Docker Compose installed
- AMD64 or ARM64 machine
- 32GB+ RAM
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
./setup-repos.sh
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

6) Start backend services
```bash
docker compose --profile backend up -d --pull always
```

7) Monitor initial sync and block building
```bash
# General logs
docker compose logs -f

# Monitor kaspad logs for Igra adapter activity
docker logs -f kaspad | grep -E "kaspa_igra_adapter|kaspa_atan"
```

#### Common Issues
- Permission error on execution-layer startup:
```bash
chmod +x build/repos/execution-layer/run-igra-dev-el.sh
```
