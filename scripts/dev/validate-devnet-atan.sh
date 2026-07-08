#!/bin/bash
# validate-devnet-atan.sh - Validate node 1's ATAN archive by importing it into a
# fresh second kaspad node (--atan-import-dir). kaspad's startup import runs the
# post-KIP-21 four-group validator against the devnet Toccata boundary and
# process::exit(1)s on any invalid period, so: node 2 imports the full range and
# stays up  ==  PASS.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
IMPORT_COMPOSE="$PROJECT_DIR/docker-compose.devnet-atan-import.yml"
OVERRIDES_JSON="$PROJECT_DIR/overrides/devnet.json"
ATAN_BASE="/app/data/kaspa-devnet/datadir/atan"
IMPORT_GRPC_HOST_PORT="${IMPORT_GRPC_HOST_PORT:-16620}"  # node 2's published gRPC
NODE1_PEER="${NODE1_PEER:-}"                             # opt into peering instead of self-mining

log()  { echo "[validate-devnet-atan] $*"; }
fail() { echo "[validate-devnet-atan] VALIDATION FAILED: $*" >&2; exit 1; }

# --- Preconditions: node 1 up ---
docker ps --format '{{.Names}}' | grep -qx kaspad-devnet || \
    fail "node 1 (kaspad-devnet) is not running; run scripts/dev/run-devnet-atan-no-l2.sh and mine first."

# --- Derive consensus params from the AUTHORITATIVE sources, not harness-default
# env: the Toccata boundary must be computed from the same finality/toccata node 1
# actually booted with, or the boundary pass/fail verdicts are silently wrong
# against a differently-configured node. finality_depth + toccata_activation come
# from the override file node 1 loaded; the tx-id prefix from node 1's archive layout.
read_json_num() { grep -oE "\"$1\"[[:space:]]*:[[:space:]]*[0-9]+" "$2" 2>/dev/null | grep -oE '[0-9]+$' | head -1; }
finality_depth=""; toccata=""
if [ -f "$OVERRIDES_JSON" ]; then
    finality_depth="$(read_json_num finality_depth "$OVERRIDES_JSON")"
    toccata="$(read_json_num toccata_activation "$OVERRIDES_JSON")"
fi
# Fall back to env (harness defaults) only if the override file is unreadable.
[ -n "$finality_depth" ] || finality_depth=$(( ${FINALITY_PERIOD_SECONDS:-60} * 10 ))
[ -n "$toccata" ]        || toccata="${TOCCATA_ACTIVATION_DAA_SCORE:-}"
[ "$finality_depth" -gt 0 ] 2>/dev/null || \
    fail "could not determine finality_depth (checked $OVERRIDES_JSON and FINALITY_PERIOD_SECONDS)."
[ -n "$toccata" ] || \
    fail "could not determine toccata_activation; node 1 may have Toccata disabled (checked $OVERRIDES_JSON and TOCCATA_ACTIVATION_DAA_SCORE)."
BOUNDARY_PERIOD=$(( toccata / finality_depth ))

# Discover node 1's tx-id prefix from its on-disk archive layout (exactly one dir
# expected); fall back to env/default if it cannot be read.
prefix="$(docker exec kaspad-devnet sh -c "ls '$ATAN_BASE' 2>/dev/null" | tr -d '\r' | grep -E '^[0-9a-fA-F]+$' | head -1)"
TX_ID_PREFIX="${prefix:-${TX_ID_PREFIX:-97b1}}"
ARCHIVE_DIR="$ATAN_BASE/$TX_ID_PREFIX/chain_block_lists"
log "params (from overrides/archive): finality_depth=$finality_depth toccata=$toccata boundary_period=$BOUNDARY_PERIOD tx_prefix=$TX_ID_PREFIX"

periods="$(docker exec kaspad-devnet sh -c "ls '$ARCHIVE_DIR' 2>/dev/null | sed 's/\.pb\$//' | sort -n")"
[ -n "$periods" ] || fail "no archived periods in $ARCHIVE_DIR (mine longer)."
first="$(echo "$periods" | head -1)"
last="$(echo "$periods" | tail -1)"
count="$(echo "$periods" | wc -l | tr -d ' ')"
log "node 1 archived periods: first=$first last=$last count=$count (boundary period=$BOUNDARY_PERIOD)"
[ "$last" -gt "$BOUNDARY_PERIOD" ] || \
    fail "last archived period ($last) is not past the Toccata boundary period ($BOUNDARY_PERIOD); mine longer."
[ "$first" -le "$BOUNDARY_PERIOD" ] || \
    log "WARNING: first archived period ($first) is already past the boundary ($BOUNDARY_PERIOD); pre-Toccata coverage is thin."

# --- Fresh node 2 import ---
log "Starting node 2 (fresh atan_db) importing from node 1's archive (read-only)..."
docker compose -f "$IMPORT_COMPOSE" down -v >/dev/null 2>&1 || true
NODE1_PEER="$NODE1_PEER" docker compose -f "$IMPORT_COMPOSE" up -d \
    || fail "could not start kaspad-import (is node 1's image built? see: docker compose -f $IMPORT_COMPOSE logs)."

# ATAN only starts the import once node 2 reports is_nearly_synced. Reaching that
# needs either peering to a fresh-tipped node 1 (opt-in via NODE1_PEER, only safe
# with node 1 mining stopped) or self-mining node 2 a few blocks so its own sink
# timestamp is fresh (the compose default). Unless the operator opted into peering,
# drive self-mining from a host cpuminer against node 2's published gRPC.
MINER_PID=""
stop_node2_miner() { [ -n "$MINER_PID" ] && kill "$MINER_PID" 2>/dev/null; MINER_PID=""; }
trap stop_node2_miner EXIT
if [ -n "$NODE1_PEER" ]; then
    log "NODE1_PEER=$NODE1_PEER set; node 2 peers to node 1 for IBD (no self-mining)."
else
    log "Self-mining node 2 to reach is_nearly_synced (host cpuminer -> 127.0.0.1:$IMPORT_GRPC_HOST_PORT)..."
    KASPAD_GRPC_PORT="$IMPORT_GRPC_HOST_PORT" SKIP_BUILD=1 \
        "$SCRIPT_DIR/run-devnet-cpuminer.sh" >/dev/null 2>&1 &
    MINER_PID=$!
fi

# --- Wait for the import to finish or the node to die ---
log "Waiting for import to complete (or node to hard-exit on an invalid period)..."
imported_line=""
for _ in $(seq 1 180); do
    if ! docker ps --format '{{.Names}}' | grep -qx kaspad-import-devnet; then
        log "---- kaspad-import last logs ----"
        docker logs --tail 40 kaspad-import-devnet 2>&1 || true
        fail "node 2 exited during import (fail-closed validation panic = invalid period)."
    fi
    logs="$(docker logs kaspad-import-devnet 2>&1)"
    # Herestring (not a pipe) so grep's early exit under pipefail can't return 141
    # and skip this fail-closed error branch on a large log.
    if grep -Eiq 'panic|process::exit|AtanError|Validation\(' <<<"$logs"; then
        log "---- kaspad-import error logs ----"; printf '%s\n' "$logs" | tail -40
        fail "node 2 logged a validation/panic error during import."
    fi
    # Wait for the COMPLETION line, not the start line + a fixed sleep. A peered
    # node 2 anchors at node 1's advanced pruning point and logs the HISTORICAL
    # variant; a self-mined node 2 logs the RECENT variant. Accept either.
    imported_line="$(grep -E 'Import of (recent|historical) finality period chain block lists complete' <<<"$logs" | tail -1)"
    [ -n "$imported_line" ] && break
    sleep 2
done
[ -n "$imported_line" ] || fail "node 2 did not reach import completion within timeout. Most likely node 2 never became is_nearly_synced, so ATAN never started. Unblock it by self-mining node 2 (SKIP_BUILD needs a prebuilt binary; run ./scripts/dev/run-devnet-cpuminer.sh once) or by peering with NODE1_PEER=kaspad-devnet:16611 (only with node 1 mining stopped)."
log "node 2 import complete: $imported_line"

# Import done: stop self-mining. Node 2 stays up for the range checks below.
stop_node2_miner

# Brief settle so stored periods are flushed, then confirm the range matches node 1.
sleep 3
docker ps --format '{{.Names}}' | grep -qx kaspad-import-devnet || \
    fail "node 2 exited shortly after import (late validation failure)."
n2_periods="$(docker exec kaspad-import-devnet sh -c "ls '$ARCHIVE_DIR' 2>/dev/null | sed 's/\.pb\$//' | sort -n")"
[ -n "$n2_periods" ] || fail "node 2 has no stored periods after import."
n2_first="$(echo "$n2_periods" | head -1)"
n2_last="$(echo "$n2_periods" | tail -1)"
n2_count="$(echo "$n2_periods" | wc -l | tr -d ' ')"
log "node 2 stored periods: first=$n2_first last=$n2_last count=$n2_count"
[ "$n2_last" -ge "$last" ] || fail "node 2 last period ($n2_last) < node 1 ($last); import incomplete."
[ "$n2_last" -gt "$BOUNDARY_PERIOD" ] || fail "node 2 did not import past the Toccata boundary."
# Pre-Toccata coverage: node 2 must hold periods at/below the boundary, not only post-Toccata ones.
[ "$n2_first" -le "$BOUNDARY_PERIOD" ] || fail "node 2 first period ($n2_first) is past the boundary ($BOUNDARY_PERIOD); pre-Toccata periods were not imported."
# Full-set check: every period node 1 archived must be present on node 2 (no missing pre/boundary/post, no mid-range gaps).
# comm needs a consistent sort; use lexical sort on both sides.
missing="$(comm -23 <(printf '%s\n' "$periods" | sort) <(printf '%s\n' "$n2_periods" | sort))"
[ -z "$missing" ] || fail "node 2 is missing periods that node 1 archived: $(echo "$missing" | tr '\n' ' ')"

echo "[validate-devnet-atan] VALIDATION PASSED: node 2 imported all $count periods node 1 archived ($n2_first..$n2_last), covering pre-Toccata, boundary ($BOUNDARY_PERIOD), and post-Toccata, with no validation error."
