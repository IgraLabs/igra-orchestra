# Ethrex Galleon Staging Deployment

This profile runs the Galleon public testnet on the same machine as other
orchestra deployments, but replaces the default `reth` execution layer with an
`ethrex` execution-layer container.

The deployment follows the original orchestra model:

- Docker Compose owns the `execution-layer` lifecycle.
- `kaspad` still talks to `http://execution-layer:8545`.
- `node-health-check-client` still talks to `http://execution-layer:8545`.
- JWT, data, and generated network params are mounted into the execution-layer
  container.

It does **not** use the host-process/socat-proxy pattern used by the temporary
mainnet ethrex staging deployment.

## Files

- `.env.example` - non-secret Galleon env template.
- `docker-compose.ethrex-galleon.yml` - compose override for ethrex and
  same-host name/port isolation.

## Runtime Layout

Use a separate directory for this deployment. Do not reuse the mainnet staging
directory.

```sh
mkdir -p /home/roman/galleon-ethrex-integration
cd /home/roman/galleon-ethrex-integration
```

Expected checkout layout:

```text
/home/roman/galleon-ethrex-integration/
  igra-orchestra/
    .env
    keys/jwt.hex
    network-params/
    build/repos/ethrex/
```

## Prepare Orchestra

```sh
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
git switch ethrex-integration
```

Create the environment file:

```sh
cp deploy/ethrex-galleon-staging/.env.example .env
cat versions.testnet.env >> .env
```

Edit `.env` before first launch:

- Set a unique `NODE_ID`.
- Keep the `GENESIS_BLOCK_HASH` from `.env.example`; it is the canonical
  Galleon env value. Some older docs contain a stale value.
- Keep `BITCOIN_BLOCK_HASH`, `ETHEREUM_BLOCK_HASH`, and `KASPA_BLOCK_HASH`
  aligned with `.env.example` unless the Galleon network definition changes.
- Replace wallet placeholders before starting frontend profiles.

Generate the JWT file:

```sh
mkdir -p keys network-params
openssl rand -hex 32 > keys/jwt.hex
chmod 600 keys/jwt.hex
```

## Prepare Ethrex

Clone ethrex into the compose build context:

```sh
mkdir -p build/repos
git clone git@github.com:IgraLabs/ethrex.git build/repos/ethrex
cd build/repos/ethrex
git switch igra-mainnet-ethrex-integration
git checkout c19d255e1d99797e08493396005762349173b9b2
cd ../../..
```

The ethrex checkout must include:

- `Dockerfile`
- `igra/run-igra-el.sh`
- `igra/genesis.template.json`
- `igra/network-params.template.md`

## Validate Compose

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  --profile backend \
  config --quiet
```

## Start Backend

Build only the ethrex execution-layer image:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  build execution-layer
```

Start the backend with the pinned Docker Hub images for the other services:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  --profile backend \
  up -d --no-build
```

This starts:

- `galleon-execution-layer`
- `galleon-kaspad`
- `galleon-node-health-check-client`

## Host Ports

The override avoids the current mainnet staging ports.

| Service | Host | Container |
|---|---:|---:|
| ethrex HTTP RPC | `127.0.0.1:19545` | `8545` |
| ethrex WebSocket RPC | `127.0.0.1:19546` | `8546` |
| kaspad gRPC | `46210` | `16210` |
| kaspad P2P | `46211` | `16211` |
| kaspad Borsh RPC | `47210` | `17210` |
| kaspad JSON RPC | `48210` | `18210` |
| Traefik RPC, if frontend is enabled | `18545` | `8545` |

## Verify

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  --profile backend \
  ps
```

Check ethrex:

```sh
curl -sS http://127.0.0.1:19545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

Expected chain ID:

```text
0x97b4
```

Check the ethrex binary ref:

```sh
curl -sS http://127.0.0.1:19545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"web3_clientVersion","params":[],"id":2}'
```

The result should include `c19d255e1d99797e08493396005762349173b9b2`
unless you intentionally advanced `ETHREX_SOURCE_REF`.

Check sync:

```sh
curl -sS http://127.0.0.1:19545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":2}'
```

Check logs:

```sh
docker logs -f galleon-execution-layer
docker logs -f galleon-kaspad
docker logs -f galleon-node-health-check-client
```

## Frontend / Load Testing

After backend sync, start workers with the same override:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  --profile frontend-w5 \
  up -d --no-build
```

The override prefixes fixed container names with `galleon-` and moves Traefik
host ports away from the default `80`, `443`, `8545`, and `9001`.

## Stop

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  --profile backend \
  --profile frontend-w5 \
  down
```

Do not use `-v` unless you intentionally want to delete the Galleon ethrex and
kaspad data volumes.
