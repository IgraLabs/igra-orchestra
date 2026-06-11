# Kaspa Safe Stack How-To

This is the operational runbook for deploying the Igra Kaspa Safe stack.

Use this when DevOps needs to deploy the coordination service for federation
members. It is intentionally command-oriented.

## What Runs

```text
                    external HTTPS URL
                            |
                            v
                    reverse proxy / LB
                            |
                            v
host 127.0.0.1:${SAFE_API_PORT} -> safe-api:8888
                            |
              +-------------+-------------+
              |                           |
              v                           v
          Postgres                      Redis

optional:

proposal-builder -> Safe API
proposal-builder -> Igra RPC
proposal-builder -> Kaspa RPC
```

The default stack starts only:

- `postgres`
- `redis`
- `safe-api`

The `proposal-builder` service is optional and started separately.

No signer private keys are deployed in this stack.

## Ports

Only one Docker service should be exposed outside Docker:

```text
host:${SAFE_API_PORT} -> safe-api:8888
```

Default:

```text
127.0.0.1:8888 -> safe-api:8888
```

Production should expose this through HTTPS:

```text
https://safe-transaction-service.igralabs.com/
    -> http://127.0.0.1:${SAFE_API_PORT}/
```

Important API base URL:

```text
https://safe-transaction-service.igralabs.com/api/v1/kaspa/
```

Do not expose Postgres or Redis to the Internet.

```text
postgres:5432   internal Docker network only
redis:6379      internal Docker network only
proposal-builder no public port
```

## Reverse Proxy

Example Nginx shape:

```nginx
server {
    listen 443 ssl http2;
    server_name safe-transaction-service.igralabs.com;

    client_max_body_size 50m;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }
}
```

Use WAF/rate limiting at the proxy/LB layer. Public endpoints accept proposal
and evidence payloads, so body-size limits must not be tiny.

## Required External Access

Safe API needs:

```text
GitHub SSH access at build time
Postgres
Redis
Igra/EVM RPC as ETHEREUM_NODE_URL for upstream migrations and chain id
Outbound HTTPS if notifications/monitoring are enabled
```

Use the target Igra L2 JSON-RPC as:

```text
ETHEREUM_NODE_URL=https://<igra-rpc>
ETH_L2_NETWORK=true
```

The deploy bundle does not run upstream indexer workers or scheduler services,
but upstream migrations still query this RPC for chain id.

Safe API does not need a permanent Kaspa RPC URL for normal proposal/signature
coordination. For final broadcast, the caller sends the Kaspa RPC URL in:

```http
POST /api/v1/kaspa/transactions/{proposal_hash}/broadcast/
```

Request body:

```json
{
  "rpc_url": "https://kaspa-testnet-rpc.example"
}
```

Proposal-builder needs:

```text
Igra RPC URL       reads finalized Igra blocks, receipts, logs, contract state
Kaspa RPC URL      reads custody UTXOs and validates spendability
Safe API URL       submits exit batches and proposals
GitHub SSH access  only if building from source on the host
```

Signer wallets need their own:

```text
Safe API URL
Igra RPC URL
Kaspa RPC URL
local wallet keys, usually offline or local-only
```

## First Deploy

```bash
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
git checkout kaspa-exit-devnet-laptop

cd deploy/kaspa-safe-stack
./scripts/stack.sh prepare
vi .env
./scripts/stack.sh config
./scripts/stack.sh build
./scripts/stack.sh up
./scripts/stack.sh status
```

`prepare` creates `.env`, generates local secrets, creates
`config/proposal-builder.json`, and clones/updates the two build repos under:

```text
build/repos/safe-transaction-service
build/repos/igra-proposal-builder-rs
```

Review `.env` before production. At minimum check:

```text
COMPOSE_PROJECT_NAME
SAFE_API_PORT
DJANGO_ALLOWED_HOSTS
DJANGO_SECRET_KEY
POSTGRES_PASSWORD
DATABASE_URL
REDIS_URL
ETHEREUM_NODE_URL
ETH_L2_NETWORK=true
KASPA_PST_HELPER_PATH=/usr/local/bin/kaspa-pst
KASPA_PST_HELPER_TIMEOUT=30
```

## Health Check

Local host check:

```bash
curl -fsS http://127.0.0.1:${SAFE_API_PORT}/check/
```

Expected:

```text
Ok
```

Kaspa API check:

```bash
curl -fsS http://127.0.0.1:${SAFE_API_PORT}/api/v1/kaspa/federations/
```

Expected: HTTP 200 JSON response, often an empty list/page on a new database.

## Start Proposal Builder

Only start proposal-builder after the bridge contract addresses and federation
public material are final.

Edit:

```bash
vi config/proposal-builder.json
```

Required fields:

```text
igraRpcUrl
safeApiUrl
contracts.kasExitBridge
contracts.mailbox
contracts.merkleTreeHook
bridge.address
bridge.scriptPublicKey
bridge.threshold
bridge.kpubs
kaspa.rpcUrl
keb.expectedValuesFile
keb.methodologyFile
keb.methodologySha256
keb.initialCheckpointFile
```

Put reference files here:

```bash
cp <expected-values.json> refs/kas-exit-bridge-contract-authenticity.expected.json
cp <methodology.md> refs/kas-exit-bridge-query-audit-methodology.md
cp <checkpoint.initial.json> refs/checkpoint.initial.json
sha256sum refs/kas-exit-bridge-query-audit-methodology.md
```

Copy the SHA-256 into `config/proposal-builder.json` as
`keb.methodologySha256`.

Start:

```bash
./scripts/stack.sh builder-up
./scripts/stack.sh builder-logs
```

## Upgrade

```bash
git pull
cd deploy/kaspa-safe-stack
./scripts/stack.sh prepare
./scripts/stack.sh config
./scripts/stack.sh build
./scripts/stack.sh migrate
./scripts/stack.sh restart-api
./scripts/stack.sh builder-up
```

## Backups

Back up the Postgres Docker volume:

```text
${COMPOSE_PROJECT_NAME}_postgres-data
```

This contains durable federation/proposal/evidence/signature/broadcast state.

Redis can be persisted, but Postgres is the critical state.

## What Was Tested

The deploy bundle has been validated with:

```bash
docker compose --env-file .env.example -f docker-compose.yml config --quiet
bash -n scripts/prepare.sh
bash -n scripts/stack.sh
./scripts/stack.sh prepare
./scripts/stack.sh config
```

For a real host acceptance test, run:

```bash
./scripts/stack.sh build
./scripts/stack.sh up
./scripts/stack.sh status
curl -fsS http://127.0.0.1:${SAFE_API_PORT}/check/
curl -fsS http://127.0.0.1:${SAFE_API_PORT}/api/v1/kaspa/federations/
```

Staging smoke on `stage-roman.igralabs.com`:

```text
project: codex-kaspa-safe-stack-20260611b
host port: 19088
ETHEREUM_NODE_URL: http://172.17.0.1:18545
Postgres: healthy
Redis: healthy
Safe API: healthy
/check/: HTTP 200 Ok
/api/v1/kaspa/federations/: HTTP 200 {"count":0,...}
/usr/local/bin/kaspa-pst exists in safe-api container
```

The staging smoke used an existing host-local Igra RPC. In production, use the
real environment's Igra L2 RPC URL in `.env` as `ETHEREUM_NODE_URL`.

## Do Not Deploy

- signer private keys
- wallet seed phrases
- signer wallet databases
- manually edited quorum/proposal rows

Signer machines verify and sign independently.
