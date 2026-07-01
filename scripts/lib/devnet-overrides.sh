#!/bin/bash
# devnet-overrides.sh - generate overrides/devnet.json (consensus override params).
# Sourced by scripts/setup-devnet.sh and scripts/dev/run-devnet-atan-no-l2.sh.

# generate_devnet_overrides SECONDS TOCCATA [PRUNING_DEPTH]
#   Writes $OVERRIDES_OUT_DIR/devnet.json (default: <this-lib>/../../overrides).
#   finality_depth = SECONDS*10 (BPS=10). toccata_activation appended only when
#   TOCCATA is non-empty (keeps JSON comma-correct when Toccata is disabled).
#   PRUNING_DEPTH defaults to 1080000 (kaspad devnet default; keeps setup-devnet.sh
#   unchanged). ATAN commits a finality period only when the pruning point advances
#   past it, and the effective pruning depth is min(pruning_depth, ~159858 for these
#   blockrate params) — so a SMALL pruning_depth (e.g. 3000) is required for ATAN to
#   archive periods within a short devnet mining run (see run-devnet-atan-no-l2.sh).
generate_devnet_overrides() {
    local seconds="$1"
    local toccata="$2"
    local pruning_depth="${3:-1080000}"
    local depth=$(( seconds * 10 ))   # BPS=10 on devnet
    local lib_dir out_dir
    lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    out_dir="${OVERRIDES_OUT_DIR:-$lib_dir/../../overrides}"
    mkdir -p "$out_dir"
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
    "pruning_depth": $pruning_depth,
    "coinbase_maturity": 200
  },
  "crescendo_activation": 0$toccata_line
}
EOF
    if [ -n "$toccata" ]; then
        echo "[setup-devnet] Generated overrides/devnet.json: finality_depth=$depth (= ${seconds}s at 10 BPS), pruning_depth=$pruning_depth, toccata_activation=$toccata"
    else
        echo "[setup-devnet] Generated overrides/devnet.json: finality_depth=$depth (= ${seconds}s at 10 BPS), pruning_depth=$pruning_depth, toccata_activation disabled (never)"
    fi
}
