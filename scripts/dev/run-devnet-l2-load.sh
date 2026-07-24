#!/usr/bin/env bash
# Drive the full IGRA devnet L2 stack under load and bootstrap L2 funds via an
# L1->L2 Entry deposit. Dev harness — not for CI/commit.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$ROOT_DIR"

# --- config (shell env overrides) -------------------------------------------
IGRA_E2E_DIR="${IGRA_E2E_DIR:-$ROOT_DIR/../igra-e2e-validation}"
LOADGEN_RATE="${LOADGEN_RATE:-20}"
LOADGEN_CONCURRENCY="${LOADGEN_CONCURRENCY:-4}"
LOADGEN_DURATION="${LOADGEN_DURATION:-300}"
DEPOSIT_KAS_OVERRIDE="${DEPOSIT_KAS:-}"
RUN_DIR="${RUN_DIR:-$ROOT_DIR/build/l2-load-$(date +%s)}"
FINALITY_OVERRIDE="${FINALITY_PERIOD_SECONDS:-}"
LAUNCH_DAA_OVERRIDE="${IGRA_LAUNCH_DAA_SCORE:-}"

set -a; [ -f "$ROOT_DIR/.env" ] && . "$ROOT_DIR/.env"; set +a
RPC_PORT="${RPC_PORT:-8555}"
FINALITY_PERIOD_SECONDS="${FINALITY_OVERRIDE:-60}"
L2_ALIVE_TIMEOUT_SECS="${L2_ALIVE_TIMEOUT_SECS:-900}"
IGRA_LAUNCH_DAA_SCORE="${LAUNCH_DAA_OVERRIDE:-10}"
GAS_GWEI="${MIN_PROTOCOL_FEE_PER_GAS_GWEI:-2000}"
DEPOSIT_KAS="$DEPOSIT_KAS_OVERRIDE"
if [ -z "$DEPOSIT_KAS" ]; then
    DEPOSIT_KAS=$(( (LOADGEN_RATE * LOADGEN_DURATION * 21000 * GAS_GWEI / 1000000000) * 3 / 2 + 10 ))
fi
W0_WALLET_TO_ADDRESS="${W0_WALLET_TO_ADDRESS:?set W0_WALLET_TO_ADDRESS in .env}"

log(){ echo "[l2-load] $*"; }

# --- 0. tool preflight ------------------------------------------------------
for t in docker jq cast websocat; do command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 2; }; done
[ -d "$IGRA_E2E_DIR" ] || { echo "IGRA_E2E_DIR not found: $IGRA_E2E_DIR" >&2; exit 2; }

mkdir -p "$RUN_DIR"

export IGRA_LAUNCH_DAA_SCORE FINALITY_PERIOD_SECONDS

# --- 0b. reconcile GENESIS_BLOCK_HASH with the EL this config builds ---------
log "probing the EL genesis hash for IGRA_LAUNCH_DAA_SCORE=$IGRA_LAUNCH_DAA_SCORE"
COMPOSE_PROFILES=backend docker compose -f docker-compose.devnet.yml up -d execution-layer \
    > "$RUN_DIR/genesis-probe.log" 2>&1
GENESIS_BLOCK_HASH=""
for _ in $(seq 1 60); do
    GENESIS_BLOCK_HASH="$(curl -s http://127.0.0.1:9545 -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_getBlockByNumber","params":["0x0",false]}' \
        | jq -r '.result.hash // empty' 2>/dev/null || true)"
    [ -n "$GENESIS_BLOCK_HASH" ] && break
    sleep 2
done
COMPOSE_PROFILES=backend docker compose -f docker-compose.devnet.yml down \
    >> "$RUN_DIR/genesis-probe.log" 2>&1
case "$GENESIS_BLOCK_HASH" in
    0x*) ;;
    *) echo "could not probe the EL genesis hash (see $RUN_DIR/genesis-probe.log)" >&2; exit 8 ;;
esac
export GENESIS_BLOCK_HASH
log "EL genesis is $GENESIS_BLOCK_HASH"

# --- 1. bring up the full stack ---------------------------------------------
log "bringing up full devnet stack (IGRA_ENABLE=true, RPC_READ_ONLY=false, skip-lock-check)"
SETUP_ANSWERS=$'\n\n\n\n\nn\n'
printf '%s' "$SETUP_ANSWERS" \
    | IGRA_ENABLE=true RPC_READ_ONLY=false IGRA_SKIP_LOCK_SCRIPT_CHECK=true \
      FINALITY_PERIOD_SECONDS="$FINALITY_PERIOD_SECONDS" "$ROOT_DIR/scripts/setup-devnet.sh"

setup_pw="$(awk -F= '$1 == "W0_KASWALLET_PASSWORD" { print $2; exit }' "$ROOT_DIR/.env" 2>/dev/null || true)"
[ -z "$setup_pw" ] || {
    echo "setup prompt answers desynced: W0_KASWALLET_PASSWORD is non-empty" >&2
    exit 4
}

# --- 2. start the throttled miner -------------------------------------------
resolve_kaswallet_container() { docker ps --format '{{.Names}}' | grep -m1 kaswallet-0 || true; }

log "resolving kaswallet-0's mining address"
MINING_ADDRESS=""
for _ in $(seq 1 30); do
    kaswallet_container="$(resolve_kaswallet_container)"
    if [ -n "$kaswallet_container" ]; then
        MINING_ADDRESS="$(docker exec "$kaswallet_container" /app/kaswallet-cli address-balances 2>/dev/null \
            | jq -r '.default_address // empty' 2>/dev/null || true)"
        [ -n "$MINING_ADDRESS" ] && break
    fi
    sleep 2
done
case "$MINING_ADDRESS" in
    kaspadev:*) ;;
    *) echo "could not resolve a devnet mining address from kaswallet-0 (got: '${MINING_ADDRESS:-<none>}')" >&2; exit 5 ;;
esac
export MINING_ADDRESS
log "mining to kaswallet-0's address $MINING_ADDRESS"

log "starting throttled CPU miner in background"
"$SCRIPT_DIR/run-devnet-cpuminer.sh" > "$RUN_DIR/miner.log" 2>&1 &
MINER_PID=$!
trap 'kill "$MINER_PID" 2>/dev/null || true' EXIT

# --- 3. wait for kaswallet-0 to hold matured, spendable KAS -----------------
log "waiting for kaswallet-0 to accumulate spendable balance (coinbase maturity)"
funded=false
for _ in $(seq 1 120); do
    kaswallet_container="$(resolve_kaswallet_container)"
    if [ -n "$kaswallet_container" ]; then
        bal="$(docker exec "$kaswallet_container" /app/kaswallet-cli address-balances 2>/dev/null \
            | jq -r '(.total_available // 0) / 100000000 | floor' 2>/dev/null || echo 0)"
    else
        bal=0
    fi
    [ "${bal:-0}" -ge $((DEPOSIT_KAS + 2)) ] 2>/dev/null && { log "kaswallet available >= $((DEPOSIT_KAS+2)) KAS"; funded=true; break; }
    sleep 5
done
[ "$funded" = true ] || {
    echo "kaswallet-0 never reached $((DEPOSIT_KAS + 2)) KAS (last seen: ${bal:-0} KAS)." >&2
    echo "Is the miner producing blocks, and is MINING_ADDRESS one this wallet controls?" >&2
    exit 6
}

# --- 3b. wait for the L2 to start producing blocks --------------------------
log "waiting for the L2 to produce its first block (first finality period must elapse)"
l2_alive=false
l2_deadline=$(( $(date +%s) + L2_ALIVE_TIMEOUT_SECS ))
while [ "$(date +%s)" -lt "$l2_deadline" ]; do
    head_hex="$(curl -s "http://127.0.0.1:${RPC_PORT}" -H 'content-type: application/json' \
        --data '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
        | jq -r '.result // "0x0"' 2>/dev/null || echo 0x0)"
    case "$head_hex" in
        0x0|null|'') ;;
        *) log "L2 head is $head_hex"; l2_alive=true; break ;;
    esac
    sleep 10
done
[ "$l2_alive" = true ] || {
    echo "L2 produced no blocks within ${L2_ALIVE_TIMEOUT_SECS}s (EL head still 0)." >&2
    echo "Check kaspad logs for 'Consensus fallback check failed' / ATAN cold-start waits." >&2
    exit 7
}

# --- 4. generate an L2 keypair ----------------------------------------------
cast wallet new --json > "$RUN_DIR/l2-key.json"
L2_ADDRESS="$(jq -r '.[0].address' "$RUN_DIR/l2-key.json")"
FUNDED_PRIVATE_KEY="$(jq -r '.[0].private_key' "$RUN_DIR/l2-key.json")"
log "generated L2 account $L2_ADDRESS"

# --- 5. L1->L2 Entry deposit ------------------------------------------------
log "depositing $DEPOSIT_KAS KAS -> iKAS to $L2_ADDRESS"
docker exec "$(docker ps --format '{{.Names}}' | grep -m1 rpc-provider-0)" \
    /app/entry_transaction_sender \
    --recipient "$W0_WALLET_TO_ADDRESS" \
    --amount "$DEPOSIT_KAS" \
    --l2-address "$L2_ADDRESS" | tee "$RUN_DIR/deposit.log"

# --- 6. wait for the L2 balance to be credited ------------------------------
log "waiting for L2 balance to appear"
for _ in $(seq 1 60); do
    hexbal="$(curl -s "http://127.0.0.1:${RPC_PORT}" -H 'content-type: application/json' \
        --data "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$L2_ADDRESS\",\"latest\"]}" \
        | jq -r '.result // "0x0"' 2>/dev/null || echo 0x0)"
    [ "$hexbal" != "0x0" ] && [ "$hexbal" != "null" ] && { log "L2 balance = $hexbal"; break; }
    sleep 5
done
[ "${hexbal:-0x0}" = "0x0" ] && { echo "L2 deposit never credited" >&2; exit 3; }

# --- 7. build + run loadgen -------------------------------------------------
log "building loadgen"
cargo build --release --manifest-path "$IGRA_E2E_DIR/Cargo.toml" -p loadgen
LOADGEN_BIN="$IGRA_E2E_DIR/target/release/loadgen"
log "running loadgen: rate=$LOADGEN_RATE conc=$LOADGEN_CONCURRENCY dur=${LOADGEN_DURATION}s"
mkdir -p "$RUN_DIR/loadgen"
FUNDED_PRIVATE_KEY="$FUNDED_PRIVATE_KEY" "$LOADGEN_BIN" \
    --rpc-url "http://127.0.0.1:${RPC_PORT}" \
    --rate "$LOADGEN_RATE" \
    --concurrency "$LOADGEN_CONCURRENCY" \
    --duration "$LOADGEN_DURATION" \
    --run-dir "$RUN_DIR/loadgen" | tee "$RUN_DIR/loadgen.log"
loadgen_rc="${PIPESTATUS[0]}"
[ "$loadgen_rc" -eq 0 ] || {
    echo "loadgen exited $loadgen_rc; see $RUN_DIR/loadgen.log" >&2
    exit 9
}

# --- 8. hand off state to the validator -------------------------------------
{ echo "RUN_DIR=$RUN_DIR"; echo "L2_ADDRESS=$L2_ADDRESS"; echo "FUNDED_PRIVATE_KEY=$FUNDED_PRIVATE_KEY"; } > "$RUN_DIR/env"
log "load run complete. Validate with: RUN_DIR=$RUN_DIR $SCRIPT_DIR/validate-devnet-l2-lane.sh"
