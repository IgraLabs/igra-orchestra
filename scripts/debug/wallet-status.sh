#!/bin/bash

# Query all kaswallet containers (0-4) and output their status as JSON
# Requires: docker, jq
# Usage: ./wallet-status.sh [count] [--debug]

set -e

# Check for required dependencies
for cmd in docker jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "Error: Required command '$cmd' not found" >&2
        exit 1
    fi
done

DEBUG=false
WALLET_COUNT=5

for arg in "$@"; do
    case $arg in
        --debug|-d) DEBUG=true ;;
        [0-9]*) WALLET_COUNT=$arg ;;
    esac
done

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
