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
TX_ID_PREFIX="${TX_ID_PREFIX:-97b1}"
FINALITY_PERIOD_SECONDS="${FINALITY_PERIOD_SECONDS:-60}"
TOCCATA_ACTIVATION_DAA_SCORE="${TOCCATA_ACTIVATION_DAA_SCORE:-3300}"
ARCHIVE_DIR="/app/data/kaspa-devnet/datadir/atan/${TX_ID_PREFIX}/chain_block_lists"
BOUNDARY_PERIOD=$(( TOCCATA_ACTIVATION_DAA_SCORE / (FINALITY_PERIOD_SECONDS * 10) ))

log()  { echo "[validate-devnet-atan] $*"; }
fail() { echo "[validate-devnet-atan] VALIDATION FAILED: $*" >&2; exit 1; }

# --- Preconditions: node 1 up and has enough archived periods ---
docker ps --format '{{.Names}}' | grep -qx kaspad-devnet || \
    fail "node 1 (kaspad-devnet) is not running; run scripts/dev/run-devnet-atan-no-l2.sh and mine first."

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
docker compose -f "$IMPORT_COMPOSE" up -d || fail "could not start kaspad-import (is node 1's image built?)."

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
    echo "$logs" | grep -Eiq 'panic|process::exit|AtanError|Validation\(' && {
        log "---- kaspad-import error logs ----"; echo "$logs" | tail -40
        fail "node 2 logged a validation/panic error during import."
    }
    imported_line="$(echo "$logs" | grep -E 'Importing recent finality period chain block lists' | tail -1)"
    [ -n "$imported_line" ] && break
    sleep 2
done
[ -n "$imported_line" ] || fail "node 2 did not report an import range within timeout."
log "node 2 import: $imported_line"

# --- Give commit a moment, then confirm node 2's imported range matches node 1 ---
sleep 10
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
