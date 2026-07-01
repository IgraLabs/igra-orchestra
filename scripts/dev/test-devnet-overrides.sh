#!/bin/bash
# test-devnet-overrides.sh - plain-bash unit tests for scripts/lib/devnet-overrides.sh
# Run: ./scripts/dev/test-devnet-overrides.sh   (exit 0 = all pass)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/devnet-overrides.sh"

TESTS_RUN=0
TESTS_FAILED=0
check() { # check DESC ACTUAL EXPECTED
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else
        echo "FAIL: $1 (got '$2', want '$3')"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export OVERRIDES_OUT_DIR="$TMP"

# Case A: Toccata scheduled -> finality_depth=600, toccata_activation=3300 present.
# Two-arg call must keep the default pruning_depth (1080000) so setup-devnet.sh is unchanged.
generate_devnet_overrides 60 3300 >/dev/null
check "finality_depth 600" "$(grep -oE '"finality_depth": [0-9]+' "$TMP/devnet.json")" '"finality_depth": 600'
check "toccata present"    "$(grep -oE '"toccata_activation": [0-9]+' "$TMP/devnet.json")" '"toccata_activation": 3300'
check "default pruning"    "$(grep -oE '"pruning_depth": [0-9]+' "$TMP/devnet.json")" '"pruning_depth": 1080000'
check "valid json A"       "$(jq -e . "$TMP/devnet.json" >/dev/null 2>&1 && echo ok)" "ok"

# Case C: explicit small pruning_depth (fast-pruning ATAN harness) is honored.
generate_devnet_overrides 60 3300 3000 >/dev/null
check "custom pruning 3000" "$(grep -oE '"pruning_depth": [0-9]+' "$TMP/devnet.json")" '"pruning_depth": 3000'
check "valid json C"        "$(jq -e . "$TMP/devnet.json" >/dev/null 2>&1 && echo ok)" "ok"

# Case B: Toccata disabled (empty) -> no toccata_activation, still valid JSON (no trailing comma).
generate_devnet_overrides 600 "" >/dev/null
check "toccata absent"     "$(grep -c 'toccata_activation' "$TMP/devnet.json")" "0"
check "valid json B"       "$(jq -e . "$TMP/devnet.json" >/dev/null 2>&1 && echo ok)" "ok"

echo "----"
echo "Ran $TESTS_RUN, failed $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
