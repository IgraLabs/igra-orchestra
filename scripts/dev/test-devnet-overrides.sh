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

# The JSON-validity checks need jq; without it every such check compares '' to
# 'ok' and reports a misleading FAIL for what is really a missing tool. Detect
# once and skip those checks (still running the content assertions) if absent.
if command -v jq >/dev/null 2>&1; then HAVE_JQ=1; else HAVE_JQ=0; echo "SKIP: jq not installed; skipping JSON-validity checks"; fi
check_json() { # check_json DESC FILE
    [ "$HAVE_JQ" = "1" ] || return 0
    check "$1" "$(jq -e . "$2" >/dev/null 2>&1 && echo ok)" "ok"
}

# Case A: Toccata scheduled -> finality_depth=600, toccata_activation=3300 present.
# Two-arg call must keep the default pruning_depth (1080000) so setup-devnet.sh is unchanged.
generate_devnet_overrides 60 3300 >/dev/null
check "finality_depth 600" "$(grep -oE '"finality_depth": [0-9]+' "$TMP/devnet.json")" '"finality_depth": 600'
check "toccata present"    "$(grep -oE '"toccata_activation": [0-9]+' "$TMP/devnet.json")" '"toccata_activation": 3300'
check "default pruning"    "$(grep -oE '"pruning_depth": [0-9]+' "$TMP/devnet.json")" '"pruning_depth": 1080000'
check_json "valid json A"  "$TMP/devnet.json"

# Case C: explicit small pruning_depth (fast-pruning ATAN harness) is honored.
generate_devnet_overrides 60 3300 3000 >/dev/null
check "custom pruning 3000" "$(grep -oE '"pruning_depth": [0-9]+' "$TMP/devnet.json")" '"pruning_depth": 3000'
check_json "valid json C"   "$TMP/devnet.json"

# Case B: Toccata disabled (empty) -> no toccata_activation, still valid JSON (no trailing comma).
generate_devnet_overrides 600 "" >/dev/null
check "toccata absent"     "$(grep -c 'toccata_activation' "$TMP/devnet.json")" "0"
check_json "valid json B"  "$TMP/devnet.json"

echo "----"
echo "Ran $TESTS_RUN, failed $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
