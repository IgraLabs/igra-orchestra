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

## Health Check

| Variable | Where | Description |
|----------|-------|-------------|
| `RPC_WALLET_AUTH_{i}` | health-check `.env` | BasicAuth user:pass to query node's wallet API |
| `RPC_MIN_BALANCE_KAS_{i}` | health-check `.env` | Min wallet balance threshold in KAS (default: 1.0) |
| `SLACK_WEBHOOK_URL` | health-check `.env` | Slack webhook for alerts including low-balance warnings |

## ATAN-Only Mode

| Variable | Where | Description |
|----------|-------|-------------|
| `NETWORK` | `.env` | Network to connect to (mainnet, testnet) |
| `TX_ID_PREFIX` | `.env` | Transaction ID prefix for ATAN filtering |
| `CDN_BASE_URL` | `.env` | CDN base URL for ATAN data import |
| `ATAN_IMPORT_URL` | `.env` | Optional override for auto-constructed import URL |
| `KASPAD_ADD_PEER` | `.env` | Optional peer address |
| `AWS_ACCESS_KEY_ID` | `.env` | AWS credentials for atan-uploader |
| `AWS_SECRET_ACCESS_KEY` | `.env` | AWS credentials for atan-uploader |
| `DATADIR` | `.env` | Data directory path for atan-uploader |
| `S3_BUCKET` | `.env` | S3 bucket name for atan-uploader (default: atan-import) |
| `AWS_REGION` | `.env` | AWS region for atan-uploader (default: us-east-1) |
| `UPLOAD_JITTER_MAX_SECONDS` | `.env` | Max jitter seconds before upload (default: 60) |
