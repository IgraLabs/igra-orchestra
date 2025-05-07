
# Kaspa CLI Wallet Quick Guide

## Connecting to Node
```bash
kaspa-cli
$ server 127.0.0.1:17610
$ network devnet
$ connect
```

## Wallet Management
**Create:**
```bash
$ wallet create
# Set password when prompted
# Save mnemonic phrase securely
```

**Open/Close:**
```bash
$ open
# Enter password
$ close
```

**List Wallets:**
```bash
$ wallet list
```

## Finding Address
Your address is displayed after wallet creation and when opening the wallet.


## Sending Transactions
```bash
$ send <recipient_address> <amount>
```

## Initiating L2
```bash
$ send <address> <amount> <priority_fee> <payload>
```
Example:
```bash
$ send kaspadev:qq727apeewmcfvv4rvq68xgfal3e9qn7ukqk9ujk0tragepxcnrgwcz34srr4 500 1 97b100000000000000000000000000000000000000000000000000000000000000000b
```

# Kaswallet daemon

## Generate keys

```bash
/target/release/kaswallet-create --devnet -k kaswallet-0.json
```

## Findout the address of the wallet
```bash
./target/release/kaswallet-daemon --devnet --keys path/to/keys.json --server ws://127.0.0.1:17610 --listen 0.0.0.0:8082
./target/release/test_client
# Address displayed in output
```