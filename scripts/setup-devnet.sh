#!/bin/bash
# setup-devnet.sh - Interactive setup script for IGRA Devnet
#
# Single-node devnet with configurable finality period.
# Generates kaspad override-params JSON to dial finality_depth down from the
# 12-hour devnet default to FINALITY_PERIOD_SECONDS (default 600).
# For implementation details, see scripts/lib/setup-common.sh.

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
    # Upper bound matches kaspad's finality_depth=1080000 pruning depth: at BPS=10
    # that is 108000s (~30h). Beyond this kaspad would reject the override.
    if ! [[ "$seconds" =~ ^[0-9]+$ ]] || (( seconds < 60 )) || (( seconds > 108000 )); then
        echo "ERROR: FINALITY_PERIOD_SECONDS must be an integer in [60, 108000] (got: $seconds)" >&2
        exit 1
    fi
    local depth=$(( seconds * 10 ))   # BPS=10 on devnet
    local out_dir="$SCRIPT_DIR/../overrides"
    mkdir -p "$out_dir"
    # blockrate values mirror the kaspad devnet built-in defaults; only
    # finality_depth is operator-tunable via FINALITY_PERIOD_SECONDS.
    # crescendo_activation=0 keeps post-Crescendo consensus active from
    # genesis (devnet has no historical pre-Crescendo blocks to honor).
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

# Source common library and run setup
source "$SCRIPT_DIR/lib/setup-common.sh"
run_setup "$@"

# kaspa-miner is gated behind the "mining" profile so setup's `--profile backend up -d --no-build`
# does not try to pull/start it before it has been built. Print the start command for the operator.
cat <<EOF

=== Devnet: Mining ===

Devnet has no external miners. To start the in-stack kaspa-miner once kaspad is healthy:

  docker compose --profile mining up -d --build kaspa-miner
  docker compose logs -f kaspa-miner

Stop with: docker compose --profile mining down
EOF
