#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="${ORCHESTRA_ENV_FILE:-$PROJECT_DIR/.env.kaspa-exit-devnet}"
if [[ "$ENV_FILE" != /* ]]; then
    ENV_FILE="$PROJECT_DIR/$ENV_FILE"
fi

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

load_env() {
    [[ -f "$ENV_FILE" ]] || die "Env file not found at $ENV_FILE. Run setup first."
    set -a
    # shellcheck source=/dev/null
    source "$ENV_FILE"
    set +a

    COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-igra-kaspa-exit-devnet}"
    KASPA_EXIT_DEVNET_CONTAINER_PREFIX="${KASPA_EXIT_DEVNET_CONTAINER_PREFIX:-$COMPOSE_PROJECT_NAME}"
    NETWORK="${NETWORK:-devnet}"
    KASPA_E2E_SIGNERS="${KASPA_E2E_SIGNERS:-3}"
    KASPA_E2E_THRESHOLD="${KASPA_E2E_THRESHOLD:-2}"
    WALLET_PASSWORD="${WALLET_PASSWORD:-stage-msig-pass}"
}

compose() {
    docker compose \
        -p "$COMPOSE_PROJECT_NAME" \
        --env-file "$ENV_FILE" \
        -f "$PROJECT_DIR/docker-compose.yml" \
        -f "$PROJECT_DIR/docker-compose.kaspa-exit-devnet.yml" \
        "$@"
}

wallet_exec() {
    compose --profile kaspad --profile kaspa-exit-e2e exec -T kaspa-wallet-tools "$@"
}

parse_kaspa_address() {
    awk '/^kaspa/ || /^kaspadev/ || /^kaspatest/ { value=$1 } END { if (value != "") print value }'
}

wait_wallet_daemons() {
    log "Waiting for signer wallet daemons"
    wallet_exec bash -lc '
        set -euo pipefail
        for index in 0 1 2; do
          port=$((8082 + index))
          for attempt in $(seq 1 180); do
            if kaspawallet --devnet balance --daemonaddress "127.0.0.1:${port}" >/tmp/wallet-${index}.out 2>/tmp/wallet-${index}.err; then
              break
            fi
            sleep 1
            if [[ "$attempt" == "180" ]]; then
              echo "wallet daemon ${index} did not become ready" >&2
              cat "/tmp/wallet-${index}.err" >&2 || true
              exit 1
            fi
          done
        done
    '
}

main() {
    require_cmd docker
    require_cmd jq

    if [[ -f "$ENV_FILE" ]]; then
        load_env
    fi

    if [[ "${KASPA_E2E_SKIP_SETUP:-false}" != "true" ]]; then
        ORCHESTRA_ENV_FILE="$ENV_FILE" "$PROJECT_DIR/scripts/dev/kaspa-exit-devnet.sh" setup
        load_env
    else
        load_env
        log "Skipping repository setup because KASPA_E2E_SKIP_SETUP=true"
    fi

    mkdir -p "$PROJECT_DIR/build/kaspa-exit-devnet/wallets" \
        "$PROJECT_DIR/build/kaspa-exit-devnet/logs" \
        "$PROJECT_DIR/build/kaspa-exit-devnet/results"

    log "Building Kaspa wallet tools and safe-service API images"
    compose --profile kaspad --profile kaspa-exit-e2e build --no-deps kaspa-wallet-tools kaspa-safe-api

    if [[ ! -f "$PROJECT_DIR/build/kaspa-exit-devnet/wallets/metadata.json" ]]; then
        log "Creating ${KASPA_E2E_THRESHOLD}-of-${KASPA_E2E_SIGNERS} signer wallet fixture"
        compose --profile kaspad --profile kaspa-exit-e2e run --rm --no-deps \
            --entrypoint /usr/local/bin/kaspa-msig-fixture \
            kaspa-wallet-tools create \
            --network "$NETWORK" \
            --out-dir /work/wallets \
            --password "$WALLET_PASSWORD" \
            --threshold "$KASPA_E2E_THRESHOLD" \
            --signers "$KASPA_E2E_SIGNERS"
    else
        log "Reusing build/kaspa-exit-devnet/wallets/metadata.json"
    fi

    log "Starting kaspad, execution-layer, signer wallet tools, and safe-service"
    up_args=(up -d)
    if [[ "${KASPA_E2E_BUILD_CORE_SERVICES:-true}" == "true" ]]; then
        up_args+=(--build)
    fi
    compose --profile kaspad --profile kaspa-exit-e2e "${up_args[@]}" \
        execution-layer kaspad kaspa-safe-db kaspa-safe-redis kaspa-safe-api kaspa-wallet-tools

    wait_wallet_daemons

    metadata="$PROJECT_DIR/build/kaspa-exit-devnet/wallets/metadata.json"
    canonical_index="$(jq -r '.signers[] | select(.cosignerIndex == 0) | .index' "$metadata")"
    canonical_port="$((8082 + canonical_index))"

    custody_address="$(jq -r '.custodyAddress // empty' "$metadata")"
    if [[ -z "$custody_address" || "$custody_address" == "null" ]]; then
        log "Creating canonical custody address from signer ${canonical_index}"
        custody_output="$(wallet_exec kaspawallet --devnet new-address --daemonaddress "127.0.0.1:${canonical_port}")"
        custody_address="$(printf '%s\n' "$custody_output" | parse_kaspa_address)"
        [[ -n "$custody_address" ]] || die "Could not parse custody address from: $custody_output"

        tmp_metadata="${metadata}.tmp"
        jq --arg custody "$custody_address" '.custodyAddress = $custody' "$metadata" > "$tmp_metadata"
        mv "$tmp_metadata" "$metadata"
    fi

    log "Starting miner against custody address $custody_address"
    export MINING_ADDRESS="$custody_address"
    compose --profile kaspa-miner up -d --build --force-recreate kaspa-miner

    log "Running real-spend proposal/sign/broadcast test"
    wallet_exec /app/kaspa-exit-real-spend-in-container.sh

    log "Real-spend e2e result"
    cat "$PROJECT_DIR/build/kaspa-exit-devnet/results/e2e-result.json"
}

main "$@"
