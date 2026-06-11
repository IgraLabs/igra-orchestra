# Igra Kaspa Safe Mainnet Stack

This directory is the mainnet-only deployment bundle for the Igra Kaspa Safe
coordination service.

It is intentionally separate from `deploy/kaspa-safe-stack`, which is used for
testnet/devnet style deployments. Use this directory only for:

```text
real Igra L2 mainnet
real Igra L2 KasExitBridge / Mailbox / MerkleTreeHook contracts
real Kaspa mainnet
```

## What Runs

Safe Transaction Service runs as one Docker Compose project:

```text
Internet
   |
   v
HTTPS reverse proxy / load balancer
   |
   v
127.0.0.1:${SAFE_API_PORT}
   |
   v
+----------+        +----------+
| safe-api | -----> | Postgres |
|  :8888   |        +----------+
|          | -----> +-------+
+----------+        | Redis |
                    +-------+
```

Proposal-builder runs as a separate Docker Compose project:

```text
+------------------+
| proposal-builder |
| daemon, no keys  |
+------------------+
   |        |        |
   |        |        +--> Kaspa mainnet RPC
   |        +----------> Igra L2 mainnet RPC
   +-------------------> Safe API /api/v1/kaspa
```

Signer private keys, signer wallet files, and seed phrases are not deployed in
either project.

## Mainnet Safety Model

The proposal-builder is allowed to know public federation material:

- canonical bridge custody address
- lock script / script public key
- federation signer kpubs
- threshold
- Igra bridge contract addresses
- Igra and Kaspa RPC URLs

The proposal-builder must not know private keys. It observes finalized exit
windows, builds candidate unsigned PST proposals with evidence, and submits
them to Safe Transaction Service.

Safe Transaction Service stores proposals, evidence, signatures, and broadcast
attempts. It coordinates quorum, but it is not a trust oracle. Signers verify
proposal evidence locally with their own wallet tooling and their own RPCs
before signing.

## No Generated Custody Secrets

This mainnet bundle does not generate any credentials automatically.

Operators must provide:

```text
DJANGO_SECRET_KEY    ordinary Django web-app secret
POSTGRES_PASSWORD   ordinary database password
```

These are infrastructure credentials only. They are not federation keys, Kaspa
keys, custody keys, or signing material.

## Read Next

Use `MAINNET-DEVOPS.md` for the full operator runbook: ports, env files,
required RPCs, first deploy, proposal-builder start, upgrades, and backups.
