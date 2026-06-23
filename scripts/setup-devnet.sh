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

PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=scripts/lib/devnet-preflight.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/devnet-preflight.sh"

# Load the single effective env source (.env or template) + versions so
# validation and the build read identical inputs. Shell overrides win.
resolve_devnet_env "$PROJECT_DIR" "$ENV_FILE" "$VERSIONS_FILE" || exit 1

# Tunable defaults applied on top of the resolved env so:
#   shell override > .env file > default.
# Use ${VAR-default} (not :-) for TOCCATA/LANE so an explicit empty opts out.
FINALITY_PERIOD_SECONDS="${FINALITY_PERIOD_SECONDS:-600}"
TOCCATA_ACTIVATION_DAA_SCORE="${TOCCATA_ACTIVATION_DAA_SCORE-1000}"
IGRA_LANE_ID="${IGRA_LANE_ID-97b10000}"
export FINALITY_PERIOD_SECONDS TOCCATA_ACTIVATION_DAA_SCORE IGRA_LANE_ID

generate_devnet_overrides() {
    local seconds="$1"
    local toccata="$2"
    # FINALITY_PERIOD_SECONDS range is validated upstream in validate_devnet_env.
    local depth=$(( seconds * 10 ))   # BPS=10 on devnet
    local out_dir="$SCRIPT_DIR/../overrides"
    mkdir -p "$out_dir"
    # blockrate mirrors the kaspad devnet defaults; only finality_depth is tuned.
    # crescendo_activation=0 keeps post-Crescendo consensus active from genesis.
    # toccata_activation is appended as the last field only when scheduled, so the
    # JSON has no trailing comma when Toccata is disabled (empty score).
    local toccata_line=""
    if [ -n "$toccata" ]; then
        toccata_line=",
  \"toccata_activation\": $toccata"
    fi
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
  "crescendo_activation": 0$toccata_line
}
EOF
    if [ -n "$toccata" ]; then
        echo "[setup-devnet] Generated overrides/devnet.json: finality_depth=$depth (= ${seconds}s at 10 BPS), toccata_activation=$toccata"
    else
        echo "[setup-devnet] Generated overrides/devnet.json: finality_depth=$depth (= ${seconds}s at 10 BPS), toccata_activation disabled (never)"
    fi
}

# finality_depth is baked into kaspad's consensus DB on first run and lives in the
# kaspad_data named volume; --override-params-file only applies to a fresh DB. Warn
# loudly when a volume already exists so a changed FINALITY_PERIOD_SECONDS does not
# silently keep the old finality. Project name matches `name:` in the compose file.
warn_if_finality_baked() {
    local volume="igra-devnet_kaspad_data"
    if docker volume inspect "$volume" >/dev/null 2>&1; then
        cat >&2 <<EOF

WARNING: existing kaspad volume '$volume' found.
         Consensus override params (finality_depth, toccata_activation) are baked
         into the consensus DB on first run; re-running setup with a different
         FINALITY_PERIOD_SECONDS or TOCCATA_ACTIVATION_DAA_SCORE will NOT take effect
         until the volume is wiped. To apply new values:

           docker compose -f docker-compose.devnet.yml down -v

         (this destroys the local chain). Continuing reuses the existing finality.

EOF
    fi
}

# Fail fast on bad config BEFORE any expensive build/up.
validate_devnet_env || exit 1

# Record exactly what will be built (one manifest per rehearsal).
record_source_revisions "$PROJECT_DIR/build/repos" "$PROJECT_DIR/rehearsals"

# When Toccata is scheduled, validate the mining config and remind the operator to
# start an external miner (required to reach the activation DAA score).
if [ -n "${TOCCATA_ACTIVATION_DAA_SCORE:-}" ]; then
    mining_preflight || exit 1
fi

generate_devnet_overrides "$FINALITY_PERIOD_SECONDS" "$TOCCATA_ACTIVATION_DAA_SCORE"
warn_if_finality_baked

# Build the stack from source. kaspad's --override-params-file is only on the
# rusty-kaspa-private v3.0 line, which is not published to Docker Hub. Clone the
# sources first with:
#   KASPAD_BRANCH=v3.0 KASWALLET_BRANCH=v3.0 IGRA_RPC_PROVIDER_BRANCH=v3.0 \
#     ./scripts/dev/setup-repos.sh
build_devnet_stack() {
    local repos_dir="$SCRIPT_DIR/../build/repos"
    local missing=()
    local r
    # The miner is not built from this repo (operators run their own); only the
    # four core services are required here.
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
    if [[ ! -f "$kaspad_args" ]]; then
        echo "ERROR: expected kaspad args file not found at $kaspad_args" >&2
        echo "       The repo layout may have changed; verify build/repos/rusty-kaspa-private." >&2
        exit 1
    fi
    if ! grep -q 'override-params-file' "$kaspad_args"; then
        echo "ERROR: kaspad sources do not support --override-params-file." >&2
        echo "       Check out v3.0 in build/repos/rusty-kaspa-private:" >&2
        echo "         (cd build/repos/rusty-kaspa-private && git checkout v3.0)" >&2
        exit 1
    fi

    echo "[setup-devnet] Building devnet images from source (first build is slow)..."
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
# shellcheck source=scripts/lib/setup-common.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/setup-common.sh"

# The devnet stack uses distinct container names (*-devnet) to stay isolated from
# the production stack. The shared readiness/stats helpers inspect the production
# container names, so override them here to target the devnet containers.
wait_for_backend_readiness() {
    log "Waiting for backend services to become ready..."
    wait_for_container_ready execution-layer-devnet 300 || return 1
    wait_for_container_ready kaspad-devnet 300 || return 1
}

show_live_stats() {
    echo "Your node is now running in the background."
    echo
    if prompt_confirm "Would you like to see live sync progress and block building stats?" "y"; then
        echo
        log "Showing sync progress (IBD/UTXO) and block building stats..."
        log "Press Ctrl+C at any time to exit - your node will continue running."
        echo
        trap 'echo; log "Stats viewer stopped."; return 0' INT
        docker logs -f -n 10 kaspad-devnet 2>&1 | \
            tee >(grep --line-buffered -E "IBD|UTXO" | sed -u 's/^/[Kaspa Sync] /' >&2) | \
            docker run --rm -i --entrypoint /app/adapter-stats "$KASPAD_IMAGE" || true
        trap - INT
    fi
}

# Devnet-specific summary: the shared print_summary points at services this stack
# does not run (e.g. node-health-check-client). Override it after sourcing so the
# post-setup guidance only references devnet services.
print_summary() {
    echo "========================================"
    echo "  Devnet Setup Complete!"
    echo "========================================"
    echo
    echo "Services started:"
    docker compose ps --format "table {{.Name}}\t{{.Status}}"
    echo
    echo "NOTE: kaspad mines no blocks on its own. Point an external miner at the"
    echo "      devnet kaspad gRPC port to produce blocks (see below)."
    echo
    echo "Useful commands:"
    echo "  docker compose -f $COMPOSE_FILE logs -f kaspad           # kaspad"
    echo "  docker compose -f $COMPOSE_FILE logs -f execution-layer  # execution layer"
    echo "  docker compose -f $COMPOSE_FILE logs -f kaswallet-0      # kaswallet"
    echo "  docker compose -f $COMPOSE_FILE logs -f rpc-provider-0   # RPC provider"
    echo "  docker stats                                             # resource usage"
    echo
    echo "RPC (eth_*) is bound to ${RPC_BIND_ADDR:-127.0.0.1}:${RPC_PORT:-8555}, read-only by"
    echo "default (RPC_READ_ONLY=true). Set RPC_READ_ONLY=false in .env to enable writes."
    echo
}

run_setup "$@"

# The miner is not part of this stack; operators run their own against the
# published devnet kaspad gRPC port.
cat <<EOF

=== Devnet: Mining ===

kaspad mines no blocks on its own. The miner is not part of this stack; a helper
clones, builds and runs tmrlvi/kaspa-miner on the host against the devnet kaspad
gRPC port. Run it once kaspad is healthy:

  ./scripts/dev/run-devnet-miner.sh

It reads MINING_ADDRESS / MINING_THREADS / KASPAD_GRPC_PORT from your .env; see
'./scripts/dev/run-devnet-miner.sh --help' for options.
Mining is required to reach TOCCATA_ACTIVATION_DAA_SCORE for the KIP-21 rehearsal.
EOF
