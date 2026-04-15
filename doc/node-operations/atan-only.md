# ATAN-Only Mode

Run kaspad saving finality periods without the full IGRA execution layer stack. This is useful for archiving ATAN chain data on a dedicated machine without running the execution layer, viaduct, or any IGRA adapter components.

## Setup

1. Copy the example environment file:

    ```bash
    cp .env.atan.example .env
    ```

2. Review and adjust settings in `.env` as needed. The defaults target mainnet.

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
- Automatically imports existing ATAN data from CDN on first start
- Continuously saves new finality periods as the blockchain progresses
- Does NOT run: execution layer (reth), IGRA adapter, viaduct, RPC providers, or wallets

## Configuration

See [`.env.atan.example`](../../.env.atan.example) for all available variables. Key settings:

| Variable | Default | Description |
|----------|---------|-------------|
| `NETWORK` | `mainnet` | Network to connect to |
| `TX_ID_PREFIX` | `97b1` | Transaction ID prefix for ATAN filtering |
| `CDN_BASE_URL` | CloudFront URL | CDN for ATAN data import |
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
