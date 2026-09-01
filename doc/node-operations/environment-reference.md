# Environment Variables Reference

All operational variables across the stack.

## Orchestra

| Variable | Where | Description |
|----------|-------|-------------|
| `NUM_WORKERS` | shell or `.env` | Number of RPC/KasWallet worker pairs (1-20, default: 5) |
| `W{N}_WALLET_TO_ADDRESS` | `.env` | Wallet address for worker N (set by `sync-wallet-addresses.sh`) |
| `W{N}_KASWALLET_PASSWORD` | `.env` | Wallet password for worker N |
| `WALLET_API_BASICAUTH` | `.env` | BasicAuth credentials for wallet balance API (htpasswd format, `$$`-escaped) |
| `RPC_READ_ONLY` | `.env` | Transaction submission enabled by default (`false`); set to `true` for read-only RPC |

## Image Versions

Every image tag is pinned centrally in the per-network version files
(`versions.mainnet.env`, `versions.galleon-testnet.env`). Setup appends them into `.env`;
nothing hardcodes a tag in compose.

| Variable | Where | Description |
|----------|-------|-------------|
| `KASPAD_VERSION` | `versions.*.env` | Image tag for `igranetwork/kaspad`. Tracks the upstream rusty-kaspa release — see the note below |
| `RETH_VERSION` | `versions.*.env` | Image tag for `igranetwork/reth`. Tracks the upstream reth release — see the note below |
| `KASWALLET_VERSION` | `versions.*.env` | Image tag for `igranetwork/kaswallet` |
| `RPC_PROVIDER_VERSION` | `versions.*.env` | Image tag for `igranetwork/rpc-provider` |
| `NODE_HEALTH_CHECK_VERSION` | `versions.*.env` | Image tag for `igranetwork/node-health-check-client` |
| `ATAN_UPLOADER_VERSION` | `versions.*.env` | Image tag for `igranetwork/atan-uploader` |

!!! note "kaspad and reth version numbers track the upstream client"

    `KASPAD_VERSION` and `RETH_VERSION` use the `<upstream>-igra.<n>` scheme: the version
    **is** the upstream rusty-kaspa / reth release the image is built from, and `.<n>` is
    the IGRA revision on that base. IGRA no longer maintains a separate version line for
    these two — the old independent numbering (`2.3`, `3.0`) collided with upstream
    version numbers, which is why it was retired.

    Three consequences:

    - **A lower number can be newer.** `2.0.1-igra.1` supersedes the retired `3.0` line.
      Do not "correct" a pin back to `3.0`.
    - **Never shorten the tag.** Bare `2.0.1` is a different, far older image — pinning it
      is a real downgrade of several months.
    - **There is no floating minor alias.** These are semver *pre-release* versions, so
      `docker/metadata-action` publishes no `2.0` or `2.5` tag to follow. Pin the full
      string.

    This applies to **kaspad and reth only**. `kaswallet`, `rpc-provider`,
    `node-health-check-client`, and `atan-uploader` still use IGRA's own numbering. Note
    also that kaspad currently dual-publishes the same commit as both `2.0.1-igra.1` and
    `3.1.0`, so a live 3.x channel still exists on that side during the migration.

## Execution Layer

| Variable | Where | Description |
|----------|-------|-------------|
| `IGRA_RETH_PRUNE_DISTANCE_BLOCKS` | `.env` | Optional. Opt-in bounded-history (pruned) execution layer; omit or leave empty for archive mode, the default. Recommended `600000` (~7 days); minimum `10064`. Plain decimal digits only — no `_` separators, no leading zeros, no surrounding whitespace; a malformed value stops the container before it writes anything. Needs a reth image that supports the profile, first released as `2.5.1-igra.2` |
| `IGRA_RETH_ADOPT_EXISTING_VOLUME` | `.env` | Optional, `1` or unset. Opts into enabling the profile on a volume that **already holds a chain**, pruning it in place instead of forcing a resync. Consulted only when pruning is requested against a populated, unmarked data directory — inert on a fresh volume and in archive mode. Any other value is rejected |

!!! warning "No published image supports this yet"

    Both networks currently pin `RETH_VERSION=2.5.1-igra.1`, which ignores this variable and
    stays archive **silently**. Setting it today does nothing.

    Do **not** pre-set it on a running archive node in anticipation of the upgrade. It is inert
    now, but the first start on an image that does support it will find a populated volume,
    refuse it, and restart-loop — unless you have also opted into adoption.

    The devnet and dev stacks build reth from source rather than pulling a tag, so what gates
    them is the branch they build (`RETH_VERSION=devnet`, `RETH_BRANCH`), not a version number.

!!! danger "The pruning distance is fixed when the data volume is created"

    The value is stamped into the reth data volume on first start. Once stamped, changing or
    removing it is **refused** — the launcher exits and the container restart-loops. Unsetting the
    variable is not a rollback, because reth keeps pruning from its persisted `reth.toml`. Going
    back to archive means a fresh volume and a full resync.

    Turning the profile *on* for a node that already has chain data is refused by default, but
    `IGRA_RETH_ADOPT_EXISTING_VOLUME=1` opts into pruning that volume in place. Adoption is
    irreversible — the first prune pass deletes everything below the boundary — the volume must
    already be storage v2 (a v1 volume needs `reth db migrate-v2` first, and the launcher cannot
    tell them apart), and retention stays coarser than the configured distance until the volume's
    pre-existing static files age out. Snapshot first if the history matters.

    A pruned node cannot serve bodies, receipts, or existence for anything older than the
    boundary, and that limit reaches end users through its public RPC. Do not put one behind an
    endpoint that advertises full history, and do not use one as a Blockscout backend.

    To move a node off this profile, wipe the reth volume with the procedure in
    [Reth Upgrade 1.9.3 → 2.5.1](upgrade-reth-1.9-to-2.5.md#3-remove-only-the-reth-volume) — same
    wipe, same 12+ hours with the L2 RPC offline. **Never `docker compose down -v`**, on any
    network: it also destroys `kaspad_data` (the L1 chain and ATAN data) and, on production,
    `traefik_certs`. On devnet `down -v` is worse than useless — it destroys the L1 chain and does
    *not* touch the reth bind mount. Clear that by hand instead:
    `sudo rm -rf data/reth && mkdir -p data/reth` (reth writes it as root; re-creating it yourself
    stops Docker from re-making it root-owned, which would block reth from writing).

    Full operator detail ships inside the reth image at `/app/igra-README.md`. Read it without a
    running container — which is the case during a restart loop — with
    `docker run --rm --entrypoint cat igranetwork/reth:$RETH_VERSION /app/igra-README.md`.

## Health Check

| Variable | Where | Description |
|----------|-------|-------------|
| `NODE_ID` | `.env` | Unique node name reported to the monitor (`MN-…` on mainnet, `GTN-…` on Galleon testnet) |
| `HEALTH_CHECK_API_KEY` | `.env` | Push API key, shared per network |
| `NODE_HEALTH_CHECK_URL` | `.env` | Monitor host; compose builds `MONITOR_URL=http://<host>:8081` from it |
| `RPC_WALLET_AUTH_{i}` | health-check `.env` | BasicAuth user:pass to query node's wallet API |
| `RPC_MIN_BALANCE_KAS_{i}` | health-check `.env` | Min wallet balance threshold in KAS (default: 1.0) |
| `SLACK_WEBHOOK_URL` | health-check `.env` | Slack webhook for alerts including low-balance warnings |

## ATAN-Only Mode

| Variable | Where | Description |
|----------|-------|-------------|
| `NETWORK` | `.env` | Network to connect to (mainnet, testnet) |
| `TX_ID_PREFIX` | `.env` | Legacy/pre-KIP21 transaction ID prefix for ATAN filtering, and the ATAN import namespace — the network-specific CDN path segment (`{CDN_BASE_URL}/{NETWORK}/{TX_ID_PREFIX}/index.pb`) in the auto-constructed import URL. **Required everywhere.** Compose refuses to render `docker-compose.yml` and `docker-compose.atan.yml` if unset (`${TX_ID_PREFIX:?…}` guards on RPC, execution-layer, and atan-uploader env), and the kaspad entrypoints additionally hard-exit at runtime — an empty prefix would render as `--atan-transaction-id-prefix=` and silently match every transaction, degrading the post-Toccata "lane AND prefix" gate to lane-only mode. Not used for post-KIP21 transaction construction. |
| `IGRA_LANE_ID` | `.env` | Canonical post-KIP21 dedicated IGRA lane namespace, currently `97b10000` (4 bytes / 8 lowercase hex chars, no `0x`). **Required everywhere.** Compose refuses to render `docker-compose.yml` and `docker-compose.atan.yml` if unset (`${IGRA_LANE_ID:?…}` guards on RPC, execution-layer, and atan-uploader env), and the kaspad and kaswallet entrypoints additionally hard-exit at runtime, mirroring post-Toccata kaspad's own enforcement (`kaspad/src/daemon.rs:828`). Reaches kaspad as `--igra-lane-id`, kaswallet as `--subnetwork-id`, and RPC as `IGRA_LANE_ID` directly. Not used for the ATAN import URL (that uses the network-specific `TX_ID_PREFIX`). RPC, kaspad, and kaswallet must all see the same value. |
| `CDN_BASE_URL` | `.env` | CDN base URL for ATAN data import |
| `ATAN_IMPORT_URL` | `.env` | Optional override for auto-constructed import URL |
| `KASPAD_ADD_PEER` | `.env` | Optional peer address |
| `KASPAD_RETENTION_PERIOD_DAYS` | `.env` | Optional block-data retention window in days, passed to kaspad as `--retention-period-days`; omit to use kaspad's default. Applies to all kaspad modes |
| `AWS_ACCESS_KEY_ID` | `.env` | AWS credentials for atan-uploader |
| `AWS_SECRET_ACCESS_KEY` | `.env` | AWS credentials for atan-uploader |
| `DATADIR` | `.env` | Data directory path for atan-uploader |
| `S3_BUCKET` | `.env` | S3 bucket name for atan-uploader (default: atan-import) |
| `AWS_REGION` | `.env` | AWS region for atan-uploader (default: us-east-1) |
| `UPLOAD_JITTER_MAX_SECONDS` | `.env` | Max jitter seconds before upload (default: 60) |
