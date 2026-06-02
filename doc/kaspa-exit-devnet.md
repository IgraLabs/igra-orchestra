# Kaspa Exit Devnet

This profile boots an isolated local devnet for the Kaspa-driven Igra exit and
multisig proposal flow. It is intended for laptops and staging sandboxes, not
public testnet/mainnet nodes.

The stack contains:

- `kaspad` from `IgraLabs/rusty-kaspa-private`
- `execution-layer` from `IgraLabs/reth-private`
- `kaspa-miner` from `IgraLabs/kaspa-miner`

Safe Transaction Service, Foundry, and signer wallets run beside this stack.
The service-side Kaspa federation APIs and exit proposal-builder live on the
`safe-transaction-service` branch `kaspa-native-wallet-integration`.

## Quick Start

```bash
git checkout kaspa-exit-devnet-laptop

./scripts/dev/kaspa-exit-devnet.sh setup
./scripts/dev/kaspa-exit-devnet.sh up
./scripts/dev/kaspa-exit-devnet.sh miner

./scripts/dev/kaspa-exit-devnet.sh wait-daa 1000
./scripts/dev/kaspa-exit-devnet.sh wait-igra 1
./scripts/dev/kaspa-exit-devnet.sh status
```

For a one-command bootstrap:

```bash
./scripts/dev/kaspa-exit-devnet.sh bootstrap
```

The script creates `.env.kaspa-exit-devnet` from
`.env.kaspa-exit-devnet.example`, creates `keys/jwt.hex`, clones the configured
repositories into `build/repos/`, builds the images, and starts only this
compose project.

Use `ORCHESTRA_ENV_FILE=/path/to/env` if you want multiple local devnets.

## Devnet Parameters

The preset uses the profile that survived the full staging exit e2e:

```text
NETWORK=devnet
TX_ID_PREFIX=97b1
IGRA_CHAIN_ID=38833
KASPAD_EXTRA_ARGS="--enable-unsynced-mining --devnet-finality-depth=5000 --devnet-pruning-depth=30125"
ATAN_IMPORT_REQUIRED=false
```

Do not shrink this profile casually. Earlier staging attempts failed with DAA
window retention errors:

- `finality=300`, `pruning=3150` failed around DAA 5554.
- `finality=700`, `pruning=10000` failed around DAA 12816.

`30125 % 5000 = 125`, satisfying rusty-kaspa's devnet override rule while
retaining enough DAA window data.

## Expected Timing

Kaspa drives Igra block production. The execution layer does not accept normal
EL txpool writes for Igra protocol transactions in this flow; Igra L2 payloads
are embedded in Kaspa transaction payloads and then observed by the EL after
kaspad/ATAN/Viaduct process them.

Operationally:

- Wait for Kaspa virtual DAA `>= 1000` before spending mined coinbase rewards.
- With `finality=5000`, expect `eth_blockNumber` to stay at `0x0` until roughly
  DAA `10000`.
- Use `wait-igra 1` before deploying the exit contracts or submitting
  `requestExit`.

## Local Ports and Isolation

Defaults from `.env.kaspa-exit-devnet`:

```text
Compose project: igra-kaspa-exit-devnet
Docker subnet:   172.31.93.0/24
Kaspa gRPC:      127.0.0.1:16610
Kaspa JSON RPC:  127.0.0.1:18610
Igra EL HTTP:    127.0.0.1:9545
Igra EL WS:      127.0.0.1:9546
```

If a port or subnet conflicts with another local stack, edit only the
`KASPA_EXIT_DEVNET_*`, `KASPAD_*_PORT`, and `EL_*_HOST_PORT` values in the env
file.

## Funding for Multisig Tests

The default `MINING_ADDRESS` is only a devnet mining sink so the chain advances
out of the box. For a full custody funding test, set `MINING_ADDRESS` to the
generated multisig custody or faucet address before starting the miner:

```bash
# edit .env.kaspa-exit-devnet
MINING_ADDRESS=kaspadev:...

./scripts/dev/kaspa-exit-devnet.sh miner
./scripts/dev/kaspa-exit-devnet.sh wait-daa 1000
```

After 1000 DAA, those coinbase UTXOs are mature and can fund the unsigned Kaspa
PST proposal.

## Exit Contracts and Safe Service

Use the Safe Transaction Service branch:

```bash
git clone git@github.com:IgraLabs/safe-transaction-service.git
cd safe-transaction-service
git checkout kaspa-native-wallet-integration
```

For Igra writes through Foundry, use the Igra transport environment:

```bash
export FOUNDRY_IGRA_ENABLED=true
export FOUNDRY_IGRA_EL_RPC_URL=http://127.0.0.1:9545
export FOUNDRY_IGRA_KASPA_RPC_URL=grpc://127.0.0.1:16610
export FOUNDRY_IGRA_EXPECTED_EL_CHAIN_ID=38833
export FOUNDRY_IGRA_KASPA_NETWORK=devnet
export FOUNDRY_IGRA_TX_ID_PREFIX=97b1
export FOUNDRY_IGRA_EL_RECEIPT_TIMEOUT_SECS=900
export FOUNDRY_IGRA_MINING_TIMEOUT_SECS=300
```

The staging helper in safe-service deploys the same production
`Mailbox`, `MerkleTreeHook`, and `KasExitBridge` bytecode fetched from the Igra
block explorer:

```bash
python scripts/submit_igra_exit_contracts_async.py \
  --rpc-url http://127.0.0.1:9545 \
  --artifact-dir /tmp/igra-exit-contracts \
  --out /tmp/igra-exit-contracts/deployment.json \
  --chain-id 38833
```

After the contracts exist, the full e2e sequence is:

```text
1. Create the Kaspa federation in Safe Transaction Service.
2. Generate three signer wallets and the canonical custody address.
3. Mine or transfer mature devnet funds to custody.
4. Submit requestExit on Igra through Foundry's Kaspa payload transport.
5. Build the exit evidence bundle for the finalized Igra window.
6. Run build_kaspa_exit_proposal against that bundle and federation.
7. Each signer independently re-verifies the proposal locally.
8. Sign locally from signer wallets; submit signed PST bundles to safe-service.
9. Broadcast once quorum is reached.
10. Verify recipient and custody change on Kaspa devnet.
```

Signer private keys stay in the wallets. The proposal-builder only knows public
kpubs, the threshold, bridge addresses, verified L2 exit evidence, selected
Kaspa UTXOs, and the unsigned PST.

## Signer Re-Verification

Signers must not trust the proposal-builder or Safe Transaction Service. Before
signing, each signer downloads the proposal plus exit evidence, verifies it
against their own Igra and Kaspa RPC endpoints, rebuilds the expected unsigned
PST from public material, and compares the exact unsigned transaction bytes.

The local signer check should reject on any mismatch in:

- Igra chain ID.
- KasExitBridge, Mailbox, and MerkleTreeHook addresses.
- Contract code hash or deployment manifest for the configured devnet.
- Kaspa network, txid prefix, custody address, kpub set, threshold, ECDSA flag,
  and canonical derivation path.
- Exit window `fromBlock..toBlock`, checkpoint continuity, and finality margin.
- Every decoded exit event: emitting contract, receipt success, topics, message
  id, request id, recipient Kaspa address, and amount.
- Merkle tree replay from the previous checkpoint to the end checkpoint.
- Selected Kaspa funding UTXOs, including live unspent state, amount, script
  public key, and coinbase maturity.
- PST inputs, outputs, change, fee, payload message IDs, payload nonce, mass,
  and unsigned txid.

The signer-side algorithm is:

```text
1. Fetch the proposal and /api/v1/kaspa/exit-batches/{id}/evidence/.
2. Check that evidenceHash matches the downloaded evidence artifacts.
3. Query local Igra RPC for chain ID, finalized/latest block, contract code,
   logs, transactions, and receipts for the proposal window.
4. Re-run the KEB exit/tree verification against those local RPC results.
5. Query local Kaspa RPC for every selected custody UTXO.
6. Re-derive the bridge multisig address from the configured public kpubs.
7. Rebuild the unsigned exit PST from verified exits and verified UTXOs.
8. Compare rebuilt unsigned PST bytes and proposal hash with safe-service.
9. Sign only if all comparisons are exact.
```

This is the same security model as offline transaction review: the service may
coordinate signatures, but the signer only signs a transaction it can reproduce
from independent public data.

## Useful Commands

```bash
./scripts/dev/kaspa-exit-devnet.sh status
./scripts/dev/kaspa-exit-devnet.sh logs kaspad
./scripts/dev/kaspa-exit-devnet.sh logs execution-layer
./scripts/dev/kaspa-exit-devnet.sh config
./scripts/dev/kaspa-exit-devnet.sh down
```

`down` stops this compose project. Add `-v` only when you intentionally want to
delete the local Kaspa and EL data volumes:

```bash
./scripts/dev/kaspa-exit-devnet.sh down -v
```
