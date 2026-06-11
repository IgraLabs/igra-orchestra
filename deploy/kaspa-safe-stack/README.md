# Kaspa Safe Stack Deploy Bundle

This directory is the handoff package for DevOps. It deploys the Igra fork of
Safe Transaction Service with the Kaspa multisig coordination API and, when
enabled, the Rust proposal-builder daemon.

DevOps should not need to understand the internals. Fill `.env`, build, run
`up`, put HTTPS in front of the Safe API port, and monitor it.

For the full step-by-step operator runbook, including ports, external URL
mapping, RPC requirements, and health checks, read `HOWTO.md`.

## What This Deploys

Default `up` starts:

```text
Postgres  <--- durable federations/proposals/evidence/signatures/broadcasts
Redis     <--- cache/locks used by upstream Safe service
Safe API  <--- /api/v1/kaspa/... coordination API, includes kaspa-pst helper
```

Optional `builder-up` starts:

```text
Rust proposal-builder daemon
  -> reads Igra RPC and Kaspa RPC
  -> verifies exit windows and bridge reference files
  -> submits candidate proposals/evidence to Safe API
```

Signer private keys are never deployed here.

## First Deploy

Run from this directory:

```bash
./scripts/stack.sh prepare
vi .env
./scripts/stack.sh config
./scripts/stack.sh build
./scripts/stack.sh up
./scripts/stack.sh status
```

Then put a production reverse proxy or load balancer in front of:

```text
http://127.0.0.1:${SAFE_API_PORT}/
```

The public URL should look like:

```text
https://safe-transaction-service.igralabs.com/api/v1/kaspa/
```

## Required Git Access

`prepare` clones these repos into `../../build/repos/`:

```text
git@github.com:IgraLabs/safe-transaction-service.git branch kaspa-native-wallet-integration
git@github.com:IgraLabs/igra-proposal-builder-rs.git branch feature/rust-proposal-builder
```

The server running `prepare` needs a GitHub SSH key with access to both repos.

## Safe API Configuration

Review `.env` before production:

```text
DJANGO_SECRET_KEY
DJANGO_ALLOWED_HOSTS
POSTGRES_PASSWORD
DATABASE_URL
REDIS_URL
SAFE_API_PORT
KASPA_PST_HELPER_PATH=/usr/local/bin/kaspa-pst
KASPA_PST_HELPER_TIMEOUT=30
ETHEREUM_NODE_URL
```

Back up the `postgres-data` Docker volume. It contains all durable Safe/Kaspa
coordination state.

This deploy bundle intentionally runs Django migrations only. It does not run
upstream `setup_service`, indexer workers, or scheduler services. Some upstream
migrations still query `ETHEREUM_NODE_URL` for chain id, so set it to the Igra
L2 RPC for the target environment.

## Start Proposal Builder

Safe API can run without proposal-builder. Start proposal-builder only after the
bridge contracts and federation config are final.

Prepare files:

```bash
vi config/proposal-builder.json
cp <expected-values.json> refs/kas-exit-bridge-contract-authenticity.expected.json
cp <methodology.md> refs/kas-exit-bridge-query-audit-methodology.md
cp <checkpoint.initial.json> refs/checkpoint.initial.json
sha256sum refs/kas-exit-bridge-query-audit-methodology.md
```

Put that SHA-256 in `config/proposal-builder.json` as `keb.methodologySha256`.

Then run:

```bash
./scripts/stack.sh builder-up
./scripts/stack.sh builder-logs
```

## Day-2 Commands

```bash
./scripts/stack.sh status
./scripts/stack.sh logs
./scripts/stack.sh restart-api
./scripts/stack.sh migrate
./scripts/stack.sh builder-logs
./scripts/stack.sh down
```

## Upgrade

```bash
git pull
./scripts/stack.sh prepare
./scripts/stack.sh build
./scripts/stack.sh migrate
./scripts/stack.sh restart-api
./scripts/stack.sh builder-up
```

## What Not To Put Here

- No signer private keys.
- No signer wallet files.
- No custodial seed phrases.
- No manually edited database rows for quorum/proposal state.

Federation members verify and sign proposals with their own wallets.
