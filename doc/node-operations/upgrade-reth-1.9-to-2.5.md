# Reth Upgrade: 1.9.3 → 2.5.1 (execution-layer resync)

!!! danger "This deletes the execution-layer database"
    Moving `RETH_VERSION` to the `2.5.1-igra.1` line is **not** a drop-in image swap. The
    reth database format changed between 1.9.3 (shipped as `3.0`) and 2.5.1, so the
    execution layer must be wiped and resynced from scratch.

    Budget **12+ hours**, during which the **L2 RPC is offline**. Your kaspad (L1) data is
    preserved — only the reth volume is removed.

## TL;DR

```bash
cd /path/to/your/igra-orchestra

# 1. Stop the WHOLE node — every profile, not just the backend. Never add -v.
docker compose --profile '*' down --remove-orphans

# 2. Work out this node's volume name (it is network-specific — never hardcode it)
PROJECT="$(docker compose config --format json | jq -r '.name')"
echo "$PROJECT"                                   # igra-orchestra-mainnet | igra-orchestra-testnet-10

# 3. Confirm nothing still holds the volume, then remove ONLY the reth volume
docker ps -a --filter "volume=${PROJECT}_reth_data" --format '{{.Names}}'   # must print nothing
docker volume rm "${PROJECT}_reth_data"

# 4. Bring the backend up and let it resync (12+ hours)
docker compose --profile backend up -d

# 5. Only once the EL has caught up, bring the workers back (same N as before)
docker compose --profile frontend-w${NUM_WORKERS} up -d
```

## Symptom: what happens if you skip the wipe

If you apply the new pin and start the stack on the old database, the run aborts like this:

```
✘ Container execution-layer            Error dependency execution-layer failed to start   25.9s
✔ Container node-health-check-client   Started
✔ Container kaspad                     Created
dependency failed to start: container execution-layer is unhealthy
```

Note what this output does **not** say: nothing here mentions the database. `kaspad` is
stuck at `Created` only because it has a hard `service_healthy` dependency on the execution
layer, so the whole backend refuses to come up. The actual reason is in the EL's own log:

```bash
docker compose logs execution-layer
```

If you see a database-version or storage-format error there, you need this runbook. Do not
retry `up -d` — it will fail identically until the volume is removed.

## Before you start

The execution layer has **no genesis file and no chain spec on disk**. It derives genesis
*and* every consensus rule from `.env` at boot, then rebuilds the whole L2 from your local
L1. A wiped node therefore picks up whatever your `.env` says *today* — if any of these
drifted since the node first synced, you will silently resync onto a **different chain**:

```bash
grep -E '^(IGRA_CHAIN_ID|IGRA_LAUNCH_DAA_SCORE|L1_REFERENCE_TIMESTAMP|L1_REFERENCE_DAA_SCORE|EL_ONE_TIME_ADDRESS|BITCOIN_BLOCK_HASH|ETHEREUM_BLOCK_HASH|KASPA_BLOCK_HASH|GENESIS_BLOCK_HASH|TX_ID_PREFIX|IGRA_LANE_ID|MIN_PROTOCOL_FEE_PER_GAS_GWEI|IGRA_ENTRY_MIN_AMOUNT|IGRA_LOCK_SCRIPT_PUBKEY|POST_FORK_LOCK_SCRIPT_PUBKEY|LOCK_SCRIPT_FORK_DAA_SCORE)=' .env
```

That is the full set the `execution-layer` service consumes. Because the resync replays the
entire chain rather than resuming it, a value that was wrong-but-harmless on a synced node
will now be baked into every block it rebuilds.

Compare against the canonical template for your network (`.env.mainnet.example` or
`.env.galleon-testnet.example`) and resolve any difference **before** removing the volume.
Keep the output — you will check `GENESIS_BLOCK_HASH` against the running node afterwards.

Record the current size so you can sanity-check the resync later:

```bash
docker system df -v | grep reth_data
```

## Procedure

### 1. Stop the whole node

```bash
docker compose --profile '*' down --remove-orphans
```

Stop **everything**, not just `--profile backend`. If the frontend stays up while the
execution layer goes away, every `rpc-provider`, `kaswallet`, and `traefik` container
detects the missing dependency, kills its child process, and enters a restart loop — noise
that makes the resync much harder to follow. A full stop also guarantees no RocksDB lock is
still held when the volume is removed.

!!! warning "Never use `down -v` here"
    In this project `-v` removes **all** named volumes, including `kaspad_data` (your L1
    chain and ATAN state — tens of GB, and by far the most expensive to rebuild) and
    `traefik_certs` (the Let's Encrypt `acme.json`; losing it can hit rate limits). Use a
    plain `down`, then remove the single reth volume by name. Do not use
    `docker volume prune` either.

### 2. Identify the volume

The compose project name is network-derived — `docker-compose.yml` sets
`name: igra-orchestra-${NETWORK}` — so the volume differs per node:

| Network | `NETWORK` | reth volume |
|---|---|---|
| Mainnet | `mainnet` | `igra-orchestra-mainnet_reth_data` |
| Galleon testnet | `testnet-10` | `igra-orchestra-testnet-10_reth_data` |
| Galleon, pre-testnet-10 migration | `testnet` | `igra-orchestra-testnet_reth_data` |

Derive it rather than typing it, so you cannot target the wrong node:

```bash
PROJECT="$(docker compose config --format json | jq -r '.name')"
# no jq? PROJECT="igra-orchestra-$(grep -E '^NETWORK=' .env | cut -d= -f2)"
echo "$PROJECT"

docker volume ls --filter "name=${PROJECT}_"
```

### 3. Remove only the reth volume

Confirm nothing still mounts it — this must print nothing at all:

```bash
docker ps -a --filter "volume=${PROJECT}_reth_data" --format '{{.Names}}\t{{.State}}'
```

If it lists anything, stop those containers first; `docker volume rm` will refuse while the
volume is in use. Then:

```bash
docker volume rm "${PROJECT}_reth_data"
```

### 4. Start the backend and resync

```bash
docker compose --profile backend up -d
docker compose logs -f execution-layer
```

Leave the frontend down for the whole resync.

!!! note "\"healthy\" does not mean \"synced\""
    The execution-layer healthcheck only probes its IPC socket and TCP 8545 — it says
    nothing about sync progress. The EL therefore reports **healthy within about a minute**
    of a wipe, and kaspad starts feeding it, while the resync still has 12+ hours to run.
    Judge progress from the logs and block height, not from `docker compose ps`.

    A brief `unhealthy` flap in the first ~35 seconds after the wipe is expected and
    self-heals.

### 5. Bring the workers back

Only once the execution layer has caught up:

```bash
docker compose --profile frontend-w${NUM_WORKERS} up -d   # same N you were running before
```

## Verify

Confirm the node rebuilt the chain you expect, not a different one:

```bash
# Genesis hash the EL actually derived
curl -s -X POST -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' \
  http://127.0.0.1:9545 | jq -r '.result.hash'

# Must equal this
grep '^GENESIS_BLOCK_HASH=' .env
```

If those two differ, stop and investigate the `.env` values from the pre-flight step — the
node has synced onto the wrong chain and the data is not usable.

Then check the stack:

```bash
docker compose ps                              # kaspad + execution-layer running / healthy
docker compose images kaspad execution-layer   # tags match versions.<network>.env
docker system df -v | grep reth_data           # size growing toward the pre-upgrade figure
```

## What is not deleted

Only `reth_data` is removed. Everything else survives and must **not** be recreated:

| Artifact | Kind | Why it stays |
|---|---|---|
| `kaspad_data` | named volume | L1 chain and ATAN state. reth replays L2 from it — removing it turns a 12-hour job into a multi-day one |
| `keys/jwt.hex` | host bind mount | Shared engine-API secret. kaspad reads the same file; regenerating it desyncs the pair |
| `traefik_certs` | named volume | Let's Encrypt `acme.json`; re-issuing risks rate limits |
| `network-params/` | host bind mount | Rewritten by the EL at boot |
