# RPC Setup & Entry Transactions Guide

## Prerequisites
- Kaspad and backend services already running
- Docker & Docker Compose installed

## Initial Setup

### Configure Environment
```bash
cp .env.backend-with-rpc.example .env
# Edit .env to set your configuration
```

## Wallet Setup

### 1. Generate Wallet Key
```bash
docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --testnet -k /keys/keys.kaswallet-0.json
```
When prompted for password, press Enter for empty password or set your own.
**IMPORTANT: Save the mnemonic phrase displayed!**

### 2. Get Wallet Address

**Terminal 1:** Start wallet daemon (leave running)
```bash
docker run --rm -v $(pwd)/keys:/keys --network igra-orchestra-testnet_igra-network \
  -p 8082:8082 --name kaswallet-temp igranetwork/kaswallet:latest \
  --testnet --keys /keys/keys.kaswallet-0.json \
  --server ws://kaspad:17210 --listen 0.0.0.0:8082
```

Expected output:
```
2025-08-20T15:57:15 [INFO] Connected to kaspa node successfully
2025-08-20T15:57:15 [INFO] Starting wallet server on 0.0.0.0:8082
2025-08-20T15:57:17 [INFO] Finished initial sync
```

**Terminal 2:** Get wallet address
```bash
docker run --rm --network host --entrypoint /app/test_client \
  igranetwork/kaswallet:latest
```

Output:
```
New Address="kaspatest:qqfrt9vlrpl98m8gwsrw45ynvpgxcrl87x3h2337k8ft4eyhacyqumc0t9vng"
Balance: Available=0, Pending=0
```

Stop wallet daemon in Terminal 1 with Ctrl+C. Verify stopped: `docker ps`

### 3. Configure .env
```bash
W0_WALLET_TO_ADDRESS=kaspatest:[your-address-from-step-2]
W0_KASWALLET_PASSWORD=[your-password-from-step-1]
```

### 4. Fund Your Wallet (Optional)
**Only required if submitting transactions or entry transactions:**
- Send KAS to the address from step 2
- Required for: transaction fees, entry transaction deposits
- If only reading blockchain data, set `RPC_READ_ONLY=true` in `.env` and skip funding

## RPC Provider Setup

### Start Services
```bash
# Single worker (rpc-provider-0 + kaswallet-0)
docker compose --profile frontend-w1 up -d --pull always
```

### Verify Services
```bash
docker compose ps
# Should show: rpc-provider-0, kaswallet-0 (plus more if multiple workers)
```

## RPC Access

### Configuration
In `.env`, configure:
- `RPC_ACCESS_TOKEN_1` to `RPC_ACCESS_TOKEN_46` - **Must all be set**, otherwise RPC works without authentication
- `RPC_READ_ONLY=true` - Set to `true` for read-only access (no wallet/funding needed), `false` to allow transactions

For HTTPS (requires domain):
- `IGRA_ORCHESTRA_DOMAIN` - Your domain
- `IGRA_ORCHESTRA_DOMAIN_EMAIL` - Your email for SSL certificates

**Without HTTPS:** Comment out these lines in `docker-compose.yml` under traefik:
```yaml
# - "--certificatesresolvers.myresolver.acme.email=${IGRA_ORCHESTRA_DOMAIN_EMAIL}"
# - "--certificatesresolvers.myresolver.acme.storage=/letsencrypt/acme.json"
# - "--certificatesresolvers.myresolver.acme.httpchallenge.entrypoint=web"
```

### Endpoint Format
```
# With HTTPS:
https://{DOMAIN}/{ACCESS_TOKEN}

# Without HTTPS:
http://{HOST_IP}:8545/{ACCESS_TOKEN}
```

### Test RPC
```bash
curl -X POST https://your-domain.com/{your_access_token} \
  -H "Content-Type: application/json" \
  -d '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'
```

## Entry Transactions

Entry transactions bridge KAS from L1 (Kaspa) to L2 (Igra) and use Worker 0's wallet balance.

**Prerequisites:**
- Worker 0 wallet must have sufficient KAS balance
- Funds needed for: transaction amount + mining fees

### Quick Send
```bash
# Uses Worker 0 wallet balance (ensure it has sufficient KAS)
# WALLET_TO_ADDRESS must match W0_WALLET_TO_ADDRESS from .env for change to return correctly
export WALLET_TO_ADDRESS='kaspatest:[your-wallet-0-address]'  # Same as W0_WALLET_TO_ADDRESS
export WALLET_DAEMON_URI='http://kaswallet-0:8082'  # Points to kaswallet-0 container
export KASWALLET_PASSWORD=''  # Your password from kaswallet-0

# Send entry transaction
docker run --rm \
  -e WALLET_TO_ADDRESS \
  -e WALLET_DAEMON_URI \
  -e KASWALLET_PASSWORD \
  --network host \
  --entrypoint /app/entry_transaction_sender \
  igranetwork/rpc-provider:latest \
  --recipient kaspatest:qprjv0e4a2l2t56870d6jwkvf9dnjnynhzr0a3kf4spndpz9f6hmxy0ux9yte \
  --amount 1.5 \
  --l2-address 0x5E1DC98169b3F5D055A18cb359B60F0B576Ab335
```

### Parameters
- `--recipient`: Kaspa L1 locking address (do not change it, otherwise you will not receive the funds)
- `--amount`: KAS amount (e.g., 1.5, 0.00000001)
- `--l2-address`: Ethereum L2 address for iKAS deposit where you want to receive the funds.

### Success Output
```
 Entry transaction sent successfully!
   Transaction ID: 97b1a2b3c4d5...
   Recipient: kaspa:qpam...
   Amount: 1.50000000 KAS (150000000 SOMPI)
   L2 Address: 0x742d35Cc...
```

## Monitoring
```bash
# View logs
docker logs -f rpc-provider-0
docker logs -f kaswallet-0

# Check service health
docker compose ps
```

## Multiple Workers

For additional workers (up to 5):
1. Generate keys for each worker: `keys.kaswallet-1.json`, `keys.kaswallet-2.json`, etc.
2. Get address for each wallet using the same process
3. Add to `.env`: `W1_WALLET_TO_ADDRESS`, `W2_WALLET_TO_ADDRESS`, etc.
4. **Fund each worker wallet** with KAS for transaction fees
5. Start with appropriate profile: `docker compose --profile frontend-w3 up -d` (for 3 workers)

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Wallet connection failed | Ensure kaswallet-0 is running: `docker compose ps` |
| Invalid amount | Use decimal format: 1.5, 0.00000001 |
| Missing wallet keys | Generate keys as shown in Wallet Setup |
| RPC timeout | Verify all services healthy |
| Transaction fails | Check wallet has sufficient KAS balance |
| "Insufficient funds" error | Top up worker wallet with KAS tokens |