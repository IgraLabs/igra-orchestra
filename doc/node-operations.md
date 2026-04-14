# Node Operations Guide

Operational reference for running Igra Orchestra nodes with wallet management, balance monitoring, and health check integration.

## Worker Configuration

Each orchestra node runs paired RPC provider + KasWallet worker services. The number of worker pairs is controlled by the `NUM_WORKERS` environment variable and the Docker Compose profile.

| Variable | Default | Range | Description |
|----------|---------|-------|-------------|
| `NUM_WORKERS` | `5` | `1-20` | Number of RPC/KasWallet worker pairs for the setup script |

**Profiles:** `frontend-w1` through `frontend-w20` — each profile starts that many worker pairs. All profiles are available; use the one matching your desired worker count.

```bash
# Start with 20 workers
NUM_WORKERS=20 ./scripts/setup-mainnet.sh

# Or manually with docker compose
docker compose --profile backend --profile frontend-w20 up -d
```

## Wallet Management

### Checking Wallet Balances

```bash
# Auto-detects running wallets and shows balances as JSON
./scripts/debug/wallet-status.sh

# Query specific number of wallets
./scripts/debug/wallet-status.sh 10
```

Wallets with less than 1 KAS will show a warning in the output.

### Syncing Wallet Addresses to .env

After wallets are running (requires kaspad to have completed IBD sync):

```bash
# Auto-detect and sync all running wallets
./scripts/debug/sync-wallet-addresses.sh

# Sync specific number
./scripts/debug/sync-wallet-addresses.sh 20
```

This updates `W{N}_WALLET_TO_ADDRESS` entries in `.env` by querying each running kaswallet container. Restart workers after syncing to apply.

## Wallet Balance API

Exposes wallet balances over HTTPS for remote monitoring without SSH access. Protected by Traefik BasicAuth and rate limiting.

### Setup

1. Generate BasicAuth credentials:

    ```bash
    # Install htpasswd if needed: apt install apache2-utils (Linux) or brew install httpd (macOS)
    htpasswd -nb admin YOUR_PASSWORD | sed 's/\$/\$\$/g'
    ```

2. Add to `.env` (no quotes around the value):

    ```
    WALLET_API_BASICAUTH=admin:$$apr1$$xxxx$$yyyyyyyyyyy
    ```

3. Start the wallet API service:

    ```bash
    docker compose --profile wallet-api up -d
    ```

### Testing

```bash
# Query wallet balances (replace admin:YOUR_PASSWORD with your credentials)
curl -u 'admin:YOUR_PASSWORD' https://your-domain/internal/wallets

# Pretty-print with jq
curl -s -u 'admin:YOUR_PASSWORD' https://your-domain/internal/wallets | jq .

# Check for low-balance wallets (below 1 KAS)
curl -s -u 'admin:YOUR_PASSWORD' https://your-domain/internal/wallets | jq '.wallets[] | select(.total.available_kas < 1)'

# Verify auth is required (should return 401)
curl -s -o /dev/null -w '%{http_code}' https://your-domain/internal/wallets
```

### Response Format

```json
{
  "wallets": [
    {
      "index": 0,
      "default_address": "kaspatest:qpt9pq4q...",
      "total": {
        "available_sompi": 93156363183,
        "available_kas": 931.56,
        "pending_sompi": 0,
        "pending_kas": 0
      }
    }
  ]
}
```

## Health Check Integration

The [node-health-check](https://github.com/IgraLabs/node-health-check) backend can monitor wallet balances and send Slack alerts when balances drop below a threshold. This is configured on the health check side (typically in the [rpc-load-balancer](https://github.com/IgraLabs/rpc-load-balancer) deployment).

### Configuration

Set these environment variables in the health check `.env`, matching each `RPC_URL_{i}` endpoint:

| Variable | Format | Description |
|----------|--------|-------------|
| `RPC_WALLET_AUTH_{i}` | `user:password` | BasicAuth credentials matching `WALLET_API_BASICAUTH` on the orchestra node |
| `RPC_MIN_BALANCE_KAS_{i}` | `1.0` | Minimum balance threshold in KAS (default: 1.0) |

Example (in rpc-load-balancer `.env`):

```bash
RPC_URL_0=https://stage-7.igralabs.com:8545
RPC_NAME_0=stage-7
RPC_WALLET_AUTH_0=admin:YOUR_PASSWORD
RPC_MIN_BALANCE_KAS_0=1.0
```

The health check derives the wallet API URL from the RPC endpoint's domain: `https://stage-7.igralabs.com/internal/wallets`.

Or via `config.toml`:

```toml
[[rpc_endpoints]]
node_id = "stage-7"
url = "https://stage-7.igralabs.com:8545"
wallet_api_auth = "admin:YOUR_PASSWORD"
min_balance_kas = 1.0
```

### Slack Alerts

When configured, the health check Slack messages include a wallet balance section:

```
--- Wallet Balances ---
  stage-7 - 30,885.95 KAS total, 5/20 wallets funded
  Wallet #5: 0.0000 KAS (kaspatest:qq5gmkr6...)
  Wallet #6: 0.0000 KAS (kaspatest:qrdvkqgw...)
```

## Environment Variables Reference

All operational variables across the stack:

| Variable | Where | Description |
|----------|-------|-------------|
| `NUM_WORKERS` | orchestra (shell or `.env`) | Number of RPC/KasWallet worker pairs (1-20, default: 5) |
| `W{N}_WALLET_TO_ADDRESS` | orchestra `.env` | Wallet address for worker N (set by `sync-wallet-addresses.sh`) |
| `W{N}_KASWALLET_PASSWORD` | orchestra `.env` | Wallet password for worker N |
| `WALLET_API_BASICAUTH` | orchestra `.env` | BasicAuth credentials for wallet balance API (htpasswd format, `$$`-escaped) |
| `RPC_WALLET_AUTH_{i}` | health-check `.env` | BasicAuth user:pass to query node's wallet API |
| `RPC_MIN_BALANCE_KAS_{i}` | health-check `.env` | Min wallet balance threshold in KAS (default: 1.0) |
| `SLACK_WEBHOOK_URL` | health-check `.env` | Slack webhook for alerts including low-balance warnings |
| `RPC_READ_ONLY` | orchestra `.env` | Set to `false` to enable transaction submission via RPC |
