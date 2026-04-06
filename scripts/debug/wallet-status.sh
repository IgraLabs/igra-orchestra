#!/bin/bash

# Query running kaswallet containers and output their status as JSON
# Requires: docker, jq
# Usage: ./wallet-status.sh [count] [--debug]
#   count  Number of wallets to query, 1-20 (default: auto-detect running containers)

set -e

# Check for required dependencies
for cmd in docker jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

DEBUG=false
WALLET_COUNT=""
MAX_WORKERS=20

for arg in "$@"; do
    case $arg in
        --debug|-d) DEBUG=true ;;
        [0-9]*)
            if ! [[ "$arg" =~ ^[0-9]+$ ]]; then
                echo "Error: count must be a positive integer, got '$arg'" >&2
                exit 1
            fi
            WALLET_COUNT=$arg ;;
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
    echo "Auto-detected $WALLET_COUNT wallet(s) (querying kaswallet-0 through kaswallet-$((WALLET_COUNT - 1)))" >&2
fi

log_debug() {
    if $DEBUG; then
        echo "[DEBUG] $*" >&2
    fi
}

wallets_json="[]"

for i in $(seq 0 $((WALLET_COUNT - 1))); do
    container="kaswallet-$i"

    log_debug "=== $container ==="

    # Run the CLI address-balances command and capture JSON output
    output=$(docker exec "$container" /app/kaswallet-cli address-balances 2>&1) || {
        echo "Error: Failed to exec into $container" >&2
        continue
    }

    log_debug "Raw output:"
    log_debug "$output"

    # Parse the JSON output and build wallet entry
    # Convert sompi to KAS (1 KAS = 100,000,000 sompi = 1e8 sompi)
    wallet_json=$(echo "$output" | jq --argjson index "$i" '{
        index: $index,
        default_address: .default_address,
        total: {
            available_sompi: .total_available,
            available_kas: (.total_available / 100000000),
            pending_sompi: .total_pending,
            pending_kas: (.total_pending / 100000000)
        },
        addresses: [.addresses[] | {
            address: .address,
            available_sompi: .available,
            available_kas: (.available / 100000000),
            pending_sompi: .pending,
            pending_kas: (.pending / 100000000),
            utxos: .utxos
        }]
    }')

    wallets_json=$(echo "$wallets_json" | jq --argjson wallet "$wallet_json" '. += [$wallet]')
done

# Output final JSON
echo "$wallets_json" | jq '{wallets: .}'

# Check for low-balance wallets (< 1 KAS)
low_balance=$(echo "$wallets_json" | jq -r '.[] | select(.total.available_kas < 1) | "  WARNING: kaswallet-\(.index) balance is \(.total.available_kas) KAS"')
if [[ -n "$low_balance" ]]; then
    echo "" >&2
    echo "Low balance wallets (< 1 KAS):" >&2
    echo "$low_balance" >&2
fi
