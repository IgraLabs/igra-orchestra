# Kaspa Exit Proposal Builder Devnet

This devnet adds a separate proposal-builder container next to the vanilla
Safe Transaction Service API.

```text
Igra RPC
  |
  v
kaspa-proposal-builder
  - KEB runner: scans finalized Igra exit windows and writes .bundle evidence
  - Foundry cast: builds and verifies unsigned Kaspa PST material
  - kaspa-pst: queries live Kaspa bridge UTXOs through kaspad RPC
  |
  v
kaspa-safe-api
  - stores proposal/evidence/signatures
  - tracks quorum
  - broadcasts only after quorum
```

The API does not run KEB, Foundry, or wallet signing. The daemon container is
the operator process that prepares unsigned proposals.

## What Is Packaged

`build/Dockerfile.kaspa-exit-proposal-builder` builds one runtime image with:

- `kaspa-pst` from the Go `kaspad` wallet/helper repo
- Foundry `cast` from the Igra Foundry branch
- KEB TypeScript tooling from `build/repos/kasExitBridge`
- the Safe Transaction Service Django management command

`scripts/dev/kaspa-exit-devnet.sh setup` prepares `build/repos/kasExitBridge`.
If `KAS_EXIT_BRIDGE_REPO_URL` is set, it clones that repo. If it is empty, it
uses the vendored KEB tooling in `tools/kasExitBridge`.

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

## Proposal Builder Config

The daemon reads:

```text
build/kaspa-exit-devnet/proposal-builder/builder.json
```

Minimal shape:

```json
{
  "network": "devnet",
  "l2ChainId": 38833,
  "igraRpcUrl": "http://execution-layer:8545",
  "l2ConfirmationBlocks": 12,
  "kaspaTxIdPrefix": "97b1",
  "contracts": {
    "kasExitBridge": "0x0000000000000000000000000000000000000000",
    "mailbox": "0x0000000000000000000000000000000000000000",
    "merkleTreeHook": "0x0000000000000000000000000000000000000000"
  },
  "bridge": {
    "address": "kaspadev:...",
    "scriptPublicKey": "...",
    "derivationPath": "m/0/0/1"
  },
  "keb": {
    "configPath": "/work/proposal-builder/keb-config.json",
    "reportsDir": "/work/proposal-builder/keb-reports",
    "runnerCwd": "/opt/kasExitBridge",
    "runnerCommand": "npm run kas-exit:run-delta --",
    "deltaBlocks": 86400,
    "previousCheckpointFile": "/work/proposal-builder/checkpoint.start.json",
    "manifestSigningPrivateKey": "/work/proposal-builder/keb_manifest_signing_priv.pem",
    "manifestSigningPublicKey": "/work/proposal-builder/keb_manifest_signing_pub.pem",
    "manifestSigningKeyId": "local-devnet-keb",
    "manifestSigningKeyType": "rsa"
  },
  "kaspa": {
    "rpcUrl": "kaspad:16610",
    "utxos": {
      "helperCommand": "kaspa-pst utxos",
      "coinbaseMaturityDaa": 1000,
      "maxInputs": 64
    }
  }
}
```

The zero contract addresses above are placeholders. A real testnet/devnet run
must use the deployed KasExitBridge, Mailbox, and MerkleTreeHook addresses plus
matching KEB expected-values/checkpoint files.

## Run The Daemon

```bash
./scripts/dev/kaspa-exit-devnet.sh proposal-builder
```

By default the service runs forever:

```text
KEB finalized window -> Foundry unsigned PST -> live Kaspa UTXOs -> safe proposal
```

For a one-shot smoke run:

```bash
KASPA_EXIT_BUILDER_MODE=once ./scripts/dev/kaspa-exit-devnet.sh proposal-builder
```

If the next KEB window is not finalized, the command skips that cycle and sleeps.
If KEB config, checkpoints, signing keys, contract values, or live spendable
Kaspa UTXOs are missing, it fails loudly instead of pretending the daemon is
healthy.
