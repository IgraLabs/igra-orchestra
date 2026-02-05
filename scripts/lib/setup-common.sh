#!/bin/bash
set -euo pipefail
# setup-common.sh - Shared library for IGRA setup scripts
#
# This library provides common functions for environment setup.
# Entry scripts must set the following variables before sourcing:
#   ENV_NAME        - Display name (e.g., "Galleon Testnet")
#   ENV_FILE        - Template file (e.g., ".env.galleon-testnet.example")
#   NODE_ID_PREFIX  - Node ID prefix (e.g., "GTN-", "GMN-")
#   KASWALLET_FLAG  - Flag for key generation (e.g., "--testnet", "--enable-mainnet-pre-launch")

# --- Configuration ---
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source image versions from central versions file
# shellcheck source=/dev/null
if [[ -f "$PROJECT_DIR/versions.env" ]]; then
    source "$PROJECT_DIR/versions.env"
else
    echo "ERROR: versions.env not found in $PROJECT_DIR" >&2
    exit 1
fi
KASWALLET_IMAGE="igranetwork/kaswallet:${KASWALLET_VERSION}"
KASPAD_IMAGE="igranetwork/kaspad:${KASPAD_VERSION}"

# --- Helper Functions ---

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    printf "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: %b\n" "$*" >&2
}

die() {
    error "$@"
    exit 1
}

prompt_input() {
    local prompt="$1"
    local default="${2:-}"
    local result

    if [[ -n "$default" ]]; then
        read -r -p "$prompt [$default]: " result
        echo "${result:-$default}"
    else
        read -r -p "$prompt: " result
        echo "$result"
    fi
}

prompt_confirm() {
    local prompt="$1"
    local default="${2:-y}"
    local result

    if [[ "$default" == "y" ]]; then
        read -r -p "$prompt [Y/n]: " result
        [[ -z "$result" || "$result" =~ ^[Yy] ]]
    else
        read -r -p "$prompt [y/N]: " result
        [[ "$result" =~ ^[Yy] ]]
    fi
}

prompt_password() {
    local prompt="$1"
    local password

    # Only use -s (silent) if stdin is a terminal
    if [[ -t 0 ]]; then
        read -r -s -p "$prompt: " password
        echo >&2  # Newline after hidden input (to stderr so it doesn't mix with output)
    else
        read -r password
    fi
    echo "$password"
}

run_docker_compose() {
    if ! docker compose "$@"; then
        error "docker compose $* failed"
        return 1
    fi
}

print_help() {
    local script_name
    script_name="$(basename "$0")"
    cat << EOF
Usage: ./$script_name [OPTIONS]

Interactive setup script for IGRA ${ENV_NAME} deployment.

Options:
  -h, --help    Show this help message and exit

This script will:
  1. Check prerequisites (Docker, Docker Compose)
  2. Configure environment (.env file)
  3. Generate JWT secret and wallet keys
  4. Start all services automatically
  5. Optionally show live block building stats

For manual setup, see the documentation in doc/
EOF
}

check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        die "Docker is not installed. Please install Docker first."
    fi
    log "Docker: OK"

    if ! docker compose version &> /dev/null; then
        die "Docker Compose is not installed. Please install Docker Compose first."
    fi
    log "Docker Compose: OK"

    if ! docker info &> /dev/null; then
        die "Docker daemon is not running. Please start Docker first."
    fi
    log "Docker daemon: OK"

    if ! command -v openssl &> /dev/null; then
        die "openssl is not installed. Please install it first:\n  - macOS: brew install openssl\n  - Ubuntu/Debian: sudo apt install openssl"
    fi
    log "openssl: OK"

    if ! command -v jq &> /dev/null; then
        die "jq is not installed. Please install it first:\n  - macOS: brew install jq\n  - Ubuntu/Debian: sudo apt install jq"
    fi
    log "jq: OK"
}

update_env_var() {
    local file="$1"
    local var="$2"
    local value="$3"
    local tmpfile

    # Use a temp file approach to safely handle special characters in values
    if grep -q "^${var}=" "$file"; then
        # Create temp file, replace the line, then move back
        tmpfile=$(mktemp) || { error "Failed to create temp file"; return 1; }
        chmod 600 "$tmpfile" || { rm -f "$tmpfile"; error "Failed to secure temp file"; return 1; }

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${var}="* ]]; then
                printf '%s=%s\n' "$var" "$value"
            else
                printf '%s\n' "$line"
            fi
        done < "$file" > "$tmpfile"

        if ! mv "$tmpfile" "$file"; then
            rm -f "$tmpfile"
            error "Failed to update $file"
            return 1
        fi
    else
        printf '%s=%s\n' "$var" "$value" >> "$file"
    fi
}

# --- Wallet Generation ---

generate_wallet() {
    local index="$1"
    local password="$2"
    local keyfile="keys/keys.kaswallet-${index}.json"

    log "Generating wallet $index..."

    # Validate PROJECT_DIR doesn't contain dangerous characters for shell interpolation
    if [[ "$PROJECT_DIR" =~ [\'\"\$\`\\] ]]; then
        die "PROJECT_DIR contains unsafe characters: $PROJECT_DIR"
    fi

    # Use expect to handle interactive password prompts
    # Pass password via environment variable to avoid command injection
    # Use --user to ensure files are created with correct ownership
    if ! WALLET_PASS="$password" expect -c '
        log_user 0
        spawn docker run --rm -it --user '"$(id -u):$(id -g)"' \
            -v "'"$PROJECT_DIR"'/keys:/keys" \
            --entrypoint /app/kaswallet-create \
            '"$KASWALLET_IMAGE"' '"$KASWALLET_FLAG"' \
            -k /keys/keys.kaswallet-'"${index}"'.json
        expect "password:"
        send -- "$env(WALLET_PASS)\r"
        expect "password"
        send -- "$env(WALLET_PASS)\r"
        expect eof
    ' 2>&1 | tee -a "$PROJECT_DIR/keys/.wallet-gen.log" > /dev/null; then
        die "Failed to generate wallet $index. Check Docker and try again."
    fi
    chmod 600 "$PROJECT_DIR/keys/.wallet-gen.log" 2>/dev/null || true

    if [[ ! -f "$keyfile" ]]; then
        die "Wallet key file $keyfile was not created. Something went wrong."
    fi

    # Validate wallet file is valid JSON (if jq is available)
    if command -v jq &> /dev/null; then
        if ! jq empty "$keyfile" 2>/dev/null; then
            die "Wallet key file $keyfile is not valid JSON. Generation may have failed."
        fi
    fi

    # Try to restrict permissions (may fail on Linux if file is owned by root)
    chmod 600 "$keyfile" 2>/dev/null || true
}

# --- Service Management ---

start_services() {
    local num_workers="$1"

    # Clean up any containers that may conflict with our service names
    # This handles orphans from different compose projects, manual docker runs, etc.
    local running=""
    while read -r name; do
        if docker ps -q -f "name=^${name}$" 2>/dev/null | grep -q .; then
            running="${running:+$running, }$name"
        fi
    done < <(run_docker_compose config --format json | jq -r '.services[].container_name // empty')

    if [[ -n "$running" ]]; then
        log "Running containers that will be replaced: $running"
        if ! prompt_confirm "Remove these containers and start fresh?"; then
            die "Aborted by user."
        fi
    fi

    local removed=""
    while read -r name; do
        if docker rm -f "$name" > /dev/null 2>&1; then
            removed="${removed:+$removed, }$name"
        fi
    done < <(run_docker_compose config --format json | jq -r '.services[].container_name // empty')
    if [[ -n "$removed" ]]; then
        log "Removed conflicting containers: $removed"
    fi

    log "Starting backend services (execution-layer, kaspad, node-health-check)..."
    if ! run_docker_compose --profile backend up -d --no-build; then
        die "Failed to start backend services."
    fi
    log "Backend services started"
    echo

    log "Waiting 10 seconds for backend services to initialize..."
    sleep 10

    log "Starting worker services ($num_workers workers)..."
    if ! run_docker_compose --profile "frontend-w${num_workers}" up -d --no-build; then
        log "WARNING: Some worker services failed to start."
        log "This is expected if kaspad has not completed IBD sync yet."
        log "Kaswallet services require kaspad to be fully synced before they can start."
    else
        log "Worker services started"
    fi
    echo
}

print_summary() {
    echo "========================================"
    echo "  Setup Complete!"
    echo "========================================"
    echo
    echo "Services started:"
    docker compose ps --format "table {{.Name}}\t{{.Status}}"
    echo
    echo "NOTE: kaswallet services may NOT start until kaspad completes IBD sync."
    echo "      This typically takes 4-6 hours for initial sync."
    echo
    echo "Useful commands:"
    echo "  docker compose logs -f kaspad                   # Monitor kaspad sync progress"
    echo "  docker compose logs -f execution-layer          # Monitor execution layer"
    echo "  docker compose logs -f node-health-check-client # Monitor health check status"
    echo "  docker compose logs -f kaswallet-0              # Monitor kaswallet logs"
    echo "  docker compose logs -f rpc-provider-0           # Monitor RPC provider (tx-parser)"
    echo "  docker stats                                    # View resource usage"
    echo "  ./scripts/debug/wallet-status.sh                # Check wallet balances"
    echo
    echo "Block building stats (after IBD sync):"
    echo "  docker logs -f -n 10 kaspad | docker run --rm -i --entrypoint /app/adapter-stats $KASPAD_IMAGE"
    echo
    echo "=== Optional: Enable Transaction Submission (RPC) ==="
    echo
    echo "By default, RPC is read-only (RPC_READ_ONLY=true)."
    echo "If you want to accept and submit user transactions:"
    echo
    echo "  1. Set RPC_READ_ONLY=false in .env"
    echo "  2. After IBD sync completes (IBD: 100%):"
    echo "     - Get wallet addresses: ./scripts/debug/wallet-status.sh"
    echo "     - Top up each wallet address with KAS (for L1 gas fees)"
    echo "     - Update .env with the actual wallet addresses"
    echo "  3. Restart workers: docker compose --profile frontend-w5 up -d"
    echo
}

show_live_stats() {
    echo "Your node is now running in the background."
    echo
    if prompt_confirm "Would you like to see live sync progress and block building stats?" "y"; then
        echo
        log "Showing sync progress (IBD/UTXO) and block building stats..."
        log "Press Ctrl+C at any time to exit - your node will continue running."
        echo
        # Using trap to handle Ctrl+C gracefully
        trap 'echo; log "Stats viewer stopped."; return 0' INT
        # Show IBD/UTXO sync progress and block building stats simultaneously
        # Sync progress lines go to stderr for visibility, full stream goes to adapter-stats
        docker logs -f -n 10 kaspad 2>&1 | \
            tee >(grep --line-buffered -E "IBD|UTXO" | sed -u 's/^/[Kaspa Sync] /' >&2) | \
            docker run --rm -i --entrypoint /app/adapter-stats "$KASPAD_IMAGE" || true
        trap - INT
    fi
}

# --- Main Setup Function ---

validate_required_variables() {
    local missing=()
    local var

    # Validate KASWALLET_FLAG is a known-safe value
    case "${KASWALLET_FLAG:-}" in
        --testnet|--enable-mainnet-pre-launch)
            ;;
        *)
            die "Invalid KASWALLET_FLAG: ${KASWALLET_FLAG:-<unset>}. Must be --testnet or --enable-mainnet-pre-launch"
            ;;
    esac

    for var in ENV_NAME ENV_FILE NODE_ID_PREFIX KASWALLET_FLAG; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Required variables not set: ${missing[*]}"
    fi
}

run_setup() {
    validate_required_variables

    # Parse arguments
    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        print_help
        exit 0
    fi

    cd "$PROJECT_DIR" || die "Failed to change to project directory: $PROJECT_DIR"

    echo "========================================"
    echo "  IGRA ${ENV_NAME} Setup Script"
    echo "========================================"
    echo

    # Step 1: Prerequisites Check
    check_prerequisites
    echo

    # Check template exists
    if [[ ! -f "$ENV_FILE" ]]; then
        die "Template file $ENV_FILE not found in $PROJECT_DIR"
    fi

    # Check for existing .env and offer backup
    if [[ -f .env ]]; then
        log "Existing .env file found. It will be replaced with the template."
        if prompt_confirm "Do you want to backup the existing .env first?" "y"; then
            local backup_file=".env.backup.$(date +%Y%m%d_%H%M%S)"
            cp .env "$backup_file"
            log "Backed up to $backup_file"
        fi
    fi

    # Always copy template to .env and append image versions
    cp "$ENV_FILE" .env
    printf '\n# --- Image Versions (from versions.env) ---\n' >> .env
    cat "$PROJECT_DIR/versions.env" >> .env
    chmod 600 .env  # Protect .env file containing sensitive credentials
    log "Created .env from template (with image versions)"

    # Configure Environment
    echo
    log "=== Configuration ==="
    echo

    # NODE_ID
    echo "NODE_ID is used to identify your node on the monitoring dashboard."
    echo "The ${NODE_ID_PREFIX} prefix will be added automatically."
    NODE_NAME=$(prompt_input "Enter your node name" "$(hostname)")
    # Validate node name format - alphanumeric, hyphens, underscores only
    if [[ ! "$NODE_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "Invalid node name format. Use only alphanumeric characters, hyphens, and underscores."
    fi
    NODE_ID="${NODE_ID_PREFIX}${NODE_NAME}"
    if [[ ${#NODE_ID} -gt 64 ]]; then
        die "NODE_ID too long. Maximum 64 characters allowed (including ${NODE_ID_PREFIX} prefix)."
    fi
    update_env_var .env "NODE_ID" "$NODE_ID"
    log "NODE_ID set to: $NODE_ID"
    echo

    # Domain (optional)
    echo "HTTPS domain is optional. Skip if you don't have a domain configured."
    DOMAIN=$(prompt_input "Enter your domain (or press Enter to skip)" "")
    if [[ -n "$DOMAIN" ]]; then
        # Validate domain format (basic check - no spaces, newlines, or shell metacharacters)
        if [[ "$DOMAIN" =~ [[:space:]\'\"\$\`\\] ]]; then
            die "Invalid domain format. Domain cannot contain spaces or special characters."
        fi
        if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
            die "Invalid domain format: $DOMAIN"
        fi
        update_env_var .env "IGRA_ORCHESTRA_DOMAIN" "$DOMAIN"

        DOMAIN_EMAIL=$(prompt_input "Enter email for Let's Encrypt" "")
        if [[ -n "$DOMAIN_EMAIL" ]]; then
            # Basic email validation
            if [[ ! "$DOMAIN_EMAIL" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
                die "Invalid email format: $DOMAIN_EMAIL"
            fi
            update_env_var .env "IGRA_ORCHESTRA_DOMAIN_EMAIL" "$DOMAIN_EMAIL"
        fi
    fi
    echo

    # Generate Secrets & Wallet Keys
    log "=== Secrets & Wallet Keys ==="
    echo

    # Create keys directory
    mkdir -p keys
    chmod 700 keys  # Restrict access to keys directory

    # Generate JWT secret
    if [[ ! -f keys/jwt.hex ]]; then
        openssl rand -hex 32 > keys/jwt.hex
        chmod 600 keys/jwt.hex
        log "Generated JWT secret: keys/jwt.hex"
    else
        log "JWT secret already exists: keys/jwt.hex"
    fi

    # Number of workers (fixed at 5)
    NUM_WORKERS=5

    # Check for existing wallet files
    EXISTING_WALLETS=()
    MISSING_WALLETS=()
    for i in $(seq 0 $((NUM_WORKERS - 1))); do
        keyfile="keys/keys.kaswallet-${i}.json"
        if [[ -f "$keyfile" ]]; then
            EXISTING_WALLETS+=("$i")
        else
            MISSING_WALLETS+=("$i")
        fi
    done

    if [[ ${#EXISTING_WALLETS[@]} -gt 0 ]]; then
        log "Found existing wallet files for workers: ${EXISTING_WALLETS[*]}"
        if [[ ${#MISSING_WALLETS[@]} -gt 0 ]]; then
            log "Missing wallet files for workers: ${MISSING_WALLETS[*]}"
        fi
        if prompt_confirm "Do you want to regenerate ALL wallet keys? (existing keys will be backed up)" "n"; then
            # Backup existing wallets
            backup_dir="keys/backup.$(date +%Y%m%d_%H%M%S)"
            mkdir -p "$backup_dir"
            for i in "${EXISTING_WALLETS[@]}"; do
                mv "keys/keys.kaswallet-${i}.json" "$backup_dir/"
            done
            log "Backed up existing wallets to $backup_dir"
            mapfile -t MISSING_WALLETS < <(seq 0 $((NUM_WORKERS - 1)))
        fi
    else
        mapfile -t MISSING_WALLETS < <(seq 0 $((NUM_WORKERS - 1)))
    fi

    # Ask for password if we need to generate new wallets
    WALLET_PASSWORD=""
    if [[ ${#MISSING_WALLETS[@]} -gt 0 ]]; then
        # Check for expect only when needed for wallet generation
        if ! command -v expect &> /dev/null; then
            die "expect is not installed. Please install it first:
  - macOS: brew install expect
  - Ubuntu/Debian: sudo apt install expect"
        fi

        echo "Enter a password for the wallet keys (used for all workers)."
        echo "Press Enter for empty password."
        WALLET_PASSWORD=$(prompt_password "Wallet password")
        echo

        # Generate missing wallet keys
        log "Generating wallet keys for workers: ${MISSING_WALLETS[*]}..."
        for i in "${MISSING_WALLETS[@]}"; do
            generate_wallet "$i" "$WALLET_PASSWORD"
        done
    else
        log "All wallet files already exist, skipping generation"
        # Still need password for .env update
        echo "Enter the password for your existing wallet keys."
        WALLET_PASSWORD=$(prompt_password "Wallet password")
        echo
    fi

    # Update .env with wallet passwords for all workers
    log "Updating .env with wallet passwords..."
    for i in $(seq 0 $((NUM_WORKERS - 1))); do
        update_env_var .env "W${i}_KASWALLET_PASSWORD" "$WALLET_PASSWORD"
    done
    log "Passwords configured for $NUM_WORKERS workers"

    # Clear sensitive data from memory (best effort - bash limitations apply)
    WALLET_PASSWORD=""
    unset WALLET_PASSWORD
    echo

    # Start Services
    log "=== Starting Services ==="
    echo
    start_services "$NUM_WORKERS"

    # Summary and optional live stats
    print_summary
    show_live_stats

    log "Setup complete. Your node is now running."
}
