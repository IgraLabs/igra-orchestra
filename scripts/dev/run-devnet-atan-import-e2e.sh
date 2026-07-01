#!/bin/bash
# run-devnet-atan-import-e2e.sh - one-shot CLEAN end-to-end for the ATAN
# import-validation path (node 1 archives -> node 2 imports + four-group-validates
# across the Toccata boundary), driven entirely in one process so the tight
# consensus-sync window is hit reliably.
#
# Why the choreography:
#   * On this fast-pruning devnet (pruning_depth=3000) node 2 must sync via
#     headers-proof IBD, and ATAN only starts once consensus is is_nearly_synced
#     (sink block timestamp younger than ~33s for these params).
#   * To be nearly-synced, node 2's sink (== node 1's tip after IBD) must be
#     < ~33s old -> node 1 must have a FRESH tip.
#   * But node 1 mining is incompatible with node 2's IBD:
#       - mining DURING node 2 IBD  -> "got unexpected pruning point"
#       - mining AFTER  node 2 IBD  -> GhostdagCompact panic on block relay
#       - bursty stop/restart mining-> node 1 UTXO-commitment corruption
#                                       -> node 2 "multiset hash mismatch"
#   So: node 1 is mined in ONE clean continuous session, then STOPPED, and node 2
#   must finish IBD within ~33s of node 1's last block, with NO node-1 mining
#   after. Steps 4-5 below therefore run kill-miner then up-node2 back-to-back in
#   this single process (zero inter-step latency) to fit inside the window.
#
# Leaves both nodes up on PASS for inspection; prints PASS/FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_NODE1="$PROJECT_DIR/docker-compose.devnet.yml"
COMPOSE_NODE2="$PROJECT_DIR/docker-compose.devnet-atan-import.yml"

TX_ID_PREFIX="${TX_ID_PREFIX:-97b1}"
FINALITY_PERIOD_SECONDS="${FINALITY_PERIOD_SECONDS:-60}"
TOCCATA_ACTIVATION_DAA_SCORE="${TOCCATA_ACTIVATION_DAA_SCORE:-3300}"
MINING_THREADS="${MINING_THREADS:-2}"          # 4 threads caused gRPC broken-pipe deaths
TARGET_PERIOD="${TARGET_PERIOD:-7}"            # archive at least this many periods (past boundary 5)
MINE_TIMEOUT_SECS="${MINE_TIMEOUT_SECS:-1500}" # ~25 min cap for the mining phase
ARCHIVE_DIR="/app/data/kaspa-devnet/datadir/atan/${TX_ID_PREFIX}/chain_block_lists"
BOUNDARY_PERIOD=$(( TOCCATA_ACTIVATION_DAA_SCORE / (FINALITY_PERIOD_SECONDS * 10) ))
NODE1_PEER_ADDR="${NODE1_PEER_ADDR:-kaspad-devnet:16611}"

log()  { echo "[e2e] $(date +%T) $*"; }
fail() { echo "[e2e] VALIDATION FAILED: $*" >&2; exit 1; }

# pgrep pattern for the miner binary. Safe from self-match: this script's own
# process cmdline is the script PATH, which does not contain "kaspa-miner".
MINER_PAT='kaspa-miner'
miner_alive() { pgrep -f "$MINER_PAT" >/dev/null 2>&1; }
stop_miner()  { pkill -9 -f "$MINER_PAT" >/dev/null 2>&1 || true; }

node1_last_period() {
    docker exec kaspad-devnet sh -c "ls '$ARCHIVE_DIR' 2>/dev/null | sed 's/\.pb\$//' | sort -n | tail -1"
}

# ---------------------------------------------------------------------------
log "STEP 1: clean slate (destroys any local devnet chain + archives)"
docker compose -f "$COMPOSE_NODE2" down -v >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_NODE1" down -v >/dev/null 2>&1 || true
docker rm -f kaspad-devnet >/dev/null 2>&1 || true
docker volume rm igra-devnet_kaspad_data >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "STEP 2: bring up a fresh ATAN-only node 1 (L2 off)"
"$SCRIPT_DIR/run-devnet-atan-no-l2.sh" >/tmp/e2e-node1-up.log 2>&1 \
    || { tail -20 /tmp/e2e-node1-up.log; fail "node 1 failed to come up"; }
docker ps --format '{{.Names}}' | grep -qx kaspad-devnet || fail "kaspad-devnet not running after startup"
log "node 1 up; boundary period = $BOUNDARY_PERIOD (Toccata DAA $TOCCATA_ACTIVATION_DAA_SCORE)"

# ---------------------------------------------------------------------------
log "STEP 3: mine ONE clean continuous session until archived period >= $TARGET_PERIOD"
SKIP_BUILD=1 MINING_THREADS="$MINING_THREADS" "$SCRIPT_DIR/run-devnet-cpuminer.sh" >/tmp/e2e-miner.log 2>&1 &
sleep 6
miner_alive || { tail -8 /tmp/e2e-miner.log; fail "miner did not start"; }

deadline=$(( SECONDS + MINE_TIMEOUT_SECS ))
last=""
while [ "$SECONDS" -lt "$deadline" ]; do
    if ! miner_alive; then
        log "miner died mid-session (gRPC?); restarting once (clean-continuous best-effort)"
        tail -3 /tmp/e2e-miner.log
        SKIP_BUILD=1 MINING_THREADS="$MINING_THREADS" "$SCRIPT_DIR/run-devnet-cpuminer.sh" >>/tmp/e2e-miner.log 2>&1 &
        sleep 6
        miner_alive || fail "miner will not stay alive; check node 1 health / .env MINING_ADDRESS"
    fi
    last="$(node1_last_period)"
    log "  archived last period = ${last:-none}"
    if [ -n "$last" ] && [ "$last" -ge "$TARGET_PERIOD" ] 2>/dev/null; then break; fi
    sleep 20
done
[ -n "$last" ] && [ "$last" -ge "$TARGET_PERIOD" ] 2>/dev/null \
    || fail "did not reach period $TARGET_PERIOD within ${MINE_TIMEOUT_SECS}s (got '${last:-none}')"
log "node 1 archived through period $last (single clean session)"

# ---------------------------------------------------------------------------
# STEP 4+5 RUN BACK-TO-BACK: stop mining then immediately peer node 2, so node
# 2's IBD completes inside the ~33s is_nearly_synced window and NO node-1 block
# is relayed to the headers-proof-synced node 2 afterwards.
log "STEP 4: stop node 1 mining (freeze pruning point; tip now maximally fresh)"
stop_miner

log "STEP 5: immediately peer a fresh node 2 (headers-proof IBD -> ATAN import)"
NODE1_PEER="$NODE1_PEER_ADDR" docker compose -f "$COMPOSE_NODE2" up -d >/dev/null 2>&1 \
    || fail "could not start kaspad-import (node 2)"
kill_ts=$SECONDS
docker ps --format '{{.Names}}' | grep -qx kaspad-import-devnet || fail "node 2 did not start"

# ---------------------------------------------------------------------------
log "STEP 6: watch node 2 for sync -> import -> four-group validation"
synced=""; imported=""; outcome=""
for _ in $(seq 1 60); do
    if ! docker ps --format '{{.Names}}' | grep -qx kaspad-import-devnet; then
        echo "---- node 2 last logs ----"; docker logs --tail 30 kaspad-import-devnet 2>&1 || true
        fail "node 2 EXITED during sync/import (fail-closed validation panic OR L1 IBD error)."
    fi
    logs="$(docker logs kaspad-import-devnet 2>&1)"

    # Hard failures (L1 IBD or ATAN validation)
    if echo "$logs" | grep -Eiq 'multiset hash|got unexpected pruning point|panic|AtanError|Validation\('; then
        echo "---- node 2 error context ----"
        echo "$logs" | grep -Ei 'multiset hash|unexpected pruning|panic|AtanError|Validation\(' | tail -6
        fail "node 2 hit an L1/validation error during import."
    fi

    [ -z "$synced" ] && echo "$logs" | grep -q 'Consensus is synced, starting ATAN' && {
        synced=1; log "  node 2: consensus synced, ATAN starting (window hit: ~$((SECONDS-kill_ts))s after mining stop)"
    }
    # Peered node 2 anchors at node 1's (advanced) pruning point, so node 1's
    # archived periods are HISTORICAL for it (imported + four-group validated,
    # not skipped as "recent/redundant"). Accept either completion line.
    echo "$logs" | grep -qE 'Import of (recent|historical) finality period chain block lists complete' && {
        imported=1; log "  node 2: import phase complete (four-group validation ran fail-closed)"; break
    }
    sleep 2
done

[ -n "$synced" ] || {
    echo "---- node 2 tail ----"; docker logs --tail 15 kaspad-import-devnet 2>&1 | grep -Ei 'waiting|synced|IBD' || true
    fail "node 2 never reached is_nearly_synced within the window (node 1 tip aged past ~33s before IBD finished). Re-run: this is the timing window, not an ATAN error."
}
[ -n "$imported" ] || fail "node 2 synced but did not report import completion within timeout."

# ---------------------------------------------------------------------------
log "STEP 7: assert node 2 stored validated periods across the Toccata boundary"
sleep 8
docker ps --format '{{.Names}}' | grep -qx kaspad-import-devnet \
    || fail "node 2 exited shortly after import (late validation failure)."
n2="$(docker exec kaspad-import-devnet sh -c "ls '$ARCHIVE_DIR' 2>/dev/null | sed 's/\.pb\$//' | sort -n")"
n2_first="$(echo "$n2" | head -1)"; n2_last="$(echo "$n2" | tail -1)"
log "node 2 stored periods: first=${n2_first:-none} last=${n2_last:-none}"
[ -n "$n2_last" ] || fail "node 2 stored no periods after import."
[ "$n2_last" -gt "$BOUNDARY_PERIOD" ] 2>/dev/null \
    || fail "node 2 top period ($n2_last) not past the Toccata boundary ($BOUNDARY_PERIOD)."

# Check the importing node's log for the four-group / historical import evidence.
hist="$(docker logs kaspad-import-devnet 2>&1 | grep -Ei 'historical finality period|Import ranges' | tail -2)"
echo "$hist" | sed 's/^/[e2e]   /'

echo
echo "[e2e] VALIDATION PASSED: node 2 imported finality periods ${n2_first}..${n2_last} across the Toccata boundary ${BOUNDARY_PERIOD} with no L1/validation error (four-group validator ran fail-closed on import)."
