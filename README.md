# IGRA Orchestra Devnet

A Docker Compose-based development environment for IGRA Orchestra components.

## Setup Requirements

- Docker Engine 23.0+ and Docker Compose V2+
- At least 4GB of RAM
- Git (for cloning repositories)
- Worker keys in the `./keys` directory (required for worker services)
- JWT secret in `./keys/jwt.hex` (must be created manually)

## Repository Structure

The `setup-repos.sh` script clones the necessary repositories into the `build/repos/` directory.

**Repositories:**

*   `build/repos/execution-layer` - Ethereum-compatible execution layer (repo: `IgraLabs/execution-layer`)
*   `build/repos/block-builder` - Block builder service (repo: `IgraLabs/block-builder`)
*   `build/repos/viaduct` - Contains the Viaduct component (repo: `IgraLabs/viaduct`)
*   `build/repos/igra-rpc-provider` - RPC provider for handling API requests (repo: `IgraLabs/igra-rpc-provider`)
*   `build/repos/kaswallet` - Wallet service for relaying transactions (repo: `IgraLabs/kaswallet`)

**Additional Development Repositories (cloned when using `./setup-repos.sh --dev`):**

*   `build/repos/rusty-kaspa` - Contains the Kaspad node (repo: `IgraLabs/rusty-kaspa`)
*   `build/repos/kaspa-miner` - Kaspa mining service (repo: `elichai/kaspa-miner`)

Ensure these repositories are present before running the Docker Compose environment. The `setup-repos.sh` script handles cloning and configuring the correct branches.

## Quick Start

The environment uses Docker Compose profiles for flexible deployment:

```bash
# 1. Setup the repositories
./setup-repos.sh

# 2. Create JWT secret
openssl rand -hex 32 > ./keys/jwt.hex

# 3. Start Kaspa services first
docker compose --profile kaspad up -d

# 4. Start the Explorer (optional)
docker compose --profile kaspa-explorer up -d

# 5. Start worker services based on your needs
docker compose --profile igra-w1 up -d  # 1 worker
# OR
docker compose --profile igra-w2 up -d  # 2 workers
# OR
docker compose --profile igra-w3 up -d  # 3 workers
```

## Initial Setup

Follow these steps before the first run:

1.  **(Optional) Create a `.env` file to override default branches:**
    Copy the example file and edit it to set your desired `_BRANCH` variables. The script uses default branches if these are not set.
    ```bash
    cp .env.example .env
    # Edit .env and add/modify lines like these:
    # BLOCK_BUILDER_BRANCH=develop
    # EXECUTION_LAYER_BRANCH=main
    # KASWALLET_BRANCH=feature/new-api
    # IGRA_RPC_PROVIDER_BRANCH=main
    # VIADUCT_BRANCH=main
    # KASPAD_BRANCH=for-wallet # Used only if --dev flag is set
    # KASPA_MINER_BRANCH=main  # Used only if --dev flag is set
    ```

2.  **Clone and setup the repositories:**
    Run the setup script. It prioritizes branch names in the following order:
    1.  Environment variables passed directly to the script (e.g., `KASWALLET_BRANCH=my-branch ./setup-repos.sh`).
    2.  Variables defined in the `.env` file (if it exists).
    3.  Default values hardcoded in the `setup-repos.sh` script.
    ```bash
    ./setup-repos.sh
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
  - `kaspa-miner` - Kaspa mining service

- **Explorer Services** (profile: `kaspa-explorer`):
  - `kaspa_explorer` - Explorer frontend
  - `simply_kaspa_socket_server` - WebSocket server for explorer
  - `kaspa_rest_server` - REST API server
  - `simply_kaspa_indexer` - Blockchain indexer
  - `kaspa_db` - PostgreSQL database for explorer data

- **Worker Services** (profiles: `igra-w1`, `igra-w2`, `igra-w3`, `igra-w4`, `igra-w5`):
  - `rpc-provider-0` to `rpc-provider-4` - RPC endpoints for API requests
  - `kaswallet-0` to `kaswallet-4` - Wallet services for transaction relay

- **Core Services** (included in worker profiles):
  - `execution-layer` - Ethereum-compatible execution layer
  - `block-builder` - Block creation and publishing
  - `viaduct` - L1-L2 communication bridge
  - `traefik` - Reverse proxy and load balancer

## Configuration

This project uses a `.env` file to manage environment variables. A `.env.example` file is provided with defaults.

### Logging Driver

By default, Docker logs are sent to `syslog`. On **macOS**, the `syslog` driver might not be available or may cause issues. You can switch to the `json-file` driver by setting the `LOGGING_DRIVER` environment variable.

1.  Create a `.env` file by copying the example:
    ```bash
    cp .env.example .env
    ```
2.  Edit the `.env` file and change the `LOGGING_DRIVER` value:
    ```
    LOGGING_DRIVER=json-file
    ```

Docker Compose will automatically pick up this variable when you run `docker compose up`. If you don't set the variable or create a `.env` file, it will default to `syslog`.

## Running the Stack

The recommended way to run the IGRA Orchestra stack is:

1. **Start Kaspa Services First**
   ```bash
   docker compose --profile kaspad up -d
   ```

2. **Start Explorer Services (Optional)**
   ```bash
   docker compose --profile kaspa-explorer up -d
   ```

3. **Start Worker Services**
   Choose the profile based on how many workers you need:
   ```bash
   # For 1 worker
   docker compose --profile igra-w1 up -d

   # For 2 workers
   docker compose --profile igra-w2 up -d

   # For 3 workers
   docker compose --profile igra-w3 up -d
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

By default, container logs are sent to the system's `syslog` driver (configurable via the `LOGGING_DRIVER` environment variable, see Configuration section). Logs are tagged with `igra-orchestra-devnet/{{.Name}}/{{.ID}}`.

If you've configured the `json-file` driver (e.g., on macOS), use standard `docker logs` commands.

#### Viewing Syslog Logs (Default on Linux)

1. **View all logs in real-time**:
   ```bash
   sudo journalctl -f | grep igra-orchestra-devnet
   ```

2. **View logs for a specific service**:
   ```bash
   sudo journalctl -f | grep "igra-orchestra-devnet/execution-layer"
   sudo journalctl -f | grep "igra-orchestra-devnet/rpc-provider-0"
   ```

3. **View logs from standard syslog file**:
   ```bash
   sudo tail -f /var/log/syslog | grep igra-orchestra-devnet
   ```

4. **View logs using Docker commands** (bypasses syslog):
   ```bash
   docker logs -f execution-layer
   docker logs -f rpc-provider-0
   ```

#### Viewing Logs (json-file driver or direct Docker)

The syslog tagging format allows for easy filtering by service name, making it possible to debug specific components of the stack. If using the `json-file` driver, standard `docker logs` filtering applies.

## Troubleshooting

### Common Issues

1. **Container name conflicts**: Stop existing containers before starting new ones
2. **Missing worker keys**: Ensure required key files exist in the correct format
3. **Missing repositories**: Run `setup-repos.sh` to clone the required repositories
4. **Permission issues**: Check data directory permissions
5. **Profile dependencies**: Make sure to start profiles in the correct order (kaspad → explorer → workers)
6. **Missing JWT file**: Ensure you've created the JWT file before starting services
7. **Service connectivity**: Ensure all services can properly connect by starting profiles in the correct order and allowing time for services to initialize
```
