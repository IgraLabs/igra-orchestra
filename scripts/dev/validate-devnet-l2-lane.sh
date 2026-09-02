#!/usr/bin/env bash
# PASS/FAIL validator for the devnet L2 + lane-id run.
#   1) stability : no viaduct panic / TooManyBlocks; containers healthy
#   2) lane-id   : every non-native, non-coinbase L1 tx == configured lane
#   3) Toccata   : lane txs present at/above the activation DAA (below is a note)
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a; [ -f "$ROOT_DIR/.env" ] && . "$ROOT_DIR/.env"; set +a
KASPAD_JSON_PORT="${KASPAD_JSON_PORT:-18610}"
IGRA_LANE_ID="${IGRA_LANE_ID:-97b10000}"
TOCCATA_ACTIVATION_DAA_SCORE="${TOCCATA_ACTIVATION_DAA_SCORE:-}"
WS="ws://127.0.0.1:${KASPAD_JSON_PORT}"

LANE_HEX="$(printf '%s' "$IGRA_LANE_ID" | tr 'A-Z' 'a-z')"
while [ "${#LANE_HEX}" -lt 40 ]; do LANE_HEX="${LANE_HEX}0"; done
NATIVE_HEX="$(printf '0%.0s' $(seq 1 40))"
COINBASE_HEX="01$(printf '0%.0s' $(seq 1 38))"

fail(){ echo "FAIL: $*" >&2; exit 1; }
wrpc_call(){
    local method="$1" params="$2"
    echo "{\"id\":1,\"method\":\"$method\",\"params\":$params}" \
        | websocat -n1 "$WS" 2>/dev/null || echo '{}'
}

# ---- 1. stability ----------------------------------------------------------
echo "== stability =="
kaspad_name="$(docker ps --format '{{.Names}}' | grep -m1 -x kaspad-devnet || true)"
[ -n "$kaspad_name" ] || fail "no running kaspad-devnet container found; is the devnet stack up?"
LOG_SCAN_LINES="${LOG_SCAN_LINES:-5000}"
logs="$(docker logs --tail "$LOG_SCAN_LINES" "$kaspad_name" 2>&1)" \
    || fail "docker logs $kaspad_name failed; cannot verify absence of panics"
if grep -qiE 'TooManyBlocks|Viaduct Collector error|panicked' <<<"$logs"; then
    fail "viaduct panic / TooManyBlocks in kaspad logs"
fi
containers="$(docker ps --format '{{.Names}}' | grep -E '^(kaspad|execution-layer|rpc-provider-[0-9]+|kaswallet-[0-9]+)-devnet$' || true)"
[ -n "$containers" ] || fail "no devnet (*-devnet) containers found; is the devnet stack up?"
while IFS= read -r c; do
    [ -n "$c" ] || continue
    status="$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo missing)"
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo missing)"
    [ "$status" = "running" ] || fail "container $c not running: $status"
    case "$health" in
        healthy|none) : ;;
        *) fail "container $c unhealthy: $health" ;;
    esac
done <<< "$containers"
echo "  ok: no panic, containers healthy"

# ---- collect recent blocks (tx subnetwork + block DAA) ---------------------
SINK="$(wrpc_call getSink '{}' | jq -r '.params.sink // empty' 2>/dev/null || true)"
[ -n "$SINK" ] || fail "could not fetch chain sink via wRPC (is kaspad wRPC JSON port $KASPAD_JSON_PORT reachable at $WS?)"

WINDOW_BLOCKS="${VALIDATE_WINDOW_BLOCKS:-100}"
declare -a block_jsons=()
hash="$SINK"
for ((i = 0; i < WINDOW_BLOCKS; i++)); do
    [ -n "$hash" ] || break
    resp="$(wrpc_call getBlock "{\"hash\":\"$hash\",\"includeTransactions\":true}")"
    block="$(echo "$resp" | jq -c '.params.block // empty' 2>/dev/null || true)"
    [ -n "$block" ] || break
    block_jsons+=("$block")
    hash="$(echo "$block" | jq -r '.header.parentsByLevel[0][0] // empty' 2>/dev/null || true)"
done
[ "${#block_jsons[@]}" -gt 0 ] || fail "could not fetch any blocks walking back from sink $SINK via wRPC"
BLOCKS_JSON="$(printf '%s\n' "${block_jsons[@]}" | jq -cs '{"params":{"blocks":.}}' 2>/dev/null || true)"
[ -n "$BLOCKS_JSON" ] || fail "failed to assemble collected-blocks JSON from $WINDOW_BLOCKS walked blocks"

# ---- 2. lane-id ------------------------------------------------------------
echo "== lane-id =="
SUBS=()
while IFS= read -r s; do [ -n "$s" ] && SUBS+=("$s"); done < <(printf '%s' "$BLOCKS_JSON" | jq -r '.params.blocks[]?.transactions[]?.subnetworkId // empty' 2>/dev/null || true)
[ "${#SUBS[@]}" -gt 0 ] || fail "no transactions found in recent blocks via getBlocks; is loadgen exercising the lane?"
lane_seen=0
for s in "${SUBS[@]}"; do
    case "$s" in
        "$NATIVE_HEX"|"$COINBASE_HEX") : ;;
        "$LANE_HEX") lane_seen=$((lane_seen + 1)) ;;
        *) fail "tx on unexpected subnetwork $s (expected lane $LANE_HEX)";;
    esac
done
MIN_LANE_TXS="${VALIDATE_MIN_LANE_TXS:-10}"
[ "$lane_seen" -ge "$MIN_LANE_TXS" ] || fail "only $lane_seen lane ($LANE_HEX) tx(s) in the fetched window; expected >= $MIN_LANE_TXS — ingress did not meaningfully exercise the lane (set VALIDATE_MIN_LANE_TXS to lower the bar)"
echo "  ok: $lane_seen ingress txs, all on lane $LANE_HEX"

# ---- 3. Toccata crossing ---------------------------------------------------
echo "== Toccata =="
if [ -z "$TOCCATA_ACTIVATION_DAA_SCORE" ]; then
    echo "  skip: TOCCATA_ACTIVATION_DAA_SCORE unset"
    toccata_result="Toccata check skipped (TOCCATA_ACTIVATION_DAA_SCORE unset)"
else
    vdaa="$(wrpc_call getBlockDagInfo '{}' | jq -r '.params.virtualDaaScore // empty' 2>/dev/null || true)"
    [ -n "$vdaa" ] || fail "could not fetch virtual DAA score via wRPC"
    [ "$vdaa" -gt "$TOCCATA_ACTIVATION_DAA_SCORE" ] 2>/dev/null || fail "virtual DAA $vdaa has not crossed Toccata $TOCCATA_ACTIVATION_DAA_SCORE"
    below="$(echo "$BLOCKS_JSON" | jq -r --arg L "$LANE_HEX" --argjson T "$TOCCATA_ACTIVATION_DAA_SCORE" \
        '[.params.blocks[]? | select((.header.daaScore|tonumber) <  $T) | .transactions[]? | select(.subnetworkId==$L)] | length' 2>/dev/null || echo 0)"
    aboveq="$(echo "$BLOCKS_JSON" | jq -r --arg L "$LANE_HEX" --argjson T "$TOCCATA_ACTIVATION_DAA_SCORE" \
        '[.params.blocks[]? | select((.header.daaScore|tonumber) >= $T) | .transactions[]? | select(.subnetworkId==$L)] | length' 2>/dev/null || echo 0)"
    echo "  lane txs below Toccata: $below ; at/above: $aboveq (virtual DAA $vdaa)"
    [ "${aboveq:-0}" -ge 1 ] || fail "no lane txs at/above Toccata activation DAA"
    [ "${below:-0}" -ge 1 ] || echo "  note: no lane txs below activation in fetched window (run started post-activation?)"
    toccata_result="Toccata crossed"
fi

echo "PASS: L2 stable under load, lane-id correct, $toccata_result"
