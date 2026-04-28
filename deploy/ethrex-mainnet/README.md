# Ethrex Mainnet Deployment

This deployment package runs IGRA mainnet with `ethrex` as the orchestra
`execution-layer` service instead of the default `reth`.

It follows the normal orchestra model:

- Docker Compose owns the `execution-layer` lifecycle.
- `kaspad` still talks to `http://execution-layer:8545`.
- `node-health-check-client` still talks to `http://execution-layer:8545`.
- JWT, data, and generated network params are mounted into the execution-layer
  container.

This package uses the standard mainnet ports and standard container names. It is
meant to replace the default mainnet execution-layer in a dedicated orchestra
deployment.

It is not for running side by side with another mainnet orchestra deployment on
the same host unless you change ports, project names, and container names.

## Files

- `.env.example` - non-secret mainnet env template for the ethrex deployment
- `docker-compose.ethrex-mainnet.yml` - compose override that swaps `reth` for
  `ethrex`

## Prepare Orchestra

```sh
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
git switch ethrex-integration
```

Create the environment file:

```sh
cp deploy/ethrex-mainnet/.env.example .env
cat versions.mainnet.env >> .env
```

Edit `.env` before first launch:

- Set a unique `NODE_ID`.
- Set `IGRA_ORCHESTRA_DOMAIN` and `IGRA_ORCHESTRA_DOMAIN_EMAIL`.
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
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  --profile backend \
  config --quiet
```

## Start Backend

Build only the ethrex execution-layer image:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  build execution-layer
```

Start backend with pinned Docker Hub images for the other services:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  --profile backend \
  up -d --no-build
```

This starts:

- `execution-layer`
- `kaspad`
- `node-health-check-client`

## Host Ports

This override keeps the standard mainnet orchestra host ports:

| Service | Host | Container |
|---|---:|---:|
| ethrex HTTP RPC | `127.0.0.1:9545` | `8545` |
| ethrex WebSocket RPC | `127.0.0.1:9546` | `8546` |
| kaspad gRPC | `16110` | `16110` |
| kaspad P2P | `16111` | `16111` |
| kaspad Borsh RPC | `17110` | `17110` |
| kaspad JSON RPC | `18110` | `18110` |

## Verify

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  --profile backend \
  ps
```

Check ethrex:

```sh
curl -sS http://127.0.0.1:9545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'
```

Expected chain ID:

```text
0x97b1
```

Check sync:

```sh
curl -sS http://127.0.0.1:9545 \
  -H 'Content-Type: application/json' \
  --data '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":2}'
```

Check logs:

```sh
docker logs -f execution-layer
docker logs -f kaspad
docker logs -f node-health-check-client
```

## Frontend / Worker Services

After backend sync, start workers with the same override:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  --profile frontend-w5 \
  up -d --no-build
```

Or start backend and frontend together:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  --profile backend \
  --profile frontend-w5 \
  up -d --no-build
```

Use `frontend-w1` through `frontend-w20` depending on the number of worker pairs
you want.

## Stop

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-mainnet/docker-compose.ethrex-mainnet.yml \
  --profile backend \
  --profile frontend-w5 \
  down
```

Do not use `-v` unless you intentionally want to delete the ethrex and kaspad
data volumes.
