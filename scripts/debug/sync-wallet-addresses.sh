#!/bin/bash

# Sync wallet addresses from running kaswallet containers into .env
# Queries kaswallet-0 through kaswallet-{count-1}, extracts the first address,
# and updates W{N}_WALLET_TO_ADDRESS in the .env file.
#
# Usage: ./scripts/debug/sync-wallet-addresses.sh [count]
#   count  Number of wallets to query, 1-20 (default: auto-detect running containers)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ENV_FILE="$PROJECT_DIR/.env"
MAX_WORKERS=20

# Check for required dependencies
for cmd in docker jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

# Parse arguments
WALLET_COUNT=""
for arg in "$@"; do
    case $arg in
        [0-9]*)
            if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
                echo "Error: count must be a positive integer, got '$arg'" >&2
                exit 1
            fi
            WALLET_COUNT=$arg ;;
        *) echo "Usage: $0 [count]" >&2; exit 1 ;;
    esac
done

if [[ -n "$WALLET_COUNT" ]] && { [[ "$WALLET_COUNT" -lt 1 ]] || [[ "$WALLET_COUNT" -gt "$MAX_WORKERS" ]]; }; then
    echo "Error: count must be between 1 and $MAX_WORKERS" >&2
    exit 1
fi

# Auto-detect running kaswallet containers if count not specified
if [[ -z "$WALLET_COUNT" ]]; then
    WALLET_COUNT=0
    for i in $(seq 0 $((MAX_WORKERS - 1))); do
        if docker inspect --format='{{.State.Running}}' "kaswallet-$i" 2>/dev/null | grep -q "true"; then
            WALLET_COUNT=$((i + 1))
        fi
    done
    if [[ "$WALLET_COUNT" -eq 0 ]]; then
        echo "Error: No running kaswallet containers found" >&2
        exit 1
    fi
    echo "Auto-detected running kaswallet containers (highest index: $((WALLET_COUNT - 1)), will query 0-$((WALLET_COUNT - 1)))"
fi

# Check .env file exists
if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: .env file not found at $ENV_FILE" >&2
    exit 1
fi

update_env_var() {
    local file="$1"
    local var="$2"
    local value="$3"
    local tmpfile

    if grep -q "^${var}=" "$file"; then
        tmpfile=$(mktemp) || { echo "Error: Failed to create temp file" >&2; return 1; }
        chmod 600 "$tmpfile" || { rm -f "$tmpfile"; echo "Error: Failed to secure temp file" >&2; return 1; }

        while IFS= read -r line || [[ -n "$line" ]]; do
            if [[ "$line" == "${var}="* ]]; then
                printf '%s=%s\n' "$var" "$value"
            else
                printf '%s\n' "$line"
            fi
        done < "$file" > "$tmpfile"

        if ! mv "$tmpfile" "$file"; then
            rm -f "$tmpfile"
            echo "Error: Failed to update $file" >&2
            return 1
        fi
    else
        printf '%s=%s\n' "$var" "$value" >> "$file"
    fi
}

updated=0
failed=0
skipped=0

echo ""
for i in $(seq 0 $((WALLET_COUNT - 1))); do
    container="kaswallet-$i"
    var_name="W${i}_WALLET_TO_ADDRESS"

    # Check if container is running
    if ! docker inspect --format='{{.State.Running}}' "$container" 2>/dev/null | grep -q "true"; then
        echo "  SKIP  $container - not running"
        skipped=$((skipped + 1))
        continue
    fi

    # Query wallet address
    output=$(docker exec "$container" /app/kaswallet-cli address-balances 2>/dev/null) || {
        echo "  FAIL  $container - failed to exec kaswallet-cli"
        failed=$((failed + 1))
        continue
    }

    # Extract first address, fall back to default_address if addresses array is empty
    address=$(echo "$output" | jq -r '.addresses[0].address // .default_address // empty' 2>/dev/null) || {
        echo "  FAIL  $container - failed to parse JSON output"
        failed=$((failed + 1))
        continue
    }

    if [[ -z "$address" ]]; then
        echo "  FAIL  $container - no address found in output"
        failed=$((failed + 1))
        continue
    fi

    # Validate address format (kaspa/kaspatest/kaspadev prefix + bech32 chars)
    if [[ ! "$address" =~ ^kaspa(test|dev)?:[a-z0-9]{50,80}$ ]]; then
        echo "  FAIL  $container - unexpected address format: $address"
        failed=$((failed + 1))
        continue
    fi

    # Update .env
    update_env_var "$ENV_FILE" "$var_name" "$address"
    echo "  OK    $var_name=$address"
    updated=$((updated + 1))
done

echo ""
echo "Summary: $updated updated, $skipped skipped, $failed failed"

if [[ "$updated" -gt 0 ]]; then
    echo ""
    echo "Wallet addresses have been written to $ENV_FILE"
    echo "Restart workers to apply: docker compose --profile frontend-w<N> up -d"
fi

if [[ "$failed" -gt 0 ]]; then
    exit 1
fi
