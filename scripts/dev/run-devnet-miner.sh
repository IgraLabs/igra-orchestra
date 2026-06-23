#!/bin/bash
# run-devnet-miner.sh - Set up and run a standalone kaspa-miner against the local
# IGRA devnet, outside the docker-compose stack. Clones and builds
# tmrlvi/kaspa-miner once, then runs it on the host against the devnet kaspad gRPC
# port. Reads MINING_ADDRESS / MINING_THREADS / KASPAD_GRPC_PORT from .env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Reuse predicates (is_port, is_positive_int, is_valid_mining_address).
# shellcheck source=scripts/lib/devnet-preflight.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/devnet-preflight.sh"

log()  { echo "[run-devnet-miner] $*"; }
warn() { echo "[run-devnet-miner] WARNING: $*" >&2; }
die()  { echo "[run-devnet-miner] ERROR: $*" >&2; exit 1; }

print_help() {
    cat <<'EOF'
Usage: ./scripts/dev/run-devnet-miner.sh [--help]

Clones and builds tmrlvi/kaspa-miner (once) and runs it against the local devnet
kaspad gRPC port. Runs in the foreground; press Ctrl+C to stop.

Configuration is read from .env (or .env.devnet.example if there is no .env);
shell/CLI values take precedence over the file.

Environment variables:
  MINING_ADDRESS          Reward address; must be a devnet address (kaspadev:...).
  MINING_THREADS          CPU miner threads (positive integer). Default: 1.
  KASPAD_GRPC_PORT        Devnet kaspad gRPC port on the host. Default: 16610.
  KASPAD_RPC_HOST         Host the miner dials. Default: 127.0.0.1 (NOT the
                          compose-internal KASPAD_HOST, which is unreachable here).
  MINE_WHEN_NOT_SYNCED    true|false. Default: true (a fresh single-node devnet
                          reports "not synced"; pass the flag so it still mines).

  MINER_REPO_URL          Default: https://github.com/tmrlvi/kaspa-miner.git
  MINER_BRANCH            Branch/tag to clone. Default: repo default branch.
  MINER_DIR               Clone/build location.
                          Default: build/repos/tmrlvi-kaspa-miner
  MINER_BUILD_GPU         auto|on|off. Default: auto (build GPU crates when CUDA/
                          OpenCL toolchains are detected, fall back to CPU-only on
                          build failure; otherwise build CPU-only directly).
  MINER_EXTRA_ARGS        Extra flags appended verbatim to the miner invocation.
  SKIP_BUILD=1            Reuse an existing release binary; skip clone/build.

Examples:
  ./scripts/dev/run-devnet-miner.sh
  MINING_THREADS=4 ./scripts/dev/run-devnet-miner.sh
  MINER_BUILD_GPU=off SKIP_BUILD=1 ./scripts/dev/run-devnet-miner.sh
EOF
}

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    print_help
    exit 0
fi

# --- resolve config (shell/CLI > .env > .env.devnet.example > default) ---
ENV_FILE="$PROJECT_DIR/.env"
[ -f "$ENV_FILE" ] || ENV_FILE="$PROJECT_DIR/.env.devnet.example"

# read_env KEY -> prints the trimmed, unquoted value from ENV_FILE; returns 1 if absent.
read_env() {
    local key="$1" line val found=1
    [ -f "$ENV_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            "$key"=*)
                val="${line#*=}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                case "$val" in
                    \"*\"|\'*\') val="${val:1:${#val}-2}" ;;
                esac
                found=0
                ;;
        esac
    done < "$ENV_FILE"
    [ "$found" -eq 0 ] && printf '%s' "$val"
    return "$found"
}

# resolve NAME DEFAULT -> sets NAME from shell (if already set) else file else default.
resolve() {
    local name="$1" default="$2" val
    [ -n "${!name+set}" ] && return 0
    if val="$(read_env "$name")"; then
        printf -v "$name" '%s' "$val"
    else
        printf -v "$name" '%s' "$default"
    fi
}

[ -f "$ENV_FILE" ] && log "Reading config from $ENV_FILE (shell overrides win)"

resolve MINING_ADDRESS ""
resolve MINING_THREADS 1
resolve KASPAD_GRPC_PORT 16610
# Host loopback, not the compose-internal KASPAD_HOST (=kaspad).
KASPAD_RPC_HOST="${KASPAD_RPC_HOST:-127.0.0.1}"
MINE_WHEN_NOT_SYNCED="${MINE_WHEN_NOT_SYNCED:-true}"

MINER_REPO_URL="${MINER_REPO_URL:-https://github.com/tmrlvi/kaspa-miner.git}"
MINER_BRANCH="${MINER_BRANCH:-}"
MINER_DIR="${MINER_DIR:-$PROJECT_DIR/build/repos/tmrlvi-kaspa-miner}"
MINER_BUILD_GPU="${MINER_BUILD_GPU:-auto}"
MINER_EXTRA_ARGS="${MINER_EXTRA_ARGS:-}"

BIN="$MINER_DIR/target/release/kaspa-miner"

# --- validate ---
command -v git >/dev/null 2>&1 || die "git not found"
is_valid_mining_address "$MINING_ADDRESS" || \
    die "MINING_ADDRESS must be a devnet address (kaspadev:...) (got: '${MINING_ADDRESS:-<unset>}'). Set it in .env or pass MINING_ADDRESS=..."
is_positive_int "$MINING_THREADS" || \
    die "MINING_THREADS must be a positive integer (got: '${MINING_THREADS:-<unset>}')"
is_port "$KASPAD_GRPC_PORT" || \
    die "KASPAD_GRPC_PORT must be an integer in 1-65535 (got: '${KASPAD_GRPC_PORT:-<unset>}')"
case "$MINER_BUILD_GPU" in auto|on|off) ;; *) die "MINER_BUILD_GPU must be auto|on|off (got: '$MINER_BUILD_GPU')" ;; esac

# --- clone + build (unless SKIP_BUILD reuses an existing binary) ---
has_opencl() {
    command -v clinfo >/dev/null 2>&1 || [ -d /etc/OpenCL/vendors ]
}

build_miner() {
    command -v cargo >/dev/null 2>&1 || \
        die "cargo (Rust toolchain) not found; needed to build the miner. Install via https://rustup.rs, or set SKIP_BUILD=1 to reuse an existing binary."

    if [ ! -d "$MINER_DIR/.git" ]; then
        log "Cloning $MINER_REPO_URL -> $MINER_DIR"
        if [ -n "$MINER_BRANCH" ]; then
            git clone --depth 1 --branch "$MINER_BRANCH" "$MINER_REPO_URL" "$MINER_DIR"
        else
            git clone --depth 1 "$MINER_REPO_URL" "$MINER_DIR"
        fi
    else
        log "Reusing existing clone at $MINER_DIR"
    fi

    local want_gpu=false
    case "$MINER_BUILD_GPU" in
        on) want_gpu=true ;;
        off) want_gpu=false ;;
        auto)
            if command -v nvcc >/dev/null 2>&1 || has_opencl; then
                want_gpu=true
                log "GPU toolchain detected; attempting GPU build (will fall back to CPU-only on failure)."
            else
                log "No CUDA/OpenCL toolchain detected; building CPU-only."
            fi
            ;;
    esac

    log "Building kaspa-miner (release)..."
    if $want_gpu; then
        if cargo build --release --manifest-path "$MINER_DIR/Cargo.toml" \
                -p kaspa-miner -p kaspacuda -p kaspaopencl; then
            return 0
        fi
        warn "GPU build failed; retrying CPU-only."
    fi
    cargo build --release --manifest-path "$MINER_DIR/Cargo.toml" -p kaspa-miner
}

if [ "${SKIP_BUILD:-}" = "1" ]; then
    [ -x "$BIN" ] || die "SKIP_BUILD=1 but no binary at $BIN; unset SKIP_BUILD to clone and build it."
    log "SKIP_BUILD=1; reusing existing binary $BIN"
else
    build_miner
    [ -x "$BIN" ] || die "miner binary not found at $BIN after build"
fi

# --- preflight: is the devnet kaspad reachable? (non-fatal; the miner retries) ---
if timeout 2 bash -c ": > /dev/tcp/$KASPAD_RPC_HOST/$KASPAD_GRPC_PORT" 2>/dev/null; then
    log "devnet kaspad gRPC reachable at $KASPAD_RPC_HOST:$KASPAD_GRPC_PORT"
else
    warn "devnet kaspad gRPC not reachable at $KASPAD_RPC_HOST:$KASPAD_GRPC_PORT yet."
    warn "Start the stack first (./scripts/setup-devnet.sh); the miner will keep retrying."
fi

# --- run (foreground; Ctrl+C stops) ---
args=(-a "$MINING_ADDRESS" -s "$KASPAD_RPC_HOST" -p "$KASPAD_GRPC_PORT" -t "$MINING_THREADS")
[ "$MINE_WHEN_NOT_SYNCED" = "true" ] && args+=(--mine-when-not-synced)

log "Starting miner -> $KASPAD_RPC_HOST:$KASPAD_GRPC_PORT (address ${MINING_ADDRESS}, ${MINING_THREADS} threads)"
log "Press Ctrl+C to stop."
# Word-split MINER_EXTRA_ARGS so callers can pass multiple flags.
# shellcheck disable=SC2086
exec "$BIN" "${args[@]}" $MINER_EXTRA_ARGS
