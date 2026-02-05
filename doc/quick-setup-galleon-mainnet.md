# IGRA Galleon Public Mainnet Deployment Guide

This guide covers deploying IGRA Orchestra on the Galleon public mainnet with pre-built Docker images.

## Quick Start (Automated)

For a guided interactive setup, run:
```bash
./scripts/setup-galleon-mainnet.sh
```
This script handles all configuration, key generation, and service startup automatically.

## Manual Setup

If the automated script above doesn't work for your environment, follow these manual steps.

## Prerequisites

- Docker and Docker Compose installed
- AMD64 or ARM64 machine
- 32GB+ RAM recommended
- Git and SSH access to github.com

## Galleon Mainnet Chain Parameters

| Parameter | Value |
|-----------|-------|
| `NETWORK` | mainnet |
| `IGRA_CHAIN_ID` | 38837 |
| `TX_ID_PREFIX` | 97b5 |
| `IGRA_LAUNCH_DAA_SCORE` | 348074960 |
| `GENESIS_BLOCK_HASH` | 0xc74895b494a1b1689871c8bfd30793749ab89c0dc1ac5c612cf31995290eef0f |
| `L1_REFERENCE_DAA_SCORE` | 337567432 |
| `L1_REFERENCE_TIMESTAMP` | 1769176427 |
| Address prefix | kaspa: |
| P2P Port | 16111 |
| gRPC Port | 16110 |
| Bootstrap Peer | 91.98.179.75 |

## Steps

1) Clone the repository

```bash
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
```

2) Configure environment

```bash
cp .env.galleon-mainnet.example .env
cat versions.env >> .env
```
Edit `.env` and fill in your node-specific values:
- `NODE_ID` - Your node identifier (will be prefixed with GMN-)
- `KASPAD_ADD_PEER` - Bootstrap peer address (default: 91.98.179.75, contact IGRA Labs if needed)
- `IGRA_ORCHESTRA_DOMAIN` - Your domain for HTTPS
- `IGRA_ORCHESTRA_DOMAIN_EMAIL` - Email for Let's Encrypt
- Worker wallet addresses and passwords (after generating keys in step 6)

3) Generate JWT secret

**Note:** This must be done before starting backend services in step 4.

```bash
mkdir -p keys
openssl rand -hex 32 > keys/jwt.hex
chmod 600 keys/jwt.hex
```

4) Start backend services

Start execution layer, kaspad, and node health check together:
```bash
docker compose --profile backend up -d --no-build
```

Monitor sync progress:
```bash
docker compose logs -f kaspad
```

Wait until `IBD: 100%` is reached (typically 4-6 hours depending on machine/network).

You can verify the genesis hash:
```bash
curl http://localhost:9545/ -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","id":"3","method":"eth_getBlockByNumber","params":["0x0", true]}'
```

Check hash field: it should match specified in the .env file.

5) Monitor IGRA adapter activity

Once kaspad is synced, you can monitor IGRA adapter activity:
```bash
docker logs -f -n 10 kaspad | docker run --rm -i --entrypoint /app/adapter-stats igranetwork/kaspad:$(grep KASPAD_VERSION versions.env | cut -d= -f2)
```

After kaspad sync, you should be able to see the progress of the building blocks:

```
Block #101,992    │ Hash: 0x0e41b08e1042d8f731816cac63940e94b0d7043bf5322fe66da371807cd1e441 │ ISC: 0x2278885c5e73a9efab568cb025feaa27732e4eff3c1e0eba7151f05da355f71d │ Prev: 0x85ac62cd59ced93a07316319364a4695efc12df6192be05efb0ea57888906238 │
Block #101,993    │ Hash: 0x321d540e55f6a6495030a51290286856269f50987f0a95770031f58ec980e914 │ ISC: 0x5f6a7dadae3ada7335c4807ee116a270c7e0ad282ba4bc9d673cabf4a1d606d3 │ Prev: 0x2278885c5e73a9efab568cb025feaa27732e4eff3c1e0eba7151f05da355f71d │
Block #101,994    │ Hash: 0x884ec7671666b1285194ee3b31fd822b83caddc286ba3fe43f701a7378efc9ae │ ISC: 0x28a00eb3d0174f7c3b23fcab75cf127dee803be266cc148035aab6932f27de70 │ Prev: 0x5f6a7dadae3ada7335c4807ee116a270c7e0ad282ba4bc9d673cabf4a1d606d3 │
^C
=== FINAL SUMMARY ===
================================================================================
                         ADAPTER STATS - SUMMARY
================================================================================
Runtime:                 0h 0m 1s
Blocks processed:        385

PIPELINE TIMING:
  Stage                    Avg (us)     Med (us)     Max (us)    Calls
  -------------------- ------------ ------------ ------------ --------
  verifier                       58           42        4,290      386
  translator                      0            0           13      386
  assembler                   4,786        4,637       30,638      385
```

Now you can wait till IGRA network is synced and reaches consensus with other nodes. Check the Grafana dashboard with your NODE_ID to monitor progress.

6) Generate mainnet wallet keys

Generate keys for each worker (0-4):

```bash
source versions.env
for i in {0..4}; do
  docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
    igranetwork/kaswallet:${KASWALLET_VERSION} --enable-mainnet-pre-launch -k /keys/keys.kaswallet-$i.json
done
```

Update `.env` with the wallet password you used during key generation (W0_KASWALLET_PASSWORD through W4_KASWALLET_PASSWORD).

Note: Wallet addresses use placeholders by default. See "Optional: Enable RPC Transaction Submission" section below if you want to accept user transactions.

7) Pull latest images (optional)

```bash
docker compose --profile backend --profile frontend-w5 pull
```

8) Start worker services

For all 5 workers:
```bash
docker compose --profile frontend-w5 up -d --no-build
```

Or start with fewer workers:
- 1 worker: `--profile frontend-w1`
- 2 workers: `--profile frontend-w2`
- 3 workers: `--profile frontend-w3`
- 4 workers: `--profile frontend-w4`
- 5 workers: `--profile frontend-w5`

9) Verify deployment

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

**Node Health Check:**
The node-health-check-client reports sync status and consensus to the monitoring dashboard.
Check its logs:
```bash
docker compose logs -f node-health-check-client
```

## Troubleshooting

**Kaspad not syncing:**
- Check network connectivity
- Verify no firewall blocking P2P port (16111)
- Ensure `KASPAD_ADD_PEER` is set to a valid bootstrap peer
- Check logs: `docker compose logs kaspad`

**Workers not connecting:**
- Ensure kaspad is fully synced with IGRA enabled
- Verify wallet key files exist in `keys/` directory
- Check kaswallet logs: `docker compose logs kaswallet-0`

**IGRA adapter issues:**
- Verify all mainnet parameters are correctly set in `.env`
- Ensure `IGRA_ENABLE=true` is set

## Optional: Enable RPC Transaction Submission

By default, the RPC is configured as **read-only** (`RPC_READ_ONLY=true`). This means it can query blockchain state but cannot submit transactions.

If you want to use this node as an RPC endpoint that accepts transactions from users:

1. Set `RPC_READ_ONLY=false` in your `.env` file
2. Top up the 5 kaswallets with KAS (you will pay for L1 gas fees)

After IBD sync completes (IBD: 100%):

1. Get wallet addresses:
```bash
./scripts/debug/wallet-status.sh
```
Look for `default_address` field in the JSON output for each wallet.

2. Top up each wallet address with KAS from an exchange or another wallet

3. Update `.env` with the actual wallet addresses (W0_WALLET_TO_ADDRESS through W4_WALLET_TO_ADDRESS)

> **⚠️ CRITICAL WARNING**: `WALLET_TO_ADDRESS` is the change return address.
> After each transaction, remaining wallet funds (change) are sent to this address.
> If set to a placeholder or incorrect address, **you will lose all wallet funds**
> after the first transaction. Double-check each address matches your wallet!

4. Restart workers:
```bash
docker compose --profile frontend-w5 up -d --no-build
```

## Maintenance

Restart services:
```bash
docker compose --profile backend --profile frontend-w5 restart
```

Update to latest images:
```bash
docker compose --profile backend --profile frontend-w5 pull
docker compose --profile backend --profile frontend-w5 up -d
```

View resource usage:
```bash
docker stats
```
