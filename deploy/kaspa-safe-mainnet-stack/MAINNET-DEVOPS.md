# Mainnet DevOps Runbook

This runbook explains how to deploy the Igra Kaspa Safe stack for mainnet.

Use this directory only for the production path:

```text
Igra L2 mainnet + mainnet KasExitBridge + Kaspa mainnet
```

For testnet/devnet, use `deploy/kaspa-safe-stack` instead.

## Components

```text
                         public HTTPS
                              |
                              v
                  safe-transaction-service.igralabs.com
                              |
                              v
                    reverse proxy / load balancer
                              |
                              v
                  127.0.0.1:${SAFE_API_PORT}
                              |
                              v
                         +----------+
                         | safe-api |
                         +----------+
                           |      |
                           |      +-------> Redis
                           |
                           +--------------> Postgres


                         separate Docker project

                         +------------------+
                         | proposal-builder |
                         | keyless daemon   |
                         +------------------+
                           |       |       |
                           |       |       +--> Kaspa mainnet RPC
                           |       +----------> Igra L2 mainnet RPC
                           +------------------> Safe API /api/v1/kaspa
```

Signer wallets are outside this deployment:

```text
signer wallet
   |
   +--> Safe API, to fetch proposals and submit signatures
   +--> Igra L2 RPC, to verify exits and finality locally
   +--> Kaspa RPC, to verify UTXOs and final transaction locally
   +--> private keys, local/offline signer-controlled only
```

## What We Added On Top Of Upstream Safe

Upstream Safe Transaction Service is an Ethereum/Safe coordination service.
This Igra fork adds a Kaspa-native coordination layer:

- `/api/v1/kaspa/federations/`
- `/api/v1/kaspa/transactions/`
- proposal evidence storage
- signer signature submission
- quorum state
- PST inspect, merge, and broadcast through the bundled `kaspa-pst` helper

Safe API stores and serves candidate proposals. It does not decide whether a
proposal is trustworthy. Signer wallets verify every proposal locally before
signing.

## Docker Projects

Mainnet uses two separate Compose files.

Safe API:

```text
docker-compose.safe.yml
services: safe-api, safe-migrate, postgres, redis
```

Proposal builder:

```text
docker-compose.proposal-builder.yml
services: proposal-builder
```

Keeping them separate lets DevOps scale, restart, and isolate them
independently. Safe API can stay up even if proposal-builder is paused.

## Exposed Ports

Expose only Safe API through a host reverse proxy or load balancer.

Default Docker port mapping:

```text
127.0.0.1:${SAFE_API_PORT:-8888} -> safe-api:8888
```

Recommended public mapping:

```text
https://safe-transaction-service.igralabs.com/
    -> http://127.0.0.1:${SAFE_API_PORT}/
```

Important public API base:

```text
https://safe-transaction-service.igralabs.com/api/v1/kaspa/
```

Do not expose these directly to the Internet:

```text
postgres:5432       internal Docker network only
redis:6379          internal Docker network only
proposal-builder    no public port
```

## Required External RPCs

Safe API needs an Igra L2 mainnet RPC:

```text
ETHEREUM_NODE_URL=https://<real-igra-l2-mainnet-rpc>
ETH_L2_NETWORK=true
```

The upstream Django migrations query chain id through this RPC. Safe API does
not need a permanent Kaspa RPC URL for normal proposal/signature coordination.
For final Kaspa broadcast, the caller supplies the Kaspa RPC URL in the
broadcast request.

Proposal-builder needs:

```text
igraRpcUrl      real Igra L2 mainnet JSON-RPC
kaspa.rpcUrl    real Kaspa mainnet RPC
safeApiUrl      Safe API Kaspa base URL
```

Signer wallets need their own Safe API URL, Igra RPC, and Kaspa RPC for local
verification. A signer should not blindly trust either proposal-builder or Safe
API.

## First Safe API Deploy

Run from this directory:

```bash
./scripts/safe.sh prepare
vi .env.safe
./scripts/safe.sh check-env
./scripts/safe.sh config
./scripts/safe.sh build
./scripts/safe.sh up
./scripts/safe.sh status
```

`prepare` creates local editable files if they do not exist:

```text
.env.safe
.env.proposal-builder
config/proposal-builder.json
```

It also clones or updates the build repos under:

```text
build/repos/safe-transaction-service
build/repos/igra-proposal-builder-rs
```

The Safe API Docker image uses `igra-proposal-builder-rs` only to build and
embed the `kaspa-pst` helper binary. It does not run proposal-builder inside the
Safe API container.

The host running `prepare` needs GitHub SSH access to:

```text
git@github.com:IgraLabs/safe-transaction-service.git
git@github.com:IgraLabs/igra-proposal-builder-rs.git
```

## Safe API Env

Edit `.env.safe` and replace every `CHANGE_ME`.

Required values:

```text
COMPOSE_PROJECT_NAME=igra-safe-mainnet
SAFE_API_BIND=127.0.0.1
SAFE_API_PORT=8888
SAFE_PUBLIC_URL=https://safe-transaction-service.igralabs.com

DJANGO_SECRET_KEY=<operator-supplied-web-app-secret>
DJANGO_ALLOWED_HOSTS=safe-transaction-service.igralabs.com,localhost,127.0.0.1
POSTGRES_PASSWORD=<operator-supplied-db-password>
DATABASE_URL=psql://safe:<same-db-password>@postgres:5432/safe_transaction_service
REDIS_URL=redis://redis:6379/0

ETHEREUM_NODE_URL=https://<real-igra-l2-mainnet-rpc>
ETH_L2_NETWORK=true

KASPA_PST_HELPER_PATH=/usr/local/bin/kaspa-pst
KASPA_PST_HELPER_TIMEOUT=30
```

`DJANGO_SECRET_KEY` and `POSTGRES_PASSWORD` are normal infrastructure secrets.
They are not blockchain private keys and do not control federation funds.

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

Use rate limiting and request-size limits at the proxy or load balancer. Public
proposal endpoints can receive evidence payloads, so the body-size limit must
be high enough for real exit bundles but low enough to reject abuse.

## Safe API Health Checks

Local health:

```bash
curl -fsS http://127.0.0.1:${SAFE_API_PORT}/check/
```

Expected:

```text
Ok
```

Kaspa API:

```bash
curl -fsS http://127.0.0.1:${SAFE_API_PORT}/api/v1/kaspa/federations/
```

Expected: HTTP 200 JSON response. A new database can return an empty list.

## Proposal-Builder Config

Edit:

```bash
vi config/proposal-builder.json
```

Required mainnet values:

```text
network=mainnet
l2ChainId=<real Igra L2 mainnet chain id>
igraRpcUrl=https://<real-igra-l2-mainnet-rpc>
safeApiUrl=https://safe-transaction-service.igralabs.com/api/v1/kaspa

contracts.kasExitBridge=<real mainnet KasExitBridge>
contracts.mailbox=<real mainnet Mailbox>
contracts.merkleTreeHook=<real mainnet MerkleTreeHook>

bridge.address=<real Kaspa mainnet bridge custody address>
bridge.scriptPublicKey=<real bridge lock script public key hex>
bridge.threshold=<required signer threshold>
bridge.kpubs=<all federation signer xpub/kpub values>

kaspa.rpcUrl=<real Kaspa mainnet RPC>
keb.deltaBlocks=<mainnet exit window size, currently 86400 unless bridge config changes>
```

The proposal-builder daemon owns its own local state file:

```text
/state/proposal-builder-state.json
```

This is not signing state. It is only daemon progress/checkpoint state.

## KEB Reference Files

Place real mainnet reference files in `refs/`:

```bash
cp <expected-values.json> refs/kas-exit-bridge-contract-authenticity.expected.json
cp <methodology.md> refs/kas-exit-bridge-query-audit-methodology.md
cp <checkpoint.initial.json> refs/checkpoint.initial.json
sha256sum refs/kas-exit-bridge-query-audit-methodology.md
```

Copy that SHA-256 into `config/proposal-builder.json`:

```text
keb.methodologySha256=<sha256>
```

These files tell proposal-builder and signer wallets what exact bridge
methodology and starting checkpoint they are verifying against.

## Start Proposal Builder

Run:

```bash
./scripts/proposal-builder.sh prepare
vi .env.proposal-builder
./scripts/proposal-builder.sh check-config
./scripts/proposal-builder.sh config
./scripts/proposal-builder.sh build
./scripts/proposal-builder.sh validate-config
./scripts/proposal-builder.sh up
./scripts/proposal-builder.sh logs
```

Proposal-builder runs continuously in daemon mode:

```text
KASPA_EXIT_BUILDER_MODE=daemon
KASPA_EXIT_BUILDER_POLL_SECONDS=300
```

It should not be run by hand for normal operation. Manual runs are useful for
diagnostics, but production should use the daemon container so exit windows are
checked consistently.

## Duplicate Proposals

Safe API accepts proposals as candidates. Signer wallets should fetch proposals
for their federation, verify each one locally, and show only proposals that
pass verification. This avoids relying on "first proposal wins".

If a bad proposal is submitted by anyone, signers simply do not sign it. Another
valid proposal for the same exit window can still be submitted and signed.

## Broadcasting A Final Transaction

After quorum is reached, an operator or wallet can broadcast through Safe API:

```http
POST /api/v1/kaspa/transactions/{proposal_hash}/broadcast/
Content-Type: application/json

{
  "rpc_url": "https://<real-kaspa-mainnet-rpc>"
}
```

Safe API uses the bundled `kaspa-pst` helper to merge/inspect/broadcast the
final Kaspa transaction. The Kaspa RPC URL is supplied at broadcast time so
operators can choose their trusted RPC.

## Hardware Guidance

Safe API is mostly database-backed coordination. It does not mine, scan full
Kaspa history, or index Igra history.

Reasonable starting point for mainnet:

```text
Safe API host:        2-4 vCPU, 4-8 GB RAM
Postgres volume:      start at 50 GB, monitor growth
Redis memory:         256 MB to 1 GB is usually enough
Proposal-builder:     1-2 vCPU, 1-2 GB RAM
Network:              reliable outbound access to Igra RPC and Kaspa RPC
```

Increase CPU/RAM if request volume grows, proposal evidence becomes large, or
the reverse proxy shows sustained queueing. Postgres disk is the most important
durable resource.

## Abuse And Rate Limits

Public Safe API endpoints can be called by untrusted users. Expected defenses:

- HTTPS reverse proxy with request body limits
- IP-based rate limiting
- application logs shipped to monitoring
- Postgres disk alerts
- alert on repeated failed proposal submissions

If users spam bad proposals, the primary risk is storage and request load, not
loss of funds. Signers still verify locally and should not sign invalid
proposals.

## Backups

Back up the Safe API Postgres volume:

```text
igra-safe-mainnet_postgres-data
```

This contains federation, proposal, evidence, signature, and broadcast records.

Redis can be persisted, but Postgres is the critical durable state.

The proposal-builder state volume is useful for daemon continuity:

```text
igra-proposal-builder-mainnet_proposal-builder-state
```

It can be rebuilt from chain data and config, but keeping it avoids unnecessary
rescans.

## Upgrade

Safe API:

```bash
git pull
./scripts/safe.sh prepare
./scripts/safe.sh check-env
./scripts/safe.sh build
./scripts/safe.sh migrate
./scripts/safe.sh restart-api
./scripts/safe.sh status
```

Proposal-builder:

```bash
git pull
./scripts/proposal-builder.sh prepare
./scripts/proposal-builder.sh check-config
./scripts/proposal-builder.sh build
./scripts/proposal-builder.sh validate-config
./scripts/proposal-builder.sh up
./scripts/proposal-builder.sh status
```

Back up Postgres before major upgrades.

## Stop

Safe API:

```bash
./scripts/safe.sh down
```

Proposal-builder:

```bash
./scripts/proposal-builder.sh down
```

Stopping proposal-builder only pauses automatic proposal creation. It does not
remove proposals or signatures already stored in Safe API.
