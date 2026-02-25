# IGRA Orchestra

A Docker Compose-based deployment environment for IGRA Orchestra components. Supports devnet, testnet, and mainnet via the `NETWORK` environment variable.

## Setup Requirements

- Docker Engine 23.0+ and Docker Compose V2+
- At least 4GB of RAM
- Git (for cloning repositories)
- Worker keys in the `./keys` directory (required for worker services)
- JWT secret in `./keys/jwt.hex` (must be created manually)

## Repository Structure

The `./scripts/dev/setup-repos.sh` script clones the necessary repositories into the `build/repos/` directory.

**Repositories:**

*   `build/repos/reth-private` - Ethereum-compatible execution layer (repo: `IgraLabs/reth-private`)
*   `build/repos/igra-rpc-provider` - RPC provider for handling API requests (repo: `IgraLabs/igra-rpc-provider`)
*   `build/repos/kaswallet` - Wallet service for relaying transactions (repo: `IgraLabs/kaswallet`)
*   `build/repos/rusty-kaspa-private` - Contains the Kaspad node (repo: `IgraLabs/rusty-kaspa-private`)

The `./scripts/dev/setup-repos.sh` script also clones the `kaspa-miner` repository (repo: `elichai/kaspa-miner`).

Ensure these repositories are present before running the Docker Compose environment. The `./scripts/dev/setup-repos.sh` script handles cloning and configuring the correct branches.

## Deployment Modes

Igra Orchestra supports two deployment modes:

### 1. Pre-built Images Mode (Recommended for Public Users)
Uses pre-built Docker images from Docker Hub for proprietary services. This mode:
- Protects intellectual property by not exposing proprietary source code
- Reduces deployment time significantly
- Only requires cloning public repositories (kaspad and kaspa-miner)

### 2. Build from Source Mode (For Developers)
Builds all services from source code. This mode:
- Requires access to all repositories (including private ones)
- Allows full customization and development
- Takes longer to deploy due to compilation

To configure the deployment mode, set `USE_PREBUILT_IMAGES` in your `.env` file:
- `USE_PREBUILT_IMAGES=true` - Use pre-built images (public deployment)
- `USE_PREBUILT_IMAGES=false` - Build from source (development)

## Quick Start

### For Public Users (Using Pre-built Images)

The fastest way to get started is using the interactive setup scripts:

```bash
# Testnet
./scripts/setup-galleon-testnet.sh

# Mainnet
./scripts/setup-galleon-mainnet.sh
```

These scripts handle environment configuration, image pulling, and service startup.

For detailed guides, see:
- [Galleon Testnet Deployment Guide](doc/quick-setup-galleon-testnet.md)
- [Galleon Mainnet Deployment Guide](doc/quick-setup-galleon-mainnet.md)

**Manual setup (alternative):**

```bash
# 1. Copy and configure environment (choose your network)
cp .env.galleon-testnet.example .env   # For testnet
# OR
cp .env.galleon-mainnet.example .env   # For mainnet
# Edit .env and set USE_PREBUILT_IMAGES=true

# 2. Setup repositories and pull images
./scripts/dev/setup-repos.sh

# 3. Create JWT secret
openssl rand -hex 32 > ./keys/jwt.hex

# 4. Start services (Docker will use the pre-built images)
docker compose --profile kaspad up -d
docker compose --profile backend up -d
```

### For Developers (Building from Source)

```bash
# 1. Copy environment file
cp .env.dev.example .env
# Keep USE_PREBUILT_IMAGES=false (default)

# 2. Setup all repositories (including proprietary)
./scripts/dev/setup-repos.sh

# 3. Create JWT secret
openssl rand -hex 32 > ./keys/jwt.hex

# 4. Setup SSH agent (required for private dependencies)
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_ed25519  # or your GitHub SSH key
ssh -T git@github.com      # verify access

# 5. Build and start services
docker compose build
docker compose --profile kaspad up -d
docker compose --profile backend up -d
# 6. Start worker services based on your needs
docker compose --profile frontend-w1 up -d  # 1 worker
# OR
docker compose --profile frontend-w2 up -d  # 2 workers
# OR
docker compose --profile frontend-w3 up -d  # 3 workers
# OR
docker compose --profile frontend-w4 up -d  # 4 workers
# OR
docker compose --profile frontend-w5 up -d  # 5 workers
```

## Initial Setup

Follow these steps before the first run:

1.  **(Optional) Create a `.env` file to override default branches:**
    Copy one of the example files and edit it. The script uses default branches if not set.
    ```bash
    cp .env.dev.example .env                    # For development (build from source)
    # OR
    cp .env.galleon-testnet.example .env        # For Galleon testnet (pre-built images)
    # OR
    cp .env.galleon-mainnet.example .env        # For Galleon mainnet (pre-built images)
    # Edit .env and add/modify lines like these:
    # RETH_BRANCH=production
    # KASWALLET_BRANCH=feature/new-api
    # IGRA_RPC_PROVIDER_BRANCH=main
    # KASPAD_BRANCH=for-wallet
    # KASPA_MINER_BRANCH=main
    ```

2.  **Clone and setup the repositories:**
    Run the setup script. It prioritizes branch names in the following order:
    1.  Environment variables passed directly to the script (e.g., `KASWALLET_BRANCH=my-branch ./scripts/dev/setup-repos.sh`).
    2.  Variables defined in the `.env` file (if it exists).
    3.  Default values hardcoded in the `./scripts/dev/setup-repos.sh` script.
    ```bash
    ./scripts/dev/setup-repos.sh
    ```

3.  **Create the JWT secret:**
    ```bash
    openssl rand -hex 32 > ./keys/jwt.hex
    ```

4.  **Create worker keys:**
    Generate the necessary key files for the wallet services. At minimum, you need `keys.kaswallet-0.json` for one worker. Additional workers require corresponding files (e.g., `keys.kaswallet-1.json`, `keys.kaswallet-2.json`).

## Docker Compose Configuration

The Docker Compose configuration uses a single docker-compose.yml file with multiple profiles for flexible deployment.

## Docker Compose Services

The Docker Compose configuration uses profiles and YAML anchors for improved maintainability. It includes the following service groups:

- **Kaspa Services** (profile: `kaspad`):
  - `kaspad` - Kaspa node

- **Kaspa Miner** (profile: `kaspa-miner`):
  - `kaspa-miner` - Kaspa mining service

- **Worker Services** (profiles: `frontend-w1`, `frontend-w2`, `frontend-w3`, `frontend-w4`, `frontend-w5`):
  - `rpc-provider-0` to `rpc-provider-4` - RPC endpoints for API requests
  - `kaswallet-0` to `kaswallet-4` - Wallet services for transaction relay

- **Core Services** (profile: `backend`):
  - `kaspad` - Kaspa node with integrated Igra adapter (L1-L2 bridge and block building)
  - `execution-layer` - Ethereum-compatible execution layer

- **Traefik** (profiles: `frontend-w1` through `frontend-w5`):
  - `traefik` - Reverse proxy and load balancer (starts with any worker profile)

- **Node Health Check** (profile: `node-health-check-client` or `backend`):
  - `node-health-check-client` - Reports node health to monitoring server

- **ATAN Uploader** (profile: `atan-uploader`):
  - `atan-uploader` - Uploads ATAN chain data to S3 and maintains index

## Configuration

This project uses a `.env` file to manage environment variables. A `.env.dev.example` file is provided with defaults.

### Logging Driver

By default, Docker logs use the `json-file` driver. You can change this by setting the `LOGGING_DRIVER` environment variable (e.g., to `syslog` on Linux).

1.  Create a `.env` file by copying the example:
    ```bash
    cp .env.dev.example .env
    ```
2.  Edit the `.env` file and change the `LOGGING_DRIVER` value:
    ```
    LOGGING_DRIVER=json-file
    ```

Docker Compose will automatically pick up this variable when you run `docker compose up`. If you don't set the variable or create a `.env` file, it will default to `json-file`.

### Image Versions

Docker image versions are centrally pinned in `versions.env`. This file is used by `docker-compose.yml`, setup scripts, and deployment tools. Update versions there when upgrading services.

## Running the Stack

The recommended way to run the IGRA Orchestra stack is:

1. **Start Kaspa Services First**
   ```bash
   docker compose --profile kaspad up -d
   # Optional: Start the miner (devnet/testnet only)
   docker compose --profile kaspa-miner up -d
   ```

2. **Start Backend (Core Services)**
   ```bash
   docker compose --profile backend up -d
   ```

3. **Start Worker Services**
   Choose the profile based on how many workers you need:
   ```bash
   # For 1 worker
   docker compose --profile frontend-w1 up -d

   # For 2 workers
   docker compose --profile frontend-w2 up -d

   # For 3 workers
   docker compose --profile frontend-w3 up -d

   # For 4 workers
   docker compose --profile frontend-w4 up -d

   # For 5 workers
   docker compose --profile frontend-w5 up -d
   ```

4. **Stopping Services**
   ```bash
   # Stop all services
   docker compose down

   # Stop specific profile
   docker compose --profile <profile-name> down
   ```

## Logs and Monitoring

### Accessing Logs

By default, container logs use the `json-file` driver (configurable via the `LOGGING_DRIVER` environment variable, see Configuration section). Logs are tagged with `igra-orchestra-${NETWORK}/{{.Name}}/{{.ID}}`.

With the default `json-file` driver, use standard `docker logs` commands. If using `syslog`, see the section below.

#### Viewing Syslog Logs (When Using syslog Driver)

1. **View all logs in real-time**:
   ```bash
   sudo journalctl -f | grep igra-orchestra
   ```

2. **View logs for a specific service**:
   ```bash
   sudo journalctl -f | grep "igra-orchestra/execution-layer"
   sudo journalctl -f | grep "igra-orchestra/rpc-provider-0"
   ```

3. **View logs from standard syslog file**:
   ```bash
   sudo tail -f /var/log/syslog | grep igra-orchestra
   ```

4. **View logs using Docker commands** (bypasses syslog):
   ```bash
   docker logs -f execution-layer
   docker logs -f rpc-provider-0
   ```

#### Viewing Logs (json-file driver or direct Docker)

The syslog tagging format allows for easy filtering by service name, making it possible to debug specific components of the stack. If using the `json-file` driver, standard `docker logs` filtering applies.

### Kaspad Configuration

Control IGRA adapter functionality in your `.env` file:

```bash
# Enable/disable IGRA adapter (default: true)
# Set to false for faster initial kaspad sync without IGRA overhead
IGRA_ENABLE=true

# Enable performance diagnostics (passes --igra-enable-perf-diagnostics flag)
ENABLE_PERF_DIAGNOSTICS=true

# Enable event logging (passes --igra-enable-event-logging flag)
ENABLE_EVENT_LOGGING=true

# Warm start from a specific block number (passes --igra-warm-start-block flag)
WARM_START_BLOCK=200184247

# Skip lock script public key verification (TESTING ONLY, default: false)
IGRA_SKIP_LOCK_SCRIPT_CHECK=false

# Transaction ID prefix for ATAN (hex-encoded, e.g., 97b1)
# Used by kaspad (--atan-transaction-id-prefix) and RPC provider
TX_ID_PREFIX=97b1

# CDN base URL for ATAN data (required)
CDN_BASE_URL=https://dyehoijgeqfp8.cloudfront.net

# ATAN auto-import URL (passes --atan-import-url flag, remote URLs only)
# Auto-constructed from CDN_BASE_URL, NETWORK and TX_ID_PREFIX by default
# Override only if you need a custom remote URL:
# ATAN_IMPORT_URL=https://custom-cdn.example.com/index.pb
```

#### Adapter Stats

Analyze kaspad adapter performance by piping logs to the adapter-stats tool:

```bash
docker logs -f -n 1000 kaspad 2>&1 | docker run --rm -i --entrypoint /app/adapter-stats igranetwork/kaspad:$(grep KASPAD_VERSION versions.env | cut -d= -f2)
```

#### Transaction Parser

When event logging is enabled, transaction logs are written to `./logs/`. Use the igra-tx-parser to watch and analyze them:

```bash
docker run --rm -v ./logs:/app/logs --entrypoint /app/igra-tx-parser igranetwork/kaspad:$(grep KASPAD_VERSION versions.env | cut -d= -f2) watch --logs-dir /app/logs
```

## Documentation

- [Galleon Testnet Deployment Guide](doc/quick-setup-galleon-testnet.md) - Public Galleon testnet deployment with pre-built images
- [Galleon Mainnet Deployment Guide](doc/quick-setup-galleon-mainnet.md) - Public Galleon mainnet deployment with pre-built images
- [Kaspa Wallet Guide](doc/kaspa-wallet.md) - Wallet setup for all networks
- [Log Management](doc/log-management.md) - Automated log cleanup for servers
- [Docker Volume Permissions](doc/troubleshooting/docker-volume-permissions.md) - Fix permission denied errors
- [SSL Certificate Issues](doc/troubleshooting/ssl-certificate.md) - Fix Traefik certificate resolver errors

## Troubleshooting

### Common Issues

1. **Container name conflicts**: Stop existing containers before starting new ones
2. **Missing worker keys**: Ensure required key files exist in the correct format
3. **Missing repositories**: Run `./scripts/dev/setup-repos.sh` to clone the required repositories
4. **Permission issues**: Check data directory permissions
5. **Profile dependencies**: Make sure to start profiles in the correct order (kaspad → backend → workers)
6. **Missing JWT file**: Ensure you've created the JWT file before starting services
7. **Service connectivity**: Ensure all services can properly connect by starting profiles in the correct order and allowing time for services to initialize
8. **SSH authentication during build**: If `docker compose build` fails with "failed to authenticate when downloading repository", ensure your SSH agent is running with your GitHub key loaded: `eval "$(ssh-agent -s)" && ssh-add ~/.ssh/id_ed25519`
