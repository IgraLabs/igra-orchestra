# KasExitBridge Query And Audit Methodology (AI-Agent)

## Scope

This document defines a reproducible, machine-checkable methodology for querying
`KasExitBridge` exit activity and collecting Merkle tree evidence required to
verify inclusion of exit-related messages in `MerkleTreeHook` roots.

Target contracts on Igra mainnet:

- `KasExitBridge`: `0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0`
- `Mailbox`: `0x3a867fCfFeC2B790970eeBDC9023E75B0a172aa7`
- `MerkleTreeHook`: `0x75719C858e0c73e07128F95B2C466d142490e933`
- `chainId`: `38833`

## Data Collection

1. Resolve numeric `startBlock` and `endBlock` (`latest`, `latest - N`, numeric).
2. Enumerate successful `requestExit` executions from
   `KasExitBridge.ExitRequested` events (event-first discovery).
3. Optionally enumerate top-level external `requestExit` attempts by block scan:
   - `tx.to == KasExitBridge`
   - calldata selector `requestExit(string,uint64)`
4. Build candidate tx set as union of:
   - txs with `ExitRequested` events
   - optional external top-level `requestExit` attempts
5. For each candidate tx, fetch:
   - full transaction
   - receipt
   - relevant logs
6. Independently collect all `MerkleTreeHook.InsertedIntoTree` events in range
   from the hook contract address.
7. Query Merkle tree checkpoints:
   - start checkpoint at block `startBlock - 1`: `root()`, `count()`
   - end checkpoint at block `endBlock`: `root()`, `count()`
   - if hook code is not deployed at a checkpoint block, use zero-state fallback:
     - `root = 0x0000000000000000000000000000000000000000000000000000000000000000`
     - `count = 0`
8. Query and record hook mailbox:
   - `MerkleTreeHook.mailbox()`
9. If expected roots are provided via CLI (`--expected-root-start`,
   `--expected-root-end`), fail immediately when mismatch is detected.
10. Validate methodology checksum:
   - compute SHA-256 of methodology file
   - fail immediately if it does not match `--expected-methodology-sha256`
     (defaults to pinned checksum shipped in script)
11. Optional root replay verification (`--verify-root-consistency`):
   - require `--tree-snapshot-file`
   - default replay input is the in-run tree dataset already collected by script
   - optional `--tree-data-file` can override replay input source
   - replay never re-queries inserted leaves from RPC
   - validate snapshot coherence:
     - recompute snapshot root from snapshot `branch + count`
     - require recomputed root equals snapshot `root`
     - require snapshot `{blockNum,count,root}` equals tree-data start checkpoint
   - replay inserts using Hyperlane Merkle semantics and compare computed end root
     with tree-data end checkpoint root

## External vs Internal Calls

- External call: top-level tx has `to == KasExitBridge`.
- Internal call: another contract calls `KasExitBridge` inside the transaction;
  top-level `tx.to != KasExitBridge`.

Successful internal calls are detected via `ExitRequested` events.

## Events Under Audit

Per `requestExit` transaction, collect:

- `KasExitBridge.BurnIKas(uint256)`
- `KasExitBridge.ExitRequested(uint32,bytes32,uint64)`
- `Mailbox.Dispatch(address,uint32,bytes32,bytes)` with `sender=KasExitBridge`
- `Mailbox.DispatchId(bytes32)`
- `InsertedIntoTree(bytes32,uint32)` from tx receipt for exit correlation

For Merkle tree data collection, collect all:

- `MerkleTreeHook.InsertedIntoTree(bytes32,uint32)` emitted by hook address

## Message Decoding

Decode `Dispatch.message` as:

Outer envelope (77 bytes):

- version: 1 byte
- nonce: 4-byte big-endian
- originDomain: 4-byte big-endian
- sender: 32-byte field (last 20 bytes are EVM address)
- destinationDomain: 4-byte big-endian
- recipient: 32 bytes

Body (starts at offset 77):

- format: 1 byte (`0x11`)
- requestId: 4-byte big-endian
- unlockAmountSompi: 8-byte big-endian
- originBurner: 20 bytes
- kasPayoutAddressLength: 1 byte
- kasPayoutAddress: UTF-8 bytes of specified length

## Checks

### Per-transaction checks

For successful `requestExit` tx:

- exactly one event of each audited type
- `messageId == keccak256(Dispatch.message)`
- same `messageId` across `ExitRequested`, `DispatchId`, `Dispatch`,
  `InsertedIntoTree`
- `Dispatch.message` must decode successfully
- decoded body `requestId` matches `ExitRequested.requestId`
- decoded body `unlockAmountSompi` strictly equals input
  `requestExit.unlockAmountSompi`
- decoded body `kasPayoutAddress` strictly equals input
  `requestExit.kasPayoutAddress`
- tx `msg.value == BurnIKas.amount`

For reverted `requestExit` tx:

- zero events of all audited types

### Global checks

- number of successful `requestExit` tx equals:
  - count of `BurnIKas` events from `KasExitBridge`
  - count of `ExitRequested` events from `KasExitBridge`

### MerkleTreeHook checks

- `MerkleTreeHook.mailbox()` must equal configured mailbox address.
- `count(endBlock) - count(startBlock - 1)` must equal number of hook
  `InsertedIntoTree` events in range.
- no duplicate `messageId` among hook `InsertedIntoTree` events.
- no duplicate `index` among hook `InsertedIntoTree` events.
- no gaps in hook leaf indices in range:
  - sorted indices must be contiguous from `count(startBlock - 1)` to
    `count(endBlock) - 1`.
- every successful exit transaction's `(txHash, messageId, index)` from exit
  correlation must be present in hook-level event dataset.
- if replay mode is enabled:
  - replayed end root from snapshot and tree-data leaves must equal end checkpoint root.

### Root Replay Semantics (Hyperlane-locked)

- `TREE_DEPTH = 32`
- tree state is `branch[32] + count`
- insert and root computations follow Hyperlane `MerkleLib` exactly:
  - `insert(Tree storage _tree, bytes32 _node)`
  - `rootWithCtx(Tree storage _tree, bytes32[32] memory _zeroes)`
- leaf inserted is `message.id()`, where:
  - `message.id() = keccak256(message bytes)`
- hashing order uses `keccak256(abi.encodePacked(left, right))`
- zero hashes are the Hyperlane constants `Z_0..Z_31`

### Snapshot File Schema

Replay mode expects a JSON snapshot with the following shape (branch abbreviated):

```json
{
  "version": 1,
  "treeDepth": 32,
  "blockNum": 0,
  "count": "0",
  "root": "0x0000000000000000000000000000000000000000000000000000000000000000",
  "branch": [
    "0x0000000000000000000000000000000000000000000000000000000000000000",
    "... 31 more bytes32 entries ..."
  ]
}
```

Validation rules:

- `branch` length must be exactly `32` (`treeDepth`).
- all `branch` entries and `root` must be `bytes32`.
- `count` must be a non-negative integer string.
- if present, `treeDepth` must equal `32`.
- `blockNum` must match tree-data start checkpoint block.

## Trace Requirement For Internal Input Verification

For internal successful calls, tx input cannot be used to decode
`requestExit(kasPayoutAddress, unlockAmountSompi)`.
Input verification must use call traces (`debug_traceTransaction`) and decode the
inner call frame to `KasExitBridge.requestExit`.

If trace APIs are unavailable:

- successful internal calls are still discoverable from events
- strict input-param matching for those internal calls is not fully verifiable and
  must be reported as an explicit limitation

Internal reverted calls with no emitted events require block/tx tracing to be
enumerated exhaustively.

## Output Model

Four files are generated:

1. exit data file:
   - top-level fields:
     - `metadata`
     - `exits`
   - `metadata` includes all run-level fields:
     - `common` section:
       - timestamps (`startedAt`, `endedAt`, `generatedAt`)
       - runtime context (`rpcUrl`, `chainId`, `fromBlock`, `toBlock`)
       - methodology provenance:
         - `methodology.path`
         - `methodology.expectedSha256`
         - `methodology.sha256`
       - cross-file links:
         - `links.exitDataFile`
         - `links.treeDataFile`
         - `links.checksFile`
     - exit context (`kasExitBridge`, `mailbox`)
     - aggregates (`totals`)
   - `exits` contains per-transaction factual fields and decoded
     `dispatchMessage` outer/body fields
2. checks file:
   - top-level fields:
     - `metadata`
     - `globalErrors`
     - `exits`
   - `metadata` includes all run-level fields:
     - `common` section with timestamps, runtime context, methodology checksum, links
     - `exit` section with exit totals and exit check-failure counters
     - `tree` section with tree checkpoints, totals, tree check-failure counters,
       and `rootReplay` result block
   - `globalErrors` is split into:
     - `globalErrors.exit`
     - `globalErrors.tree`
   - `exits` keeps per-transaction check booleans, event counts, and errors
3. tree data file:
   - top-level fields:
     - `metadata`
     - `events`
   - `metadata` includes:
     - `common` section with timestamps, runtime context, methodology checksum, links
     - hook context (`merkleTreeHook`, hook `mailbox`)
     - optional expected roots provided by caller
     - start/end checkpoints (`root`, `count`, `blockTag`)
     - total number of hook `InsertedIntoTree` events
   - `events` includes one record per hook insert:
     - `txHash`, `blockNum`, `messageId`, `index`
4. tree snapshot file:
   - top-level fields:
     - `version`
     - `treeDepth`
     - `blockNum`
     - `count`
     - `root`
     - `branch`
   - this file is directly reusable as `--tree-snapshot-file` for a subsequent incremental run.

## Reproducibility Notes

- Use a fixed numeric block range for deterministic reruns.
- Keep RPC endpoint explicit in metadata.
- Avoid inferred values when direct on-chain fields are available.
