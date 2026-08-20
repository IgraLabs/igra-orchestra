# Read-Only RPC Node

A minimal Igra node for co-location on a hardened host. Serves `eth_*` **reads only** to a local consumer at
`http://igra-local-rpc:8545`. It cannot broadcast transactions — no `kaswallet`, and the proxy runs read-only.

Entry point: `docker-compose.readonly-rpc.yml` · Environment: `.env.readonly-rpc.example`

## Services

| Service | Profile | Does |
|---|---|---|
| `kaspad` | `kaspad`, `backend` | L1 node and the Igra sequencer |
| `execution-layer` | `execution-layer`, `kaspad`, `backend` | reth, pruned to ~1 week of history |
| `rpc-proxy` | `rpc-proxy`, `backend` | fail-closed read-only allowlist; the only thing the consumer reaches |
| `node-health-check-client` | `node-health-check-client`, `backend` | pushes sync status to the monitor |

Profile and container names match `docker-compose.yml`. **A profile is required** — with none set, nothing starts.

Because the container names match, this stack and the full orchestra stack **cannot run on the same Docker
daemon** — `container_name` is global, so the second one to start fails with a name conflict. That is fine for the
intended deployment, where this is the only Igra stack on the host, but it does mean you cannot bring both up on
one development machine.

## Start

```bash
cp .env.readonly-rpc.example .env      # then edit it

# everything
docker compose -f docker-compose.readonly-rpc.yml --profile backend up -d

# kaspad + execution-layer only
docker compose -f docker-compose.readonly-rpc.yml --profile kaspad up -d

# one service at a time
docker compose -f docker-compose.readonly-rpc.yml --profile execution-layer up -d
docker compose -f docker-compose.readonly-rpc.yml --profile rpc-proxy up -d
docker compose -f docker-compose.readonly-rpc.yml --profile node-health-check-client up -d
```

Stop with `stop`, not `down` — the consumer attaches to `igra-readonly-rpc` as an external network and `down`
removes it:

```bash
docker compose -f docker-compose.readonly-rpc.yml --profile backend stop
docker compose -f docker-compose.readonly-rpc.yml --profile backend ps
```

Config changes need `up -d`, never `restart` — `restart` reuses the environment the container was created with.

## Initial sync — two stages

```bash
# Stage 1: IGRA_ENABLE=false in .env (the shipped default), sync L1 first
docker compose -f docker-compose.readonly-rpc.yml --profile kaspad up -d
journalctl --no-pager -u docker CONTAINER_NAME=kaspad -n 50

# Stage 2: set IGRA_ENABLE=true, then
docker compose -f docker-compose.readonly-rpc.yml --profile backend up -d
```

Container health is not the sync gate — kaspad reports healthy as soon as gRPC listens, long before chain parity.

## Verify

```bash
# from the consumer's vantage point
docker run --rm --network igra-readonly-rpc curlimages/curl -sS \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  http://igra-local-rpc:8545                                  # expect 0x97b1

# writes must be refused with -32000 "Read-only mode is enabled"
docker run --rm --network igra-readonly-rpc curlimages/curl -sS \
  -H 'content-type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x02"]}' \
  http://igra-local-rpc:8545

# kaspad and reth must NOT resolve from the consumer network
docker run --rm --network igra-readonly-rpc busybox nslookup kaspad     # must fail

# pruning actually active
journalctl --no-pager -u docker CONTAINER_NAME=execution-layer \
  | grep 'Pruning: enabled; distance=600000'

# logs
journalctl --no-pager -u docker CONTAINER_NAME=kaspad -n 50
```

An error alone does not prove the write guard works — `eth_sendRawTransaction` fails on a malformed payload too.
Check for `-32000` specifically.

## Notes

- **Open blocker.** `reth_data` initializes root-owned, so the uid-1000 execution layer cannot write and the stack
  does not start. Fix in the reth image (`mkdir -p /app/data && chown 1000:1000 /app/data`, as `Dockerfile.kaspad`
  already does), or `chown` the volume as root before first start.
- **Storage.** `IGRA_RETH_PRUNE_DISTANCE_BLOCKS=600000` (~7.3 days) bounds four reth history segments;
  `KASPAD_RETENTION_PERIOD_DAYS=7` bounds L1. **Neither bounds total disk**, and pruning is one-way per volume.
  `eth_getLogs` older than the window is unavailable, so `RPC_URL_2` must be archive-capable.
- **Chain data** lives in the named volumes `kaspad_data` and `reth_data` under `/var/lib/docker/volumes` — put
  that on the filesystem sized for it before first start.
- **The consumer's compose file** must list **both** `default` (with `gw_priority: 1`) and `igra-readonly-rpc`
  under `networks:`. An explicit list replaces the implicit default attachment, and `igra-readonly-rpc` is
  `internal`, so naming it alone costs the consumer all egress.
- **Sync reporting** sends the node id, chain head and versions to `${NODE_HEALTH_CHECK_URL}:8081` over plaintext
  HTTP with a shared API key. Drop the `node-health-check-client` service and its four variables if that trade is
  not worth it.
- **No inbound P2P.** No ports are published; kaspad syncs outbound-only.
- **Hardening is untested against these images.** All four services run `user: "1000:1000"`, `read_only: true` and
  `cap_drop: ALL`. If one fails at start, relax a single key on that service and file it.
