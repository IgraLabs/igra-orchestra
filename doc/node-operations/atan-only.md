# ATAN-Only Mode

Run kaspad saving finality periods without the full IGRA execution layer stack. This is useful for archiving ATAN chain data on a dedicated machine without running the execution layer, viaduct, or any IGRA adapter components.

## Setup

1. Copy the example environment file:

    ```bash
    cp .env.atan.example .env
    ```

2. Review and adjust settings in `.env` as needed. The defaults target mainnet.
   For Galleon testnet-10, set `NETWORK=testnet-10`, `TX_ID_PREFIX=97b4`,
   `DATADIR=/app/data/kaspa-testnet-10/datadir`, and keep
   `ATAN_IMPORT_URL=https://dyehoijgeqfp8.cloudfront.net/testnet/97b4/index.pb`
   until the `/testnet-10/97b4/index.pb` CDN object is published.
   For post-KIP21 lane-based networks, keep `IGRA_LANE_ID` set to the
   canonical 4-byte lane namespace (8 lowercase hex chars, no `0x`),
   e.g. `97b10000`. The auto-import path will use `IGRA_LANE_ID` instead
   of `TX_ID_PREFIX`.

3. Start kaspad with ATAN:

    ```bash
    docker compose -f docker-compose.atan.yml up -d
    ```

4. Optionally start the ATAN uploader to push finality period data to S3:

    ```bash
    docker compose -f docker-compose.atan.yml --profile atan-uploader up -d
    ```

    This requires `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `DATADIR` to be set in `.env`.
    For mainnet, use `DATADIR=/app/data/kaspa-mainnet/datadir`.

## What It Does

- Starts kaspad with `--atan-listen` and `--atan-transaction-id-prefix` flags
- Passes `--igra-lane-id` when `IGRA_LANE_ID` is set
- Automatically imports existing ATAN data from CDN on first start
- Continuously saves new finality periods as the blockchain progresses
- Does NOT run: execution layer (reth), IGRA adapter, viaduct, RPC providers, or wallets

## Configuration

See `.env.atan.example` at the repository root for all available variables. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | Network to connect to |
| `TX_ID_PREFIX` | `97b1` | Legacy/pre-KIP21 transaction ID prefix for ATAN filtering and fallback import namespace |
| `IGRA_LANE_ID` | `97b10000` | Post-KIP21 dedicated IGRA lane namespace (4 bytes / 8 lowercase hex chars, no `0x`); passed to kaspad as `--igra-lane-id` and used as the ATAN import/upload namespace |
| `CDN_BASE_URL` | CloudFront URL | CDN for ATAN data import |
| `ATAN_IMPORT_URL` | (empty) | Optional full import URL override; required for Galleon testnet-10 until the new CDN path is published |
| `KASPAD_ADD_PEER` | (empty) | Optional peer to connect to |

## Monitoring

Check kaspad logs:

```bash
docker compose -f docker-compose.atan.yml logs -f kaspad
```

Check atan-uploader logs (if running):

```bash
docker compose -f docker-compose.atan.yml logs -f atan-uploader
```

## Verifying archives

To confirm the stored post-KIP-21 finality-period archives are valid — the recomputed `seq_commit` chain
and IGRA-lane replay match the stored values — run the offline `kaspa-atan-verify` tool (bundled in the
kaspad image) against the data volume read-only. See [ATAN Verification](atan-verification.md).
