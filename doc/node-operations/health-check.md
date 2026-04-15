# Health Check Integration

The [node-health-check](https://github.com/IgraLabs/node-health-check) backend can monitor wallet balances and send Slack alerts when balances drop below a threshold. This is configured on the health check side (typically in the [rpc-load-balancer](https://github.com/IgraLabs/rpc-load-balancer) deployment).

## Configuration

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

## Slack Alerts

When configured, the health check Slack messages include a wallet balance section:

```
--- Wallet Balances ---
  stage-7 - 30,885.95 KAS total, 5/20 wallets funded
  Wallet #5: 0.0000 KAS (kaspatest:qq5gmkr6...)
  Wallet #6: 0.0000 KAS (kaspatest:qrdvkqgw...)
```
