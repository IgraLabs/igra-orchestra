#!/bin/bash
# run-devnet-atan-no-l2.sh - Bring up a devnet kaspad with ATAN enabled but L2
# (viaduct / execution layer) DISABLED, with Toccata scheduled early so mining
# quickly crosses the KIP-21 boundary. Used to produce ATAN finality-period
# archives before/after Toccata for import-validation (see
# scripts/dev/validate-devnet-atan.sh).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.devnet.yml"

# shellcheck source=scripts/lib/devnet-overrides.sh
source "$SCRIPT_DIR/../lib/devnet-overrides.sh"

log() { echo "[run-devnet-atan-no-l2] $*"; }

# Test knobs (override via shell). Defaults give 5 pre + boundary + >=5 post periods.
export NETWORK="${NETWORK:-devnet}"
export TX_ID_PREFIX="${TX_ID_PREFIX:-97b1}"
export IGRA_LANE_ID="${IGRA_LANE_ID:-97b10000}"
export FINALITY_PERIOD_SECONDS="${FINALITY_PERIOD_SECONDS:-60}"
export TOCCATA_ACTIVATION_DAA_SCORE="${TOCCATA_ACTIVATION_DAA_SCORE:-3300}"
# Small pruning_depth so the pruning point advances quickly: ATAN only commits a
# finality period once the pruning point passes it. Effective depth is
# min(pruning_depth, ~159858), so this must be small to archive periods within a
# short mining run. Must stay > finality_depth (600). Baked on first run.
export PRUNING_DEPTH="${PRUNING_DEPTH:-3000}"
export IGRA_ENABLE=false
export ATAN_ENABLE=true
# Mining node has no ATAN data source; leave import unset.
export ATAN_IMPORT_DIR=""
export ATAN_IMPORT_URL="${ATAN_IMPORT_URL:-}"
export CDN_BASE_URL="${CDN_BASE_URL:-}"

# finality_depth + toccata are baked into the consensus DB on first run. A stale
# volume would silently keep old values, so require a clean slate.
if docker volume inspect igra-devnet_kaspad_data >/dev/null 2>&1; then
    log "ERROR: volume igra-devnet_kaspad_data exists; its baked finality/toccata may differ."
    log "       Wipe it first (destroys the local chain):"
    log "         docker compose -f $COMPOSE_FILE down -v"
    exit 1
fi

log "Generating overrides (finality=${FINALITY_PERIOD_SECONDS}s, toccata=${TOCCATA_ACTIVATION_DAA_SCORE}, pruning_depth=${PRUNING_DEPTH})"
OVERRIDES_OUT_DIR="$PROJECT_DIR/overrides" generate_devnet_overrides \
    "$FINALITY_PERIOD_SECONDS" "$TOCCATA_ACTIVATION_DAA_SCORE" "$PRUNING_DEPTH"

mkdir -p "$PROJECT_DIR/logs/kaspad"

log "Starting kaspad ONLY (no execution layer, no L2)..."
# --no-deps guarantees the execution-layer dependency is not started.
docker compose -f "$COMPOSE_FILE" --profile backend up -d --build --no-deps kaspad

log "Waiting for kaspad to report healthy..."
status=none
for _ in $(seq 1 30); do
    status="$(docker inspect -f '{{.State.Health.Status}}' kaspad-devnet 2>/dev/null || echo none)"
    [ "$status" = "healthy" ] && break
    sleep 2
done
log "kaspad health: $status"
# Fail closed: a still-unhealthy node (bad overrides, port clash, crash loop)
# must not print a success banner and exit 0 — downstream callers (the e2e's
# STEP 2) treat exit 0 + container-exists as a healthy node 1 and would burn the
# long mining phase against a broken node before surfacing a confusing failure.
if [ "$status" != "healthy" ]; then
    log "ERROR: kaspad did not become healthy within 60s (status: $status). Recent logs:"
    docker logs --tail 40 kaspad-devnet 2>&1 || true
    exit 1
fi

cat <<EOF

Node 1 (ATAN-only, L2 off) is up. Next:

  1) Mine across Toccata (needs MINING_ADDRESS=kaspadev:... in .env):
       ./scripts/dev/run-devnet-cpuminer.sh
     ATAN archives a period only once the pruning point (pruning_depth=${PRUNING_DEPTH}
     behind the tip) passes it. Toccata is at DAA ${TOCCATA_ACTIVATION_DAA_SCORE}
     (period 5). To archive 5+ periods each side, the pruning point must reach ~DAA
     6300, i.e. mine to virtual DAA ~9500-10000. Watch the archive dir in step 2.

  2) Watch archived periods appear:
       docker exec kaspad-devnet ls /app/data/kaspa-devnet/datadir/atan/${TX_ID_PREFIX}/chain_block_lists

  3) Validate via import into a second node:
       ./scripts/dev/validate-devnet-atan.sh

NOTE: this run overwrote overrides/devnet.json with harness params
(finality=${FINALITY_PERIOD_SECONDS}s, toccata=${TOCCATA_ACTIVATION_DAA_SCORE},
pruning_depth=${PRUNING_DEPTH}). The normal devnet stack loads whatever
overrides/devnet.json is present, so re-run ./scripts/setup-devnet.sh (and wipe
the kaspad volume) before returning to it — otherwise these params get baked into
a fresh volume.
EOF
