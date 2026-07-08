#!/bin/bash
# test-devnet-env.sh - plain-bash unit tests for scripts/lib/devnet-env.sh
# Run: ./scripts/dev/test-devnet-env.sh   (exit 0 = all pass)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/devnet-env.sh"

TESTS_RUN=0
TESTS_FAILED=0
check() { # check DESC ACTUAL EXPECTED
    TESTS_RUN=$((TESTS_RUN + 1))
    if [ "$2" = "$3" ]; then echo "PASS: $1"; else
        echo "FAIL: $1 (got '$2', want '$3')"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
ENV_FILE="$TMP/.env"

# A representative .env: plain, whitespace-padded, double/single quoted, CRLF,
# and a duplicated key (last assignment must win).
printf 'PLAIN=abc\n'                    >  "$ENV_FILE"
printf 'PADDED=   spaced   \n'          >> "$ENV_FILE"
printf 'DQUOTED="in quotes"\n'          >> "$ENV_FILE"
printf "SQUOTED='single'\n"             >> "$ENV_FILE"
printf 'CRLF=windows\r\n'               >> "$ENV_FILE"
printf 'DUP=first\n'                    >> "$ENV_FILE"
printf 'DUP=last\n'                     >> "$ENV_FILE"

# --- read_env ---
check "plain value"       "$(read_env PLAIN)"   "abc"
check "trims whitespace"  "$(read_env PADDED)"  "spaced"
check "strips dquotes"    "$(read_env DQUOTED)" "in quotes"
check "strips squotes"    "$(read_env SQUOTED)" "single"
check "trims CR"          "$(read_env CRLF)"    "windows"
check "last match wins"   "$(read_env DUP)"     "last"
read_env ABSENT >/dev/null; check "absent returns 1" "$?" "1"

# --- resolve precedence: shell > file > default ---
DEF="$( unset MISSING; resolve MISSING theDefault; echo "$MISSING" )"
check "default when absent" "$DEF" "theDefault"

FROMFILE="$( unset PLAIN; resolve PLAIN theDefault; echo "$PLAIN" )"
check "file beats default"  "$FROMFILE" "abc"

SHELLWINS="$( PLAIN=shellwins; resolve PLAIN theDefault; echo "$PLAIN" )"
check "shell beats file"    "$SHELLWINS" "shellwins"

# Shell value that is explicitly empty must still win over the file.
EMPTYWINS="$( PLAIN=""; resolve PLAIN theDefault; echo "[$PLAIN]" )"
check "empty shell wins"    "$EMPTYWINS" "[]"

echo "----"
echo "Ran $TESTS_RUN, failed $TESTS_FAILED"
[ "$TESTS_FAILED" -eq 0 ]
