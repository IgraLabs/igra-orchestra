#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ORCHESTRA_ENV_FILE:-$PROJECT_DIR/.env.kaspa-exit-devnet}"
if [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$PROJECT_DIR/$ENV_FILE"
fi
EXAMPLE_ENV_FILE="$PROJECT_DIR/.env.kaspa-exit-devnet.example"

usage() {
    cat <<'EOF'
Usage: ./scripts/dev/kaspa-exit-devnet.sh <command> [args]

Commands:
  setup             Create env/JWT files and clone pinned repositories
  up                Build and start kaspad + Igra execution-layer
  miner             Build and start kaspa-miner
  real-spend-e2e    Mine to multisig custody and prove safe-service broadcast
  bootstrap         Run setup, up, miner, then wait for Igra L2 blocks
  wait-daa [score]  Wait until Kaspa virtual DAA reaches score (default: 1000)
  wait-igra [hex]   Wait until eth_blockNumber is at least hex/decimal block (default: 1)
  status            Print compose status, Kaspa DAA, and Igra block number
  logs [service]    Tail logs for the stack or one service
  down              Stop only this devnet project
  config            Render the merged Docker Compose config

Use ORCHESTRA_ENV_FILE=/path/to/env to select a different env file.
EOF
}

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required"
}

setup_aux_repo() {
    local repo_url="$1"
    local branch="$2"
    local folder="${repo_url##*/}"
    folder="${folder%.git}"
    local target="$PROJECT_DIR/build/repos/$folder"

    [[ -n "$repo_url" ]] || return 0
    [[ -n "$branch" ]] || die "Missing branch for $repo_url"

    if [[ ! -d "$target/.git" ]]; then
        log "Cloning $repo_url into build/repos/$folder"
        git clone "$repo_url" "$target"
    fi

    log "Configuring build/repos/$folder on $branch"
    git -C "$target" fetch
    git -C "$target" checkout "$branch"
    git -C "$target" pull --ff-only
}

ensure_env_file() {
    if [[ ! -f "$ENV_FILE" ]]; then
        cp "$EXAMPLE_ENV_FILE" "$ENV_FILE"
        log "Created $ENV_FILE from $(basename "$EXAMPLE_ENV_FILE")"
        log "Edit ports, subnet, branches, or MINING_ADDRESS there if needed."
    fi
}

load_env() {
    ensure_env_file
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a

    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-igra-kaspa-exit-devnet}"
    KASPA_EXIT_DEVNET_CONTAINER_PREFIX="${KASPA_EXIT_DEVNET_CONTAINER_PREFIX:-$COMPOSE_PROJECT_NAME}"
    EL_HTTP_HOST_PORT="${EL_HTTP_HOST_PORT:-9545}"
    KASPAD_JSON_PORT="${KASPAD_JSON_PORT:-18610}"
}

compose() {
    load_env
    docker compose \
        -p "$COMPOSE_PROJECT_NAME" \
        --env-file "$ENV_FILE" \
        -f "$PROJECT_DIR/docker-compose.yml" \
        -f "$PROJECT_DIR/docker-compose.kaspa-exit-devnet.yml" \
        "$@"
}

kaspa_dag_info() {
    curl -fsS \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"getBlockDagInfo","params":{}}' \
        "http://127.0.0.1:${KASPAD_JSON_PORT}" \
        | jq '.result // .'
}

kaspa_virtual_daa() {
    kaspa_dag_info | jq -r '.virtualDaaScore // .virtual_daa_score // empty'
}

igra_block_hex() {
    curl -fsS \
        -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        "http://127.0.0.1:${EL_HTTP_HOST_PORT}" \
        | jq -r '.result // empty'
}

to_decimal_block() {
    local value="$1"
    if [[ "$value" == 0x* || "$value" == 0X* ]]; then
        value="${value#0x}"
        value="${value#0X}"
        printf '%d\n' "$((16#$value))"
    else
        printf '%d\n' "$value"
    fi
}

cmd_setup() {
    require_cmd docker
    require_cmd git
    require_cmd jq
    require_cmd curl
    require_cmd openssl

    ensure_env_file
    mkdir -p "$PROJECT_DIR/keys" "$PROJECT_DIR/build/repos"
    if [[ ! -f "$PROJECT_DIR/keys/jwt.hex" ]]; then
        openssl rand -hex 32 > "$PROJECT_DIR/keys/jwt.hex"
        chmod 600 "$PROJECT_DIR/keys/jwt.hex"
        log "Created keys/jwt.hex"
    fi

    ORCHESTRA_ENV_FILE="$ENV_FILE" "$PROJECT_DIR/scripts/dev/setup-repos.sh"
    load_env
    setup_aux_repo "${SAFE_TRANSACTION_SERVICE_REPO_URL:-}" "${SAFE_TRANSACTION_SERVICE_BRANCH:-main}"
    setup_aux_repo "${FOUNDRY_REPO_URL:-}" "${FOUNDRY_BRANCH:-main}"
}

cmd_up() {
    compose --profile kaspad up -d --build execution-layer kaspad
}

cmd_miner() {
    load_env
    [[ -n "${MINING_ADDRESS:-}" ]] || die "MINING_ADDRESS is empty in $ENV_FILE"
    compose --profile kaspa-miner up -d --build kaspa-miner
}

cmd_wait_daa() {
    load_env
    local target="${1:-1000}"
    local sleep_seconds="${KASPA_EXIT_DEVNET_POLL_SECONDS:-10}"
    local daa

    log "Waiting for Kaspa virtual DAA >= $target"
    while true; do
        daa="$(kaspa_virtual_daa || true)"
        if [[ "$daa" =~ ^[0-9]+$ ]]; then
            log "Kaspa virtual DAA: $daa"
            if (( daa >= target )); then
                return 0
            fi
        else
            log "Kaspa JSON RPC not ready yet"
        fi
        sleep "$sleep_seconds"
    done
}

cmd_wait_igra() {
    load_env
    local target="${1:-1}"
    local target_decimal
    target_decimal="$(to_decimal_block "$target")"
    local sleep_seconds="${KASPA_EXIT_DEVNET_POLL_SECONDS:-10}"
    local block_hex
    local block_decimal

    log "Waiting for Igra eth_blockNumber >= $target_decimal"
    while true; do
        block_hex="$(igra_block_hex || true)"
        if [[ "$block_hex" == 0x* || "$block_hex" == 0X* ]]; then
            block_decimal="$(to_decimal_block "$block_hex")"
            log "Igra block: $block_hex ($block_decimal)"
            if (( block_decimal >= target_decimal )); then
                return 0
            fi
        else
            log "Igra EL RPC not ready yet"
        fi
        sleep "$sleep_seconds"
    done
}

cmd_status() {
    compose ps
    load_env
    echo
    echo "Kaspa DAG:"
    kaspa_dag_info || true
    echo
    echo "Igra eth_blockNumber:"
    igra_block_hex || true
}

cmd_logs() {
    if [[ $# -gt 0 ]]; then
        compose logs -f --tail=200 "$@"
    else
        compose logs -f --tail=200
    fi
}

cmd_config() {
    compose --profile kaspad --profile kaspa-miner --profile kaspa-exit-e2e config "$@"
}

cmd_real_spend_e2e() {
    ORCHESTRA_ENV_FILE="$ENV_FILE" "$PROJECT_DIR/scripts/dev/kaspa-exit-real-spend-e2e.sh" "$@"
}

cmd_bootstrap() {
    cmd_setup
    cmd_up
    cmd_miner
    cmd_wait_daa 1000
    cmd_wait_igra 1
}

main() {
    local command="${1:-}"
    if [[ -z "$command" || "$command" == "-h" || "$command" == "--help" ]]; then
        usage
        exit 0
    fi
    shift || true

    case "$command" in
        setup) cmd_setup "$@" ;;
        up) cmd_up "$@" ;;
        miner) cmd_miner "$@" ;;
        real-spend-e2e) cmd_real_spend_e2e "$@" ;;
        bootstrap) cmd_bootstrap "$@" ;;
        wait-daa) cmd_wait_daa "$@" ;;
        wait-igra) cmd_wait_igra "$@" ;;
        status) cmd_status "$@" ;;
        logs) cmd_logs "$@" ;;
        down) compose down "$@" ;;
        config) cmd_config "$@" ;;
        *) usage >&2; exit 2 ;;
    esac
}

main "$@"
