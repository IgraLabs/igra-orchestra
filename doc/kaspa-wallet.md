# Kaspa Wallet Quick Guide

## Network Selection

Choose the appropriate network flag based on your deployment:
- `--devnet` / `network devnet` - Development network (kaspadev: addresses)
- `--testnet` / `network testnet` - Test network (kaspatest: addresses)
- `--mainnet` / `network mainnet` - Production network (kaspa: addresses)

## Kaspa CLI Wallet

### Connecting to Node

Devnet:
```bash
kaspa-cli
$ server 127.0.0.1:17610
$ network devnet
$ connect
```

Testnet:
```bash
kaspa-cli
$ server 127.0.0.1:17610
$ network testnet
$ connect
```

Mainnet:
```bash
kaspa-cli
$ server 127.0.0.1:17610
$ network mainnet
$ connect
```

### Wallet Management

Create wallet:
```bash
$ wallet create
# Set password when prompted
# Save mnemonic phrase securely
```

Open/close wallet:
```bash
$ open
# Enter password
$ close
```

List wallets:
```bash
$ wallet list
```

### Finding Address

Your address is displayed after wallet creation and when opening the wallet.

Address prefixes by network:
- Devnet: `kaspadev:`
- Testnet: `kaspatest:`
- Mainnet: `kaspa:`

### Sending Transactions

Basic transaction:
```bash
$ send <recipient_address> <amount>
```

Initiating L2 transaction:
```bash
$ send <address> <amount> <priority_fee> <payload>
```

Example (devnet):
```bash
$ send kaspadev:qq727apeewmcfvv4rvq68xgfal3e9qn7ukqk9ujk0tragepxcnrgwcz34srr4 500 1 97b100000000000000000000000000000000000000000000000000000000000000000b
```

## Kaswallet Daemon

### Generate Keys

Devnet:
```bash
kaswallet-create --devnet -k keys.kaswallet-0.json
```

Testnet:
```bash
kaswallet-create --testnet -k keys.kaswallet-0.json
```

Mainnet:
```bash
kaswallet-create --mainnet -k keys.kaswallet-0.json
```

Docker (mainnet - use `--enable-mainnet-pre-launch`):
```bash
docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-0.json
```

Docker (testnet - use `--testnet`):
```bash
docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
  igranetwork/kaswallet:latest --testnet -k /keys/keys.kaswallet-0.json
```

Generate all 5 wallets (mainnet):
```bash
for i in {0..4}; do
  docker run --rm -it -v $(pwd)/keys:/keys --entrypoint /app/kaswallet-create \
    igranetwork/kaswallet:latest --enable-mainnet-pre-launch -k /keys/keys.kaswallet-$i.json
done
```

### Running the Daemon

Devnet:
```bash
kaswallet-daemon --devnet --keys path/to/keys.json --server grpc://127.0.0.1:16210 --listen 0.0.0.0:8082
```

Testnet:
```bash
kaswallet-daemon --testnet --keys path/to/keys.json --server grpc://127.0.0.1:16210 --listen 0.0.0.0:8082
```

Mainnet:
```bash
kaswallet-daemon --mainnet --keys path/to/keys.json --server grpc://127.0.0.1:16210 --listen 0.0.0.0:8082
```

### Finding Wallet Address

```bash
kaswallet-test-client
# Address displayed in output
```

