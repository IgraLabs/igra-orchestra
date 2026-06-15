#!/bin/bash
# setup-devnet.sh - Interactive setup script for IGRA Devnet
#
# Single-node devnet with configurable finality period. Generates kaspad
# override-params JSON setting finality_depth from FINALITY_PERIOD_SECONDS,
# builds the stack from source, and runs the shared setup in setup-common.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Environment-specific configuration (used by sourced setup-common.sh)
# shellcheck disable=SC2034
ENV_NAME="Devnet"
# shellcheck disable=SC2034
ENV_FILE=".env.devnet.example"
# shellcheck disable=SC2034
NODE_ID_PREFIX="DEV-"
# shellcheck disable=SC2034
KASWALLET_FLAG="--devnet"

# No upstream RPC load balancer on devnet; allow operator override.
# shellcheck disable=SC2034
RPC_LB_HOSTNAME="${RPC_LB_HOSTNAME:-}"

# Version file for this network
# shellcheck disable=SC2034
VERSIONS_FILE="versions.devnet.env"

# Use the devnet-only compose file. Docker Compose honors COMPOSE_FILE.
export COMPOSE_FILE="docker-compose.devnet.yml"

# Single worker by default (devnet runs only kaswallet-0 / rpc-provider-0).
export NUM_WORKERS="${NUM_WORKERS:-1}"

# Generate kaspad override-params JSON. Default: 600s finality (= 6000-block depth at BPS=10).
FINALITY_PERIOD_SECONDS="${FINALITY_PERIOD_SECONDS:-600}"

generate_devnet_overrides() {
    local seconds="$1"
    # Upper bound = pruning_depth (1080000) / BPS (10) = 108000s.
    if ! [[ "$seconds" =~ ^[0-9]+$ ]] || (( seconds < 60 )) || (( seconds > 108000 )); then
        echo "ERROR: FINALITY_PERIOD_SECONDS must be an integer in [60, 108000] (got: $seconds)" >&2
        exit 1
    fi
    local depth=$(( seconds * 10 ))   # BPS=10 on devnet
    local out_dir="$SCRIPT_DIR/../overrides"
    mkdir -p "$out_dir"
    # blockrate mirrors the kaspad devnet defaults; only finality_depth is tuned.
    # crescendo_activation=0 keeps post-Crescendo consensus active from genesis.
    cat > "$out_dir/devnet.json" <<EOF
{
  "blockrate": {
    "target_time_per_block": 100,
    "ghostdag_k": 124,
    "past_median_time_sample_rate": 10,
    "difficulty_sample_rate": 2,
    "max_block_parents": 16,
    "mergeset_size_limit": 248,
    "merge_depth": 36000,
    "finality_depth": $depth,
    "pruning_depth": 1080000,
    "coinbase_maturity": 200
  },
  "crescendo_activation": 0
}
EOF
    echo "[setup-devnet] Generated overrides/devnet.json: finality_depth=$depth (= ${seconds}s at 10 BPS)"
}

generate_devnet_overrides "$FINALITY_PERIOD_SECONDS"

# Build the stack from source. kaspad's --override-params-file is only on the
# rusty-kaspa-private v3.0 line, which is not published to Docker Hub. Clone the
# sources first with:
#   KASPAD_BRANCH=v3.0 KASWALLET_BRANCH=v3.0 IGRA_RPC_PROVIDER_BRANCH=v3.0 \
#     ./scripts/dev/setup-repos.sh
build_devnet_stack() {
    local repos_dir="$SCRIPT_DIR/../build/repos"
    local missing=()
    local r
    for r in rusty-kaspa-private reth-private kaswallet igra-rpc-provider; do
        [ -d "$repos_dir/$r" ] || missing+=("$r")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: source repos not found under build/repos: ${missing[*]}" >&2
        echo "       Clone them first (kaspad/kaswallet/rpc-provider on v3.0):" >&2
        echo "         KASPAD_BRANCH=v3.0 KASWALLET_BRANCH=v3.0 IGRA_RPC_PROVIDER_BRANCH=v3.0 \\" >&2
        echo "           ./scripts/dev/setup-repos.sh" >&2
        exit 1
    fi

    # --override-params-file exists only on the v3.0 line; without it kaspad
    # crash-loops on the unknown argument at runtime.
    local kaspad_args="$repos_dir/rusty-kaspa-private/kaspad/src/args.rs"
    if ! grep -q 'override-params-file' "$kaspad_args" 2>/dev/null; then
        echo "ERROR: kaspad sources do not support --override-params-file." >&2
        echo "       Check out v3.0 in build/repos/rusty-kaspa-private:" >&2
        echo "         (cd build/repos/rusty-kaspa-private && git checkout v3.0)" >&2
        exit 1
    fi

    echo "[setup-devnet] Building devnet images from source (first build is slow)..."
    # Export the inputs the compose file references so `docker compose build` can
    # interpolate it and tag images as igranetwork/<svc>:devnet. run_setup writes
    # .env later; source the same inputs here.
    set -a
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/../$ENV_FILE"
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/../$VERSIONS_FILE"
    set +a
    # kaspa-miner is excluded; it builds on demand under the "mining" profile.
    docker compose build kaspad execution-layer kaswallet-0 rpc-provider-0
}

build_devnet_stack

# Pre-create bind-mount targets so Docker does not auto-create them root-owned,
# which would block reth from writing its data dir and auth.ipc socket.
mkdir -p "$SCRIPT_DIR/../data/reth" \
         "$SCRIPT_DIR/../data/reth-ipc" \
         "$SCRIPT_DIR/../network-params" \
         "$SCRIPT_DIR/../logs/kaspad"

# Source common library and run setup
source "$SCRIPT_DIR/lib/setup-common.sh"
run_setup "$@"

# kaspa-miner is gated behind the "mining" profile and built on demand.
cat <<EOF

=== Devnet: Mining ===

Start the in-stack kaspa-miner once kaspad is healthy:

  docker compose -f docker-compose.devnet.yml --profile mining up -d --build kaspa-miner
  docker compose -f docker-compose.devnet.yml logs -f kaspa-miner

Stop with: docker compose -f docker-compose.devnet.yml --profile mining down
EOF
