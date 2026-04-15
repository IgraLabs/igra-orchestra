# Wallet Management

## Checking Wallet Balances

```bash
# Auto-detects running wallets and shows balances as JSON
./scripts/debug/wallet-status.sh

# Query specific number of wallets
./scripts/debug/wallet-status.sh 10
```

Wallets with less than 1 KAS will show a warning in the output.

## Syncing Wallet Addresses to .env

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
