# IGRA Orchestra Devnet Setup Guide

## Initial Setup

1. Install prerequisites:
   - Docker Engine 23.0+ and Docker Compose V2+
   - Git
   - Ensure at least 4GB RAM available

2. Create a `.env` file to configure the environment:
   ```bash
   # Copy the example configuration file
   cp .env.example .env

   # Edit the .env file to adjust settings as needed
   ```

3. Key settings in the `.env` file:
   ```
   # Docker configuration
   LOGGING_DRIVER=json-file  # Use json-file on macOS, syslog on Linux

   # Log levels
   RUST_LOG=debug
   LOG_LEVEL=debug

   # Kaspad configuration
   KASPAD_HOST=kaspad
   KASPAD_BORSH_PORT=17610

   # Viaduct settings
   REPLAY_ON_ERROR=-1
   SYNC_THREADS=64
   MAGIC_SPK=20587b999b5b38f5c87ce04e4a2100998a05d303cc54c30ec77fa2c51dc5aa0a53ac
   IGRA_LAUNCH_DAA_SCORE=26927000

   # Mining configuration
   MINING_ADDRESS=kaspadev:your_generated_address
   MINING_THREADS=1

   # RPC access tokens (must be 32 hex characters)
   RPC_ACCESS_TOKEN_1=token_1
   # ...more tokens...

   # Worker configurations
   W0_WALLET_TO_ADDRESS=kaspadev:worker0_address
   W0_KASWALLET_PASSWORD=worker0_password

   # Additional workers...
   W1_WALLET_TO_ADDRESS=kaspadev:worker1_address
   W1_KASWALLET_PASSWORD=worker1_password
   ```

4. Clone and configure repositories:
   ```bash
   ./setup-repos.sh
   ```

5. Create JWT secret:
   ```bash
   openssl rand -hex 32 > ./keys/jwt.hex
   ```

## Worker Key Generation

Generate keys for kaswallet workers:

```bash
/target/release/kaswallet-create --devnet -k keys/kaswallet-0.json
/target/release/kaswallet-create --devnet -k keys/kaswallet-1.json
/target/release/kaswallet-create --devnet -k keys/kaswallet-2.json
```

## Starting Services

1. Start Kaspa services:
   ```bash
   docker compose --profile kaspad up -d
   ```

2. Generate a Kaspa wallet address using Kaspa CLI:
   ```bash
   kaspa-cli
   $ server 127.0.0.1:17610
   $ network devnet
   $ connect
   $ wallet create
   # Set password when prompted
   # Save mnemonic phrase securely
   # Note down the generated address
   ```

3. Update the mining address in your `.env` file:
   ```bash
   # Edit the .env file and set your generated address
   MINING_ADDRESS=kaspa:your_generated_address
   ```

4. Start mining to accumulate KAS before launching core services:
   ```bash
   docker compose --profile kaspa-miner up -d
   ```

5. Start Explorer to monitor mining progress:
   ```bash
   docker compose --profile kaspa-explorer up -d
   ```

6. Let the miner run for a while to accumulate sufficient KAS (check the explorer at http://localhost:8080)

## Starting Core Services

After mining and distributing KAS, start IGRA worker services:

```bash
# Choose one based on how many workers you need
docker compose --profile igra-w1 up -d  # 1 worker
# OR
docker compose --profile igra-w2 up -d  # 2 workers
# OR
docker compose --profile igra-w3 up -d  # 3 workers
```

## Monitoring

1. View service logs:
   ```bash
   docker logs -f execution-layer
   docker logs -f rpc-provider-0
   docker logs -f kaswallet-0
   ```

2. Access Kaspa Explorer at http://localhost:8008

3. Monitor system health via Traefik dashboard (http://localhost:8080/dashboard/)
