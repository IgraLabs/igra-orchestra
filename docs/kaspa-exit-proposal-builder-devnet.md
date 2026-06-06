# Kaspa Exit Proposal Builder Devnet

This devnet adds a separate proposal-builder container next to the vanilla
Safe Transaction Service API.

```text
Igra RPC
  |
  v
kaspa-proposal-builder
  - Rust daemon: scans finalized Igra exit windows
  - verifies contract expected-values and methodology hash
  - queries live Kaspa bridge UTXOs through kaspad JSON-RPC
  - builds old-kaspawallet-compatible unsigned PST bytes in Rust
  - submits exit batch + candidate proposal to Safe Transaction Service
  |
  v
kaspa-safe-api
  - stores proposal/evidence/signatures
  - tracks quorum
  - broadcasts only after quorum
```

The API does not run wallet signing and does not decide whether proposals are
legitimate. The Rust daemon container is the operator process that prepares
unsigned proposals. Signer wallets must still reverify proposals before signing.

## What Is Packaged

`build/Dockerfile.kaspa-exit-proposal-builder` builds one runtime image with:

- `igra-proposal-builder` from `build/repos/igra-proposal-builder-rs`
- Rust `kaspa-pst` from the same repo for helper/debug parity

`build/Dockerfile.kaspa-exit-safe-api` also packages Rust `kaspa-pst` from
`igra-proposal-builder-rs`. The Go `kaspad` repo remains in the devnet only for
wallet tooling: `kaspawallet`, `kaspa-msig-fixture`, and signer-side tests.

`scripts/dev/kaspa-exit-devnet.sh setup` clones:

- `safe-transaction-service`, for the Kaspa API/storage service
- `igra-proposal-builder-rs`, for Rust proposal-builder and Rust `kaspa-pst`
- `kaspad`, for Go wallet tooling only

## Start The Devnet

```bash
cp .env.kaspa-exit-devnet.example .env.kaspa-exit-devnet
./scripts/dev/kaspa-exit-devnet.sh setup
./scripts/dev/kaspa-exit-devnet.sh up
./scripts/dev/kaspa-exit-devnet.sh miner
./scripts/dev/kaspa-exit-devnet.sh real-spend-e2e
```

`real-spend-e2e` creates the multisig federation fixture and writes the
federation id to:

```text
build/kaspa-exit-devnet/results/federation.json
```

Before starting the Rust proposal-builder for real exits, deploy or configure
the Igra bridge contracts and provide matching expected-values/checkpoint
files. The proposal-builder refuses to run without those files.

## Proposal Builder Config

The daemon reads the rendered Rust config:

```text
build/kaspa-exit-devnet/proposal-builder/builder.json
```

Render it with:

```bash
./scripts/dev/kaspa-exit-devnet.sh render-builder-config
```

The renderer reads:

- `build/kaspa-exit-devnet/wallets/metadata.json`
- `build/kaspa-exit-devnet/results/federation.json`
- `KASPA_EXIT_BUILDER_EXPECTED_VALUES_FILE`
- `KASPA_EXIT_BUILDER_INITIAL_CHECKPOINT_FILE`
- `KASPA_EXIT_BUILDER_METHODOLOGY_FILE`

Config shape:

```json
{
  "network": "devnet",
  "l2ChainId": 38833,
  "igraRpcUrl": "http://execution-layer:8545",
  "safeApiUrl": "http://kaspa-safe-api:8888/api/v1/kaspa",
  "federationId": "00000000-0000-0000-0000-000000000000",
  "contracts": {
    "kasExitBridge": "0x...",
    "mailbox": "0x...",
    "merkleTreeHook": "0x..."
  },
  "bridge": {
    "address": "kaspadev:...",
    "scriptPublicKey": "...",
    "derivationPath": "m/0/0/1",
    "threshold": 2,
    "ecdsa": false,
    "kpubs": ["kpub...", "kpub...", "kpub..."]
  },
  "finality": {
    "confirmationBlocks": 12
  },
  "keb": {
    "expectedValuesFile": "/work/proposal-builder/kas-exit-bridge-contract-authenticity.expected.json",
    "methodologyFile": "/work/proposal-builder/kas-exit-bridge-query-audit-methodology.md",
    "methodologySha256": "...",
    "initialCheckpointFile": "/work/proposal-builder/checkpoint.initial.json",
    "deltaBlocks": 86400
  },
  "kaspa": {
    "rpcUrl": "http://kaspad:18610",
    "coinbaseMaturityDaa": 1000,
    "maxInputs": 64
  },
  "pst": {
    "txIdPrefix": "97b1",
    "feeSompi": 1000000,
    "maxPayloadNonceAttempts": 1000000
  }
}
```

The contract addresses must match the deployed KasExitBridge, Mailbox, and
MerkleTreeHook contracts. The expected-values file must match those deployed
contracts. This is intentionally not inferred from proposals.

## Run The Daemon

```bash
./scripts/dev/kaspa-exit-devnet.sh proposal-builder
```

By default the service runs forever:

```text
finalized Igra window -> Rust evidence verification -> live Kaspa UTXOs -> Rust PST -> safe proposal
```

For a one-shot smoke run:

```bash
KASPA_EXIT_BUILDER_MODE=once ./scripts/dev/kaspa-exit-devnet.sh proposal-builder
```

If the next KEB window is not finalized, the command skips that cycle and sleeps.
If checkpoints, expected contract values, methodology files, contract addresses,
or live spendable Kaspa UTXOs are missing, it fails loudly instead of pretending
the daemon is healthy.

## Igra Genesis Funding

The devnet mounts `build/kaspa-exit-devnet/reth/genesis.template.json` into the
execution-layer container. `./scripts/dev/kaspa-exit-devnet.sh up` generates this
template from the checked-out `reth-private` template, adds `EL_ONE_TIME_ADDRESS`
with `EL_ONE_TIME_BALANCE`, starts the execution layer, reads its real genesis
hash, writes `GENESIS_BLOCK_HASH` back into `.env.kaspa-exit-devnet`, and only
then starts kaspad. Kaspad hard-fails if that hash does not match the EL genesis.

If `EL_ONE_TIME_ADDRESS` changes after the execution layer has initialized, stop
the isolated devnet and remove only its reth/kaspad volumes before running `up`
again. Genesis allocations cannot be changed in-place.

The query/audit methodology file is vendored under
`tools/kasExitBridge/docs/kas-exit-bridge-query-audit-methodology.md`, so the
config renderer can copy it into the devnet work directory without relying on an
external history-data checkout.
