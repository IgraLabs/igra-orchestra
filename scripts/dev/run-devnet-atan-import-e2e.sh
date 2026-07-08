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
MINE_TIMEOUT_SECS="${MINE_TIMEOUT_SECS:-1500}" # ~25 min cap for the mining phase
MAX_MINER_RESTARTS="${MAX_MINER_RESTARTS:-1}"  # bound restart cycles (bursty restarts corrupt node 1)
ARCHIVE_DIR="/app/data/kaspa-devnet/datadir/atan/${TX_ID_PREFIX}/chain_block_lists"
BOUNDARY_PERIOD=$(( TOCCATA_ACTIVATION_DAA_SCORE / (FINALITY_PERIOD_SECONDS * 10) ))
NODE1_PEER_ADDR="${NODE1_PEER_ADDR:-kaspad-devnet:16611}"
CPUMINER_BIN="$PROJECT_DIR/build/repos/kaspanet-cpuminer/target/release/kaspa-miner"

# Per-run log dir via mktemp -d (not fixed /tmp paths that concurrent runs would
# clobber and pre-existing symlinks could hijack). Printed on failure.
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/e2e-atan-import.XXXXXX")"
NODE1_UP_LOG="$RUN_DIR/node1-up.log"
MINER_LOG="$RUN_DIR/miner.log"
NODE2_COMPOSE_LOG="$RUN_DIR/node2-compose.log"

log()  { echo "[e2e] $(date +%T) $*"; }
fail() { echo "[e2e] VALIDATION FAILED: $*" >&2; exit 1; }

# Default the mining target to 2 periods past the boundary so the run always
# crosses Toccata even when the boundary is moved via TOCCATA/FINALITY overrides;
# reject an explicit target that would stop mining before the boundary.
TARGET_PERIOD="${TARGET_PERIOD:-$((BOUNDARY_PERIOD + 2))}"
[ "$TARGET_PERIOD" -gt "$BOUNDARY_PERIOD" ] 2>/dev/null \
    || fail "TARGET_PERIOD ($TARGET_PERIOD) must be > the Toccata boundary period ($BOUNDARY_PERIOD); mining would stop before crossing Toccata."

# Preflight helpers: is_valid_mining_address + .env resolution, so the destructive
# STEP 1 wipe is gated on a runnable configuration (STEP 3 mines with SKIP_BUILD=1).
# shellcheck source=scripts/lib/devnet-preflight.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/devnet-preflight.sh"
ENV_FILE="$PROJECT_DIR/.env"; [ -f "$ENV_FILE" ] || ENV_FILE="$PROJECT_DIR/.env.devnet.example"
# shellcheck source=scripts/lib/devnet-env.sh
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/devnet-env.sh"
resolve MINING_ADDRESS ""

# Miner lifecycle: track the concrete PID (run-devnet-cpuminer.sh ends in `exec`,
# so $! is the miner's stable PID) instead of a pkill -f pattern that could kill
# an unrelated kaspa-miner (e.g. run-devnet-miner.sh) or mis-report liveness.
MINER_PID=""
start_miner() {
    SKIP_BUILD=1 MINING_THREADS="$MINING_THREADS" \
        "$SCRIPT_DIR/run-devnet-cpuminer.sh" >>"$MINER_LOG" 2>&1 &
    MINER_PID=$!
}
miner_alive() { [ -n "$MINER_PID" ] && kill -0 "$MINER_PID" 2>/dev/null; }
stop_miner()  { [ -n "$MINER_PID" ] && kill "$MINER_PID" 2>/dev/null; MINER_PID=""; }
# A leaked background miner otherwise survives any failure path / Ctrl+C and keeps
# mining node 1, dirtying the clean baseline for the next run. No-op on the PASS
# path, where mining is already stopped in STEP 4.
trap stop_miner EXIT

node1_last_period() {
    docker exec kaspad-devnet sh -c "ls '$ARCHIVE_DIR' 2>/dev/null | sed 's/\.pb\$//' | sort -n | tail -1"
}
node1_all_periods() {
    docker exec kaspad-devnet sh -c "ls '$ARCHIVE_DIR' 2>/dev/null | sed 's/\.pb\$//' | sort -n"
}

# ---------------------------------------------------------------------------
# STEP 0: preflight BEFORE the destructive wipe. STEP 3 mines with SKIP_BUILD=1
# (no build), so a missing binary or invalid MINING_ADDRESS must be caught here,
# not after the local chain is already gone; and the wipe itself is gated.
log "STEP 0: preflight (before destructive wipe)"
[ -x "$CPUMINER_BIN" ] || \
    fail "cpuminer binary not found at $CPUMINER_BIN. Build it once first (clones + builds): ./scripts/dev/run-devnet-cpuminer.sh"
is_valid_mining_address "$MINING_ADDRESS" || \
    fail "MINING_ADDRESS must be a devnet address (kaspadev:...) (got: '${MINING_ADDRESS:-<unset>}'); set it in .env."
if docker volume inspect igra-devnet_kaspad_data >/dev/null 2>&1; then
    if [ "${E2E_FORCE:-}" = "1" ]; then
        log "E2E_FORCE=1; destroying existing igra-devnet_kaspad_data volume."
    elif [ -t 0 ]; then
        printf '[e2e] Existing devnet volume igra-devnet_kaspad_data will be DESTROYED. Continue? [y/N] ' >&2
        read -r reply
        case "$reply" in [yY]|[yY][eE][sS]) ;; *) fail "aborted (existing volume left intact)." ;; esac
    else
        fail "existing igra-devnet_kaspad_data volume would be destroyed; re-run with E2E_FORCE=1 to confirm (non-interactive)."
    fi
fi

# ---------------------------------------------------------------------------
log "STEP 1: clean slate (destroys any local devnet chain + archives)"
docker compose -f "$COMPOSE_NODE2" down -v >/dev/null 2>&1 || true
docker compose -f "$COMPOSE_NODE1" down -v >/dev/null 2>&1 || true
docker rm -f kaspad-devnet >/dev/null 2>&1 || true
docker volume rm igra-devnet_kaspad_data >/dev/null 2>&1 || true

# ---------------------------------------------------------------------------
log "STEP 2: bring up a fresh ATAN-only node 1 (L2 off)"
"$SCRIPT_DIR/run-devnet-atan-no-l2.sh" >"$NODE1_UP_LOG" 2>&1 \
    || { tail -20 "$NODE1_UP_LOG"; fail "node 1 failed to come up; see $NODE1_UP_LOG"; }
docker ps --format '{{.Names}}' | grep -qx kaspad-devnet || fail "kaspad-devnet not running after startup"
log "node 1 up; boundary period = $BOUNDARY_PERIOD (Toccata DAA $TOCCATA_ACTIVATION_DAA_SCORE); logs in $RUN_DIR"

# ---------------------------------------------------------------------------
log "STEP 3: mine ONE clean continuous session until archived period >= $TARGET_PERIOD"
start_miner
sleep 6
miner_alive || { tail -8 "$MINER_LOG"; fail "miner did not start"; }

deadline=$(( SECONDS + MINE_TIMEOUT_SECS ))
last=""
restarts=0
while [ "$SECONDS" -lt "$deadline" ]; do
    if ! miner_alive; then
        # Enforce the restart bound: unlimited stop/restart cycles can recreate the
        # node-1 UTXO-commitment corruption -> node-2 multiset mismatch this
        # choreography exists to avoid (see header). Fail once the budget is spent.
        if [ "$restarts" -ge "$MAX_MINER_RESTARTS" ]; then
            tail -3 "$MINER_LOG"
            fail "miner died again after $restarts restart(s) (limit $MAX_MINER_RESTARTS); aborting to avoid bursty stop/restart mining. Check node 1 health / .env MINING_ADDRESS."
        fi
        restarts=$(( restarts + 1 ))
        log "miner died mid-session (gRPC?); restart #$restarts of $MAX_MINER_RESTARTS (clean-continuous best-effort)"
        tail -3 "$MINER_LOG"
        start_miner
        sleep 6
        miner_alive || fail "miner will not stay alive after restart #$restarts; check node 1 health / .env MINING_ADDRESS"
    fi
    last="$(node1_last_period)"
    log "  archived last period = ${last:-none}"
    if [ -n "$last" ] && [ "$last" -ge "$TARGET_PERIOD" ] 2>/dev/null; then break; fi
    sleep 20
done
[ -n "$last" ] && [ "$last" -ge "$TARGET_PERIOD" ] 2>/dev/null \
    || fail "did not reach period $TARGET_PERIOD within ${MINE_TIMEOUT_SECS}s (got '${last:-none}')"
log "node 1 archived through period $last (single clean session, $restarts miner restart(s))"

# ---------------------------------------------------------------------------
# STEP 4+5 RUN BACK-TO-BACK: stop mining then immediately peer node 2, so node
# 2's IBD completes inside the ~33s is_nearly_synced window and NO node-1 block
# is relayed to the headers-proof-synced node 2 afterwards.
log "STEP 4: stop node 1 mining (freeze pruning point; tip now maximally fresh)"
stop_miner

log "STEP 5: immediately peer a fresh node 2 (headers-proof IBD -> ATAN import)"
NODE1_PEER="$NODE1_PEER_ADDR" docker compose -f "$COMPOSE_NODE2" up -d >"$NODE2_COMPOSE_LOG" 2>&1 \
    || { tail -20 "$NODE2_COMPOSE_LOG"; fail "could not start kaspad-import (node 2); see $NODE2_COMPOSE_LOG"; }
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

    # Hard failures (L1 IBD or ATAN validation). Herestrings, not pipes: under
    # pipefail `echo "$logs" | grep -q` can return 141 (grep exits early -> echo
    # gets SIGPIPE) on a large log even when the pattern matches, which would skip
    # this fail-closed branch and let a completed-but-invalid run read as PASS.
    if grep -Eiq 'multiset hash|got unexpected pruning point|panic|AtanError|Validation\(' <<<"$logs"; then
        echo "---- node 2 error context ----"
        grep -Ei 'multiset hash|unexpected pruning|panic|AtanError|Validation\(' <<<"$logs" | tail -6
        fail "node 2 hit an L1/validation error during import (after $restarts miner restart(s))."
    fi

    if [ -z "$synced" ] && grep -q 'Consensus is synced, starting ATAN' <<<"$logs"; then
        synced=1; log "  node 2: consensus synced, ATAN starting (window hit: ~$((SECONDS-kill_ts))s after mining stop)"
    fi
    # Peered node 2 anchors at node 1's (advanced) pruning point, so node 1's
    # archived periods are HISTORICAL for it (imported + four-group validated,
    # not skipped as "recent/redundant"). Accept either completion line.
    if grep -qE 'Import of (recent|historical) finality period chain block lists complete' <<<"$logs"; then
        imported=1; log "  node 2: import phase complete (four-group validation ran fail-closed)"; break
    fi
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
# "Across the boundary" requires pre-Toccata coverage too, not only post-boundary
# periods: node 2 must hold a period at/below the boundary.
[ "$n2_first" -le "$BOUNDARY_PERIOD" ] 2>/dev/null \
    || fail "node 2 first period ($n2_first) is past the boundary ($BOUNDARY_PERIOD); pre-Toccata periods were not imported."
# Full-set check: every period node 1 archived must be present on node 2 (no
# missing pre/boundary/post period, no mid-range gap). comm needs a consistent
# sort; use lexical sort on both sides.
n1_all="$(node1_all_periods)"
missing="$(comm -23 <(printf '%s\n' "$n1_all" | sort) <(printf '%s\n' "$n2" | sort))"
[ -z "$missing" ] || fail "node 2 is missing periods that node 1 archived: $(echo "$missing" | tr '\n' ' ')"

# Check the importing node's log for the four-group / historical import evidence.
hist="$(docker logs kaspad-import-devnet 2>&1 | grep -Ei 'historical finality period|Import ranges' | tail -2)"
echo "$hist" | sed 's/^/[e2e]   /'

echo
echo "[e2e] VALIDATION PASSED: node 2 imported every finality period node 1 archived (${n2_first}..${n2_last}), covering pre-Toccata, the boundary (${BOUNDARY_PERIOD}), and post-Toccata, with no L1/validation error (four-group validator ran fail-closed on import)."
