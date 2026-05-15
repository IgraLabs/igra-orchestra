# IGRA Frigate (Testnet-12) Public Testnet Deployment Guide

This guide covers deploying IGRA Orchestra on the Frigate public testnet
(`testnet-12`) with pre-built Docker images.

> **Heads-up:** The shipped `.env.frigate-testnet.example` contains
> `TODO_TN12_<NAME>_REPLACE_ME` placeholders for values that aren't yet public
> (image versions, chain params, ops endpoints). You must replace them with the
> Frigate-specific values before launching. Track the current list in
> [Frigate Testnet Pending Values](frigate-testnet-values.md).

## Why testnet-12 has its own project namespace

`NETWORK` is now a slug of the form `<family>[-<suffix>]` (`mainnet`,
`testnet-10`, `testnet-12`). Docker Compose interpolates `${NETWORK}` into the
project name (`igra-orchestra-${NETWORK}`), the logging tag, the ATAN CDN
path, and the kaspad CLI flags. That gives Galleon (`testnet-10`) and Frigate
(`testnet-12`) isolated project, volume, log, and ATAN namespaces. The compose
file still uses fixed `container_name` values and host ports, so running both
stacks side by side on one host requires compose overrides for those names and
ports.

## Quick Start (Automated)

For a guided interactive setup, run:
```bash
./scripts/setup-frigate-testnet.sh
```
On first run before launch values are published, this script creates `.env` and
stops with a placeholder list. After you fill the pending Frigate values in
`.env`, rerun it to finish configuration, key generation, and service startup.

## Manual Setup

If the automated script above doesn't work for your environment, follow these manual steps.

## Prerequisites

- Docker and Docker Compose installed
- AMD64 or ARM64 machine
- 32GB+ RAM recommended
- Git and SSH access to github.com

## Frigate Testnet Chain Parameters

The placeholder rows below are not values to copy. They mark slots that the
Frigate launch will fill in once the chain parameters are published — track
the required value list in [Frigate Testnet Pending Values](frigate-testnet-values.md)
and copy the published values into `.env` rather than this table.

| Parameter | Value |
|-----------|-------|
| `NETWORK` | testnet-12 |
| `IGRA_CHAIN_ID` | _(pending)_ |
| `TX_ID_PREFIX` | _(pending)_ |
| `IGRA_LANE_ID` | 97b1000000000000000000000000000000000000 (post-KIP21 from genesis) |
| `IGRA_LAUNCH_DAA_SCORE` | _(pending)_ |
| `GENESIS_BLOCK_HASH` | _(pending)_ |
| `L1_REFERENCE_DAA_SCORE` | _(pending)_ |
| `L1_REFERENCE_TIMESTAMP` | _(pending)_ |
| `IGRA_LOCK_SCRIPT_PUBKEY` | _(pending)_ |
| Address prefix | kaspatest: |
| P2P Port | 16211 |
| gRPC Port | 16210 (localhost bind by default) |
| Borsh Port | 17210 (localhost bind by default) |
| JSON Port | 18210 (localhost bind by default) |
| Bootstrap Peer | (DNS seed; set `KASPAD_ADD_PEER` for faster initial sync) |

## Steps

1) Clone the repository

```bash
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
```

2) Configure environment

```bash
cp .env.frigate-testnet.example .env
cat versions.frigate-testnet.env >> .env
```
Edit `.env` and:
- Replace every `TODO_TN12_*_REPLACE_ME` placeholder with the published Frigate value.
- The appended image version values in `.env` are the source of truth for the
  commands below; you do not need to edit `versions.frigate-testnet.env` separately
  when following this copy-and-append flow.
- `NODE_ID` - Your node identifier (defaults to the `FTN-` prefix).
- `IGRA_ORCHESTRA_DOMAIN` - Your domain for HTTPS.
- `IGRA_ORCHESTRA_DOMAIN_EMAIL` - Email for Let's Encrypt.
- Worker wallet passwords after generating keys in step 6. Wallet change
  addresses are only required if you enable RPC transaction submission.

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

Wait until `IBD: 100%` is reached. Frigate uses DNS seeds for peer discovery
(no `--nodnsseed`), so peers should appear automatically. Compose starts
kaspad with `--ua-rule=reject;ver:kaspad<1.1.1`, rejecting pre-1.1.1 peers.

You can verify the genesis hash:
```bash
curl http://localhost:9545/ -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","id":"3","method":"eth_getBlockByNumber","params":["0x0", true]}'
```

Check hash field: it should match `GENESIS_BLOCK_HASH` in your `.env`.

5) Monitor IGRA adapter activity

Once kaspad is synced, you can monitor IGRA adapter activity:
```bash
KASPAD_VERSION="$(awk -F= '$1 == "KASPAD_VERSION" { print $2; exit }' .env)"
docker logs -f -n 10 kaspad | docker run --rm -i --entrypoint /app/adapter-stats igranetwork/kaspad:${KASPAD_VERSION}
```

Now you can wait until the IGRA network is synced and reaches consensus with
other Frigate nodes. Check the Grafana dashboard with your `NODE_ID` to
monitor progress.

6) Generate testnet wallet keys

Generate keys for each worker (0-4):

```bash
KASWALLET_VERSION="$(awk -F= '$1 == "KASWALLET_VERSION" { print $2; exit }' .env)"
for i in {0..4}; do
  docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
    igranetwork/kaswallet:${KASWALLET_VERSION} --testnet --testnet-suffix=12 -k /keys/keys.kaswallet-$i.json
done
```

Update `.env` with the wallet password you used during key generation (W0_KASWALLET_PASSWORD through W4_KASWALLET_PASSWORD).

Note: RPC transaction submission is disabled by default. Wallet addresses use placeholders; replace them only if you follow the optional transaction submission steps below.

7) Pull latest images (optional)

```bash
docker compose --profile backend --profile frontend-w5 pull
```

8) Start worker services

For all 5 workers:
```bash
docker compose --profile frontend-w5 up -d --no-build
```

This assumes the backend profile is already running. To start backend and frontend together in one command:

```bash
docker compose --profile backend --profile frontend-w5 up -d --no-build
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
- Verify no firewall blocking P2P port (16211)
- DNS seeds should provide peers automatically; set `KASPAD_ADD_PEER` to a
  known Frigate peer if discovery is slow.
- Check logs: `docker compose logs kaspad`

**Peers immediately disconnecting:**
- Compose starts kaspad with `--ua-rule=reject;ver:kaspad<1.1.1`, which rejects
  pre-Toccata nodes. Testing against older peers requires changing the compose
  runtime configuration.

**Workers not connecting:**
- Ensure kaspad is fully synced with IGRA enabled
- Verify wallet key files exist in `keys/` directory
- Check kaswallet logs: `docker compose logs kaswallet-0`

**IGRA adapter issues:**
- Verify all testnet parameters are correctly set in `.env`
- Ensure no `TODO_TN12_*_REPLACE_ME` placeholders remain
- Ensure `IGRA_ENABLE=true` is set

## Optional: Enable RPC Transaction Submission

By default, the RPC is read-only (`RPC_READ_ONLY=true`) and does not submit transactions.

To enable transaction submission, you need to fund the wallets and explicitly opt in:

1. Top up the 5 kaswallets with KAS (you will pay for L1 gas fees)

After IBD sync completes (IBD: 100%):

1. Get wallet addresses:
```bash
./scripts/debug/wallet-status.sh
```
Look for `default_address` field in the JSON output for each wallet.

2. Top up each wallet address with KAS from a faucet or another wallet

3. Update `.env` with the actual wallet addresses (W0_WALLET_TO_ADDRESS through W4_WALLET_TO_ADDRESS) and set `RPC_READ_ONLY=false`

> **CRITICAL WARNING**: `WALLET_TO_ADDRESS` is the change return address.
> After each transaction, remaining wallet funds (change) are sent to this address.
> If set to a placeholder or incorrect address, **you will lose all wallet funds**
> after the first transaction. Double-check each address matches your wallet!

4. Restart workers:
```bash
docker compose --profile frontend-w5 up -d --no-build
```

## Maintenance

Restart frontend services without touching backend:
```bash
docker compose --profile frontend-w5 restart
```

Stop frontend only without touching backend:
```bash
docker compose --profile frontend-w5 down
docker compose --profile frontend-w5 up -d --no-build
```

For fewer workers, replace `frontend-w5` with `frontend-w1` through `frontend-w4`.

Update to latest images:
```bash
docker compose --profile backend --profile frontend-w5 pull
docker compose --profile backend --profile frontend-w5 up -d
```

View resource usage:
```bash
docker stats
```
