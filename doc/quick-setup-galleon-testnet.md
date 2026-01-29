# IGRA Galleon Public Testnet Deployment Guide

This guide covers deploying IGRA Orchestra on the Galleon public testnet with pre-built Docker images.

#### Quick Start (Automated)

For a guided interactive setup, run:
```bash
./scripts/setup-galleon-testnet.sh
```
This script handles all configuration, key generation, and service startup automatically.

#### Manual Setup

If the automated script above doesn't work for your environment, follow these manual steps.

#### Prerequisites

- Docker and Docker Compose installed
- AMD64 or ARM64 machine
- 32GB+ RAM recommended
- Git and SSH access to github.com

#### Galleon Testnet Chain Parameters

| Parameter | Value |
|-----------|-------|
| `NETWORK` | testnet |
| `IGRA_CHAIN_ID` | 38836 |
| `TX_ID_PREFIX` | 97b4 |
| `IGRA_LAUNCH_DAA_SCORE` | 368045400 |
| `GENESIS_BLOCK_HASH` | 0xcde7665949ac157e4d4ee866141ef20d991e5ce1fe6ffc20b874198f9dd2e9d8 |
| `L1_REFERENCE_DAA_SCORE` | 361004030 |
| `L1_REFERENCE_TIMESTAMP` | 1768475045 |
| Address prefix | kaspatest: |
| P2P Port | 16211 |
| gRPC Port | 16210 |
| Bootstrap Peer | 65.109.78.124 |

#### Steps

1) Clone the repository

```bash
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
```

2) Configure environment

```bash
cp .env.galleon-testnet.example .env
```
Edit `.env` and fill in your node-specific values:
- `NODE_ID` - Your node identifier
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

Wait until `IDB: 100%` is reached (typically 4-6 hours depending on machine/network).

You can verify the genesis hash:
```bash
curl http://localhost:9545/ -X POST -H "Content-Type: application/json" --data '{"jsonrpc":"2.0","id":"3","method":"eth_getBlockByNumber","params":["0x0", true]}'
```

Check hash field: it should match specified in the .env file.

5) Monitor IGRA adapter activity

Once kaspad is synced, you can monitor IGRA adapter activity:
```bash
docker logs -f -n 10 kaspad | docker run --rm -i --entrypoint /app/adapter-stats igranetwork/kaspad:2.0.1
```

After kaspad sync, you should be able to see the progress of the building blocks:

```
Block #101,992    │ Hash: 0x0e41b08e1042d8f731816cac63940e94b0d7043bf5322fe66da371807cd1e441 │ ISC: 0x2278885c5e73a9efab568cb025feaa27732e4eff3c1e0eba7151f05da355f71d │ Prev: 0x85ac62cd59ced93a07316319364a4695efc12df6192be05efb0ea57888906238 │
Block #101,993    │ Hash: 0x321d540e55f6a6495030a51290286856269f50987f0a95770031f58ec980e914 │ ISC: 0x5f6a7dadae3ada7335c4807ee116a270c7e0ad282ba4bc9d673cabf4a1d606d3 │ Prev: 0x2278885c5e73a9efab568cb025feaa27732e4eff3c1e0eba7151f05da355f71d │
Block #101,994    │ Hash: 0x884ec7671666b1285194ee3b31fd822b83caddc286ba3fe43f701a7378efc9ae │ ISC: 0x28a00eb3d0174f7c3b23fcab75cf127dee803be266cc148035aab6932f27de70 │ Prev: 0x5f6a7dadae3ada7335c4807ee116a270c7e0ad282ba4bc9d673cabf4a1d606d3 │
Block #101,995    │ Hash: 0x89b244f95085c9970f4038daed48f886d32e83b5dd13f3314fc738fbea26f933 │ ISC: 0xf288ce24d30df53d6770f13ecdfae39e150eea76a840a740e693ca0edaff0e39 │ Prev: 0x28a00eb3d0174f7c3b23fcab75cf127dee803be266cc148035aab6932f27de70 │
Block #101,996    │ Hash: 0x259be8f5188c2f11023952df3a97106a5fe565c916a69bbac02e4d6e7ddc46f9 │ ISC: 0xc6e8075a18543d200d8683f8508c3c4b7f54e975f25cd6914c46ed7d61c2de65 │ Prev: 0xf288ce24d30df53d6770f13ecdfae39e150eea76a840a740e693ca0edaff0e39 │
Block #101,997    │ Hash: 0x5e566979f8c42eafcf5be66841b3d6d5b2cb15c99879e4355cb3af2d3e57136e │ ISC: 0x69c7e13dd8f7bab51e450b01b4f58ab9a1ee3dccec57f4f93fe4f7af04c31549 │ Prev: 0xc6e8075a18543d200d8683f8508c3c4b7f54e975f25cd6914c46ed7d61c2de65 │
Block #101,998    │ Hash: 0x927b0baecdebfa0d8b4237827cbaf2d55a0f2bbf2942a41c3720a3cd3a2fa801 │ ISC: 0xec59b2dd7d6bef0576dc426b822da376a53fc220c15c09b992b3a950e016e2b4 │ Prev: 0x69c7e13dd8f7bab51e450b01b4f58ab9a1ee3dccec57f4f93fe4f7af04c31549 │
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

ASSEMBLER STAGES:
  Stage                    Avg (us)     Med (us)     Max (us)    Calls
  -------------------- ------------ ------------ ------------ --------
  canonical_update              469          461          737      385
  entry                           6            6           25      385
  payload_build               1,661        1,531       27,207      385
  regular                         6            6           44      385
  state_validation                8            8           30      385
  total                         267          237        7,433      385
  tx_processing                 274          244        7,443      385

RPC TIMING:
  Method                             Avg (us)     Med (us)     Max (us)    Calls  Success %
  ------------------------------ ------------ ------------ ------------ -------- ----------
  admin_clearTxpool                       104          100          177      386      100.0
  engine_forkchoiceUpdatedV3              175          168          522      770      100.0
  engine_getPayloadV4                     438          437        1,643      385      100.0
  engine_newPayloadV4                     668          652        1,452      385      100.0
  eth_getBlockByHash                      107          105          224      385      100.0
  eth_getBlockByNumber                    183          175          323      385      100.0
  eth_sendRawTransaction                  151          148          243      381        0.0
  txpool_content                           90           88          181      385      100.0

PERFORMANCE:
  Avg blocks/second:     385.0
================================================================================
```

Now you can wait till IGRA network is synced and reaches consensus with other nodes. Check the Grafana dashboard with your NODE_ID to monitor progress.

6) Generate testnet wallet keys

Generate keys for each worker (0-4):

```bash
for i in {0..4}; do
  docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
    igranetwork/kaswallet:2.0.0 --testnet -k /keys/keys.kaswallet-$i.json
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

#### Troubleshooting

**Kaspad not syncing:**
- Check network connectivity
- Verify no firewall blocking P2P port (16211)
- Ensure `KASPAD_ADD_PEER=65.109.78.124` is set
- Check logs: `docker compose logs kaspad`

**Workers not connecting:**
- Ensure kaspad is fully synced with IGRA enabled
- Verify wallet key files exist in `keys/` directory
- Check kaswallet logs: `docker compose logs kaswallet-0`

**IGRA adapter issues:**
- Verify all testnet parameters are correctly set in `.env`
- Ensure `IGRA_ENABLE=true` is set

#### Optional: Enable RPC Transaction Submission

By default, the RPC is configured as **read-only** (`RPC_READ_ONLY=true`). This means it can query blockchain state but cannot submit transactions.

If you want to use this node as an RPC endpoint that accepts transactions from users:

1. Set `RPC_READ_ONLY=false` in your `.env` file
2. Top up the 5 kaswallets with KAS (you will pay for L1 gas fees)

After IBD sync completes (IDB: 100%):

1. Get wallet addresses:
```bash
./scripts/debug/wallet-status.sh
```
Look for `default_address` field in the JSON output for each wallet.

2. Top up each wallet address with KAS from a faucet or another wallet

3. Update `.env` with the actual wallet addresses (W0_WALLET_TO_ADDRESS through W4_WALLET_TO_ADDRESS)

4. Restart workers:
```bash
docker compose --profile frontend-w5 up -d --no-build
```

#### Maintenance

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
