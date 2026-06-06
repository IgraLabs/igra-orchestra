# Igra Q Logic Zone Staging

This package adds the Falcon-L5 q-logic-zone beside the canonical first Igra
zone.

The intended M1 topology is:

```text
Kaspa / rusty-kaspa-private
  |-- 0x92/0x94/0x95 --> canonical execution-layer
  `-- 0x9F zone_id=0x0002 --> q-execution-layer
```

Both zones use the same Kaspa sequencing source. The canonical first Igra zone
remains unchanged; q-zone traffic is opt-in through `0x9F` envelopes.

## Branches

Use the same branch name across active development repos:

```text
igra-q-logic-zone
```

Expected q-zone repo layout:

```text
build/repos/rusty-kaspa-private  branch igra-q-logic-zone
build/repos/ethrex-q             branch igra-q-logic-zone
```

`build/repos/ethrex-q` is the Falcon-L5 q-ethrex checkout. If the canonical
first zone is also ethrex, keep it as a separate checkout under
`build/repos/ethrex`.

## Q-Ethrex Packaging

The q-zone compose service expects the q-ethrex image to expose this Igra EL
container interface:

```text
/app/run-igra-el.sh
/app/genesis.template.json
/app/network-params.template.md
```

The `igra-q-logic-zone` ethrex branch provides these files. The wrapper
generates q genesis/network params, can print the computed q genesis hash, and
then starts ethrex with HTTP, WebSocket, and authenticated Engine API endpoints
for rusty-kaspa-private.

## Prepare Repos

From the orchestra root:

```sh
scripts/dev/setup-q-zone-repos.sh
```

The script clones/checks out:

```text
rusty-kaspa-private -> igra-q-logic-zone
ethrex-q            -> igra-q-logic-zone
```

## Isolated Devnet

Create a dedicated working directory on staging; do not reuse an existing
mainnet/testnet directory.

```sh
cp deploy/igra-q-zone-staging/.env.devnet.example .env
cat versions.testnet.env >> .env
mkdir -p keys network-params
openssl rand -hex 32 > keys/jwt.hex
openssl rand -hex 32 > keys/q-jwt.hex
chmod 600 keys/jwt.hex keys/q-jwt.hex
```

Before first boot, set a real mining address:

```text
MINING_ADDRESS=
```

The template pins the current M1 q genesis hash:

```text
IGRA_Q_GENESIS_BLOCK_HASH=0x1982147dd8e731fc6463b3a8a2c78b92cd8ea6dcb21accdcd60de9ee659c375b
```

If any q genesis input changes, recompute it with q-ethrex:

```sh
IGRA_PRINT_GENESIS_HASH_AND_EXIT=true /app/run-igra-el.sh
```

Validate compose:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-staging.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-devnet.yml \
  --profile backend \
  --profile q-zone \
  --profile kaspa-miner \
  config --quiet
```

Start:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-staging.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-devnet.yml \
  --profile backend \
  --profile q-zone \
  --profile kaspa-miner \
  up -d
```

## Official Galleon Plus Q-Zone

To run beside official Galleon staging with original canonical Igra ethrex,
prepare the normal Galleon ethrex env first:

```sh
cp deploy/ethrex-galleon-staging/.env.example .env
cat versions.testnet.env >> .env
cat deploy/igra-q-zone-staging/.env.q-zone.example >> .env
```

Generate a second JWT:

```sh
mkdir -p keys network-params
openssl rand -hex 32 > keys/q-jwt.hex
chmod 600 keys/q-jwt.hex
```

Use all three compose files:

```sh
docker compose \
  -f docker-compose.yml \
  -f deploy/ethrex-galleon-staging/docker-compose.ethrex-galleon.yml \
  -f deploy/igra-q-zone-staging/docker-compose.q-zone-staging.yml \
  --profile backend \
  --profile q-zone \
  config --quiet
```

Then start with the same files and profiles.

## Host Ports

Default q-zone staging ports:

| Service | Host | Container |
|---|---:|---:|
| q-ethrex HTTP RPC | `127.0.0.1:29545` | `8545` |
| q-ethrex WebSocket RPC | `127.0.0.1:29546` | `8546` |
| kaspad gRPC | `56210` | `16210` |
| kaspad P2P | `56211` | `16211` |
| kaspad Borsh RPC | `57210` | `17210` |
| kaspad JSON RPC | `58210` | `18210` |

Change the host ports in `.env` or the override before using a shared staging
host if any port is already occupied.

The kaspad ports above are applied only by
`docker-compose.q-zone-devnet.yml`. The official Galleon sidecar mode keeps the
Galleon kaspad ports from `docker-compose.ethrex-galleon.yml` and only adds the
q-ethrex RPC ports.
