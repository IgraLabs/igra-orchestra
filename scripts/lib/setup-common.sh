#!/bin/bash
set -euo pipefail
# setup-common.sh - Shared library for IGRA setup scripts
#
# This library provides common functions for environment setup.
# Entry scripts must set the following variables before sourcing:
#   ENV_NAME        - Display name (e.g., "Galleon Testnet")
#   ENV_FILE        - Template file (e.g., ".env.galleon-testnet.example")
#   NODE_ID_PREFIX  - Node ID prefix (e.g., "GTN-", "GMN-")
#   KASWALLET_FLAG  - Flags for key generation (e.g., "--testnet --testnet-suffix=10")

# --- Configuration ---
SCRIPT_DIR="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

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

read_env_value() {
    local file="$1"
    local var="$2"
    local line key value result=""

    [[ -f "$file" ]] || return 0

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line%$'\r'}"
        [[ "$line" =~ ^[[:space:]]*($|#) ]] && continue
        [[ "$line" == *"="* ]] || continue

        key="${line%%=*}"
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        [[ "$key" == "$var" ]] || continue

        value="${line#*=}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ ${#value} -ge 2 ]]; then
            case "$value" in
                \"*\"|\'*\') value="${value:1:${#value}-2}" ;;
            esac
        fi
        result="$value"
    done < "$file"

    printf '%s' "$result"
}

find_unresolved_placeholders() {
    local file

    for file in "$@"; do
        [[ -f "$file" ]] || continue
        awk '
            /^[[:space:]]*(#|$)/ { next }
            /TODO_[A-Z0-9_]*(_REPLACE_ME)?/ {
                printf "%s:%d:%s\n", FILENAME, FNR, $0
            }
        ' "$file"
    done
}

refresh_image_versions_from_env() {
    local env_file="${1:-.env}"
    local var value

    for var in KASPAD_VERSION RETH_VERSION RPC_PROVIDER_VERSION KASWALLET_VERSION NODE_HEALTH_CHECK_VERSION ATAN_UPLOADER_VERSION; do
        value="$(read_env_value "$env_file" "$var")"
        if [[ -n "$value" ]]; then
            printf -v "$var" '%s' "$value"
        fi
    done

    KASWALLET_IMAGE="igranetwork/kaswallet:${KASWALLET_VERSION:-}"
    KASPAD_IMAGE="igranetwork/kaspad:${KASPAD_VERSION:-}"
}

validate_required_image_versions() {
    local missing=()
    local var value

    for var in KASPAD_VERSION RETH_VERSION RPC_PROVIDER_VERSION KASWALLET_VERSION NODE_HEALTH_CHECK_VERSION ATAN_UPLOADER_VERSION; do
        value="${!var:-}"
        if [[ -z "$value" || "$value" == TODO_* ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Required image versions are missing or still TODO placeholders: ${missing[*]}. Fill them in .env before re-running setup."
    fi
}

load_default_image_versions() {
    if [[ -z "${VERSIONS_FILE:-}" ]]; then
        die "VERSIONS_FILE not set"
    fi
    if [[ -f "$PROJECT_DIR/$VERSIONS_FILE" ]]; then
        # shellcheck source=/dev/null
        source "$PROJECT_DIR/$VERSIONS_FILE"
        refresh_image_versions_from_env "$PROJECT_DIR/$VERSIONS_FILE"
    else
        die "$VERSIONS_FILE not found in $PROJECT_DIR"
    fi
}

load_default_image_versions

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

wait_for_container_ready() {
    local name="$1"
    local timeout_seconds="${2:-300}"
    local waited=0
    local state
    local health

    while (( waited < timeout_seconds )); do
        state="$(docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || true)"
        health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || true)"

        if [[ "$state" == "running" && ( "$health" == "healthy" || "$health" == "none" ) ]]; then
            return 0
        fi

        if [[ "$state" == "exited" || "$state" == "dead" ]]; then
            error "$name exited before becoming ready"
            return 1
        fi

        sleep 2
        waited=$((waited + 2))
    done

    error "Timed out waiting for $name to become ready"
    return 1
}

wait_for_backend_readiness() {
    log "Waiting for backend services to become ready..."

    if ! wait_for_container_ready execution-layer 300; then
        return 1
    fi

    if ! wait_for_container_ready kaspad 300; then
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
  4. Start all services automatically once required placeholders are filled
  5. Optionally show live block building stats

For manual setup, see the documentation in doc/
EOF
}

check_prerequisites() {
    log "Checking prerequisites..."
    local missing_tools=()
    local errors=()

    # Check Docker
    if ! command -v docker &> /dev/null; then
        errors+=("Docker is not installed. Please install Docker: https://docs.docker.com/get-docker/")
    else
        log "Docker: OK"

        if ! docker compose version &> /dev/null; then
            errors+=("Docker Compose plugin is not available. Please update Docker or install the Compose plugin.")
        else
            log "Docker Compose: OK"
        fi

        if ! docker info &> /dev/null; then
            errors+=("Docker daemon is not running. Please start Docker.")
        else
            log "Docker daemon: OK"
        fi
    fi

    # Check CLI tools
    if ! command -v openssl &> /dev/null; then
        missing_tools+=("openssl")
    else
        log "openssl: OK"
    fi

    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    else
        log "jq: OK"
    fi

    if ! command -v expect &> /dev/null; then
        missing_tools+=("expect")
    else
        log "expect: OK"
    fi

    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        errors+=("Missing tools: ${missing_tools[*]}\n  macOS:         brew install ${missing_tools[*]}\n  Ubuntu/Debian: sudo apt install ${missing_tools[*]}")
    fi

    if [[ ${#errors[@]} -gt 0 ]]; then
        echo >&2
        for err in "${errors[@]}"; do
            error "$err"
        done
        echo >&2
        die "Please fix the above issues and re-run this script."
    fi
}

# Resolve A/AAAA records, comma-joined. Fall back to dig where getent is unreliable.
resolve_lb_ips() {
    local host="$1"
    local v4 v6 ips=""
    if command -v getent &> /dev/null; then
        ips=$(
            {
                getent ahostsv4 "$host" 2>/dev/null
                getent ahostsv6 "$host" 2>/dev/null
            } | awk '{print $1}' | sort -u | paste -sd, -
        )
    fi
    if [[ -z "$ips" ]] && command -v dig &> /dev/null; then
        log "getent returned empty for $host, trying dig..."
        v4=$(dig +short A "$host" 2>/dev/null | grep -E '^[0-9.]+$' || true)
        v6=$(dig +short AAAA "$host" 2>/dev/null | grep -E '^[0-9a-fA-F:]+$' || true)
        ips=$(printf '%s\n%s\n' "$v4" "$v6" | grep -v '^$' | sort -u | paste -sd, - || true)
    fi
    printf '%s' "$ips"
}

update_env_var() {
    local file="$1"
    local var="$2"
    local value="$3"
    local tmpfile

    if grep -q "^${var}=" "$file"; then
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

    # Pre-create with mode 600 before tee writes prompt output.
    local wallet_log="$PROJECT_DIR/keys/.wallet-gen.log"
    if [[ ! -f "$wallet_log" ]]; then
        (umask 077 && : > "$wallet_log")
    fi
    chmod 600 "$wallet_log" 2>/dev/null || true

    # Use expect for password prompts; pass the password via env and run as the caller.
    # shellcheck disable=SC2016 # Variables are intentionally spliced via quote-breaking, not expanded inside single quotes
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
    ' 2>&1 | tee -a "$wallet_log" > /dev/null; then
        die "Failed to generate wallet $index. Check Docker and try again."
    fi
    chmod 600 "$wallet_log" 2>/dev/null || true

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

    if ! wait_for_backend_readiness; then
        die "Backend services did not become ready."
    fi

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
    echo "Core services exit when a required upstream dependency disappears."
    echo "Mainnet templates restart them automatically; testnet and dev do not."
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
    echo "  docker logs -f -n 10 kaspad | docker run --rm -i --entrypoint /app/adapter-stats igranetwork/kaspad:\$(grep KASPAD_VERSION $VERSIONS_FILE | cut -d= -f2)"
    echo
    echo "=== Optional: Enable Transaction Submission (RPC) ==="
    echo
    local rpc_read_only
    rpc_read_only="$(awk -F= '$1 == "RPC_READ_ONLY" { print $2; exit }' .env 2>/dev/null || true)"
    if [[ "$rpc_read_only" == "true" ]]; then
        echo "RPC is currently read-only (RPC_READ_ONLY=true)."
        echo "To enable transaction submission, fund the wallets and set RPC_READ_ONLY=false:"
    else
        echo "RPC currently accepts transactions (RPC_READ_ONLY=false)."
        echo "Before exposing transaction submission, fund the wallets:"
    fi
    echo
    echo "  1. After IBD sync completes (IBD: 100%):"
    echo "     - Get wallet addresses: ./scripts/debug/wallet-status.sh"
    echo "     - Top up each wallet address with KAS (for L1 gas fees)"
    echo "     - Update .env with the actual wallet addresses"
    echo "  2. Restart workers: docker compose --profile frontend-w${NUM_WORKERS} up -d"
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
        --testnet|--devnet|--enable-mainnet-pre-launch)
            ;;
        *)
            if [[ ! "${KASWALLET_FLAG:-}" =~ ^--testnet[[:space:]]+--testnet-suffix=[0-9]+$ ]]; then
                die "Invalid KASWALLET_FLAG: ${KASWALLET_FLAG:-<unset>}. Must be --testnet, --testnet --testnet-suffix=<digits>, --devnet, or --enable-mainnet-pre-launch"
            fi
            ;;
    esac

    for var in ENV_NAME ENV_FILE NODE_ID_PREFIX KASWALLET_FLAG VERSIONS_FILE; do
        if [[ -z "${!var:-}" ]]; then
            missing+=("$var")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Required variables not set: ${missing[*]}"
    fi
}

validate_no_unresolved_placeholders() {
    local files=("$@")
    local matches

    if [[ ${#files[@]} -eq 0 ]]; then
        files=(.env)
    fi

    matches="$(find_unresolved_placeholders "${files[@]}")"
    if [[ -n "$matches" ]]; then
        error "Unresolved placeholders found; replace these values before running setup:"
        printf '%s\n' "$matches" | sed 's|^|  |' >&2
        die "Setup aborted before generating wallets or starting services."
    fi
}

run_setup() {
    validate_required_variables

    if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
        print_help
        exit 0
    fi

    cd "$PROJECT_DIR" || die "Failed to change to project directory: $PROJECT_DIR"

    echo "========================================"
    echo "  IGRA ${ENV_NAME} Setup Script"
    echo "========================================"
    echo

    check_prerequisites
    echo

    if [[ ! -f "$ENV_FILE" ]]; then
        die "Template file $ENV_FILE not found in $PROJECT_DIR"
    fi

    local template_network existing_network template_has_placeholders replace_env=true
    template_network="$(read_env_value "$ENV_FILE" NETWORK)"
    existing_network="$(read_env_value .env NETWORK)"
    if [[ -n "$(find_unresolved_placeholders "$ENV_FILE" "$PROJECT_DIR/$VERSIONS_FILE")" ]]; then
        template_has_placeholders=true
    else
        template_has_placeholders=false
    fi

    # Preserve same-network pre-launch .env files so operators can fill placeholders.
    if [[ -f .env && "$template_has_placeholders" == "true" && "$existing_network" == "$template_network" ]]; then
        replace_env=false
        log "Existing .env for NETWORK=$existing_network found; preserving operator-edited values."
    fi

    if [[ "$replace_env" == "true" ]]; then
        if [[ -f .env ]]; then
            log "Existing .env file found. It will be replaced with the template."
            if prompt_confirm "Do you want to backup the existing .env first?" "y"; then
                local backup_file
                backup_file=".env.backup.$(date +%Y%m%d_%H%M%S)"
                # Backup contains .env credentials, so create it with restrictive perms.
                (umask 077 && cp .env "$backup_file")
                chmod 600 "$backup_file" || die "Failed to chmod backup $backup_file; refusing to leave it world-readable."
                log "Backed up to $backup_file"
            fi
        fi

        cp "$ENV_FILE" .env
        printf '\n# --- Image Versions (from %s) ---\n' "$VERSIONS_FILE" >> .env
        cat "$PROJECT_DIR/$VERSIONS_FILE" >> .env
        chmod 600 .env  # Protect .env file containing sensitive credentials
        log "Created .env from template (with image versions)"
    fi

    validate_no_unresolved_placeholders .env
    refresh_image_versions_from_env .env
    validate_required_image_versions

    # Auto-populate trusted proxies when a wrapper or .env provides an RPC LB.
    local effective_rpc_lb_hostname env_rpc_lb_hostname
    effective_rpc_lb_hostname="${RPC_LB_HOSTNAME:-}"
    env_rpc_lb_hostname="$(read_env_value .env RPC_LB_HOSTNAME)"
    if [[ -z "$effective_rpc_lb_hostname" && -n "$env_rpc_lb_hostname" ]]; then
        effective_rpc_lb_hostname="$env_rpc_lb_hostname"
    fi
    if [[ -n "$effective_rpc_lb_hostname" ]]; then
        update_env_var .env "RPC_LB_HOSTNAME" "$effective_rpc_lb_hostname"
        local lb_ips
        lb_ips=$(resolve_lb_ips "$effective_rpc_lb_hostname")
        if [[ -n "$lb_ips" ]]; then
            update_env_var .env "ORCHESTRA_TRUSTED_PROXIES" "$lb_ips"
            log "Resolved $effective_rpc_lb_hostname -> $lb_ips (ORCHESTRA_TRUSTED_PROXIES)"
        else
            echo >&2
            echo "WARN: could not resolve $effective_rpc_lb_hostname; ORCHESTRA_TRUSTED_PROXIES left empty." >&2
            echo "      Rate limiting will key on proxy IP, not real client IP if behind an LB." >&2
            echo "      Edit .env manually once DNS is reachable, or re-run this script." >&2
            echo >&2
        fi
    fi

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

    # Number of workers (configurable via NUM_WORKERS env var, default: 5, max: 20)
    NUM_WORKERS="${NUM_WORKERS:-5}"
    if ! [[ "$NUM_WORKERS" =~ ^[0-9]+$ ]] || [[ "$NUM_WORKERS" -lt 1 ]] || [[ "$NUM_WORKERS" -gt 20 ]]; then
        die "NUM_WORKERS must be a number between 1 and 20 (got: $NUM_WORKERS)"
    fi

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
            MISSING_WALLETS=()
            for i in $(seq 0 $((NUM_WORKERS - 1))); do
                MISSING_WALLETS+=("$i")
            done
        fi
    else
        MISSING_WALLETS=()
        for i in $(seq 0 $((NUM_WORKERS - 1))); do
            MISSING_WALLETS+=("$i")
        done
    fi

    # Ask for password if we need to generate new wallets
    WALLET_PASSWORD=""
    if [[ ${#MISSING_WALLETS[@]} -gt 0 ]]; then
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
