### IGRA Mainnet Deployment Guide

This guide covers deploying IGRA Orchestra on Kaspa mainnet with pre-built Docker images.

#### Prerequisites

- Docker and Docker Compose installed
- AMD64 or ARM64 machine
- 32GB+ RAM recommended
- Git and SSH access to github.com
- Mainnet configuration parameters from IGRA team

#### Important: Mainnet vs Testnet Differences

| Setting | Testnet | Mainnet |
|---------|---------|---------|
| `NETWORK` | testnet | mainnet |
| `IGRA_CHAIN_ID` | 19416 | Different (obtain from team) |
| `TX_ID_PREFIX` | 97b1 | Different (obtain from team) |
| Address prefix | kaspatest: | kaspa: |
| Wallet flag | --testnet | --mainnet |
| Peer config | Specific peer | Auto-discovery |

#### Steps

1) Configure environment

```bash
cp .env.mainnet.example .env
```

Edit `.env` and fill in the mainnet-specific values:
- `IGRA_CHAIN_ID` - Mainnet chain ID
- `TX_ID_PREFIX` - Mainnet transaction prefix
- `GENESIS_BLOCK_HASH` - Mainnet genesis hash
- `L1_REFERENCE_TIMESTAMP` - Mainnet L1 reference timestamp
- `L1_REFERENCE_DAA_SCORE` - Mainnet L1 reference DAA score
- `IGRA_LAUNCH_DAA_SCORE` - Mainnet IGRA launch DAA score
- `IGRA_LOCK_SCRIPT_PUBKEY` - Mainnet lock script pubkey
- `EL_ONE_TIME_ADDRESS` - Mainnet execution layer one-time address
- `NODE_ID` - Your node identifier
- `IGRA_ORCHESTRA_DOMAIN` - Your domain for HTTPS
- `IGRA_ORCHESTRA_DOMAIN_EMAIL` - Email for Let's Encrypt

2) Initialize repositories and images

```bash
chmod +x setup-repos.sh
./setup-repos.sh
```

3) Initial kaspad sync without IGRA

For faster initial sync, start kaspad without IGRA adapter:

```bash
# Set IGRA_ENABLE=false in .env for initial sync
sed -i 's/IGRA_ENABLE=true/IGRA_ENABLE=false/' .env

# Start kaspad
docker compose --profile kaspad up -d
```

Monitor sync progress:
```bash
docker compose logs -f kaspad
```

Wait until `IDB: 100%` is reached (typically 4-6 hours depending on machine/network).

4) Enable IGRA and restart kaspad

Once kaspad is fully synced:

```bash
# Enable IGRA
sed -i 's/IGRA_ENABLE=false/IGRA_ENABLE=true/' .env

# Restart kaspad with IGRA enabled
docker compose --profile kaspad down
docker compose --profile kaspad up -d
```

5) Generate JWT secret

```bash
openssl rand -hex 32 > keys/jwt.hex
```

6) Generate mainnet wallet keys

Generate keys for each worker (0-4):

```bash
# Using kaswallet-create with --enable-mainnet-pre-launch flag
docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-0.json

docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-1.json

docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-2.json

docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-3.json

docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-4.json
```

Or use a loop:
```bash
for i in {0..4}; do
  docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
    igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-$i.json
done
```

Update `.env` with the generated wallet addresses (must have `kaspa:` prefix).

7) Make execution layer script executable

```bash
chmod +x build/repos/reth-private/igra/run-igra-el.sh
```

8) Start backend services

```bash
docker compose --profile execution-layer up -d --pull always
```

9) Start worker services

For all 5 workers:
```bash
docker compose --profile frontend-w5 up -d
```

Or start with fewer workers:
- 1 worker: `--profile frontend-w1`
- 2 workers: `--profile frontend-w2`
- 3 workers: `--profile frontend-w3`
- 4 workers: `--profile frontend-w4`
- 5 workers: `--profile frontend-w5`

10) Verify deployment

Monitor logs:
```bash
# General logs
docker compose logs -f

# Monitor kaspad IGRA adapter activity
docker logs -f kaspad | grep -E "kaspa_igra_adapter|kaspa_atan"

# Check specific service
docker compose logs -f execution-layer
docker compose logs -f rpc-provider-0
```

Verify services are healthy:
```bash
docker compose ps
```

#### Troubleshooting

**Permission error on execution-layer startup:**
```bash
chmod +x build/repos/reth-private/igra/run-igra-el.sh
```

**Kaspad not syncing:**
- Check network connectivity
- Verify no firewall blocking P2P port (16111 for mainnet, 16211 for testnet)
- Check logs: `docker compose logs kaspad`

**Workers not connecting:**
- Ensure kaspad is fully synced with IGRA enabled
- Verify wallet key files exist in `keys/` directory
- Check kaswallet logs: `docker compose logs kaswallet-0`

**IGRA adapter issues:**
- Verify all mainnet parameters are correctly set in `.env`
- Check `IGRA_LOCK_SCRIPT_PUBKEY` is the mainnet value
- Ensure `IGRA_ENABLE=true` is set

#### Maintenance

Restart services:
```bash
docker compose --profile kaspad --profile execution-layer --profile frontend-w5 restart
```

Update to latest images:
```bash
docker compose --profile execution-layer --profile frontend-w5 pull
docker compose --profile execution-layer --profile frontend-w5 up -d
```

View resource usage:
```bash
docker stats
```

