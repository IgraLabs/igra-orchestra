#!/bin/bash
set -euo pipefail
# fetch-block-hashes.sh - Fetch reference block hashes from Bitcoin, Ethereum, and Kaspa
#
# Fetches the latest block hashes from public APIs and prints them
# for copy-pasting into .env.
#
# Usage: ./scripts/fetch-block-hashes.sh

# Check prerequisites
for cmd in curl jq; do
    if ! command -v "$cmd" &> /dev/null; then
        echo "ERROR: $cmd is not installed." >&2
        exit 1
    fi
done

echo "Fetching reference block hashes..." >&2

# Bitcoin: latest block hash
echo "  Bitcoin..." >&2
BITCOIN_BLOCK_HASH=$(curl -sf --max-time 15 https://blockstream.info/api/blocks/tip/hash) \
    || { echo "ERROR: Failed to fetch Bitcoin block hash" >&2; exit 1; }

# Ethereum: block hash 3 blocks before latest (for reorg safety)
echo "  Ethereum (latest - 3)..." >&2
latest_hex=$(curl -sf --max-time 15 https://ethereum-rpc.publicnode.com \
    -H 'Content-Type: application/json' \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    | jq -r '.result') || { echo "ERROR: Failed to fetch Ethereum block number" >&2; exit 1; }

[[ "$latest_hex" =~ ^0x[0-9a-fA-F]+$ ]] || { echo "ERROR: Invalid Ethereum block number: $latest_hex" >&2; exit 1; }
target_hex=$(printf '0x%x' $((16#${latest_hex#0x} - 3)))
ETHEREUM_BLOCK_HASH=$(curl -sf --max-time 15 https://ethereum-rpc.publicnode.com \
    -H 'Content-Type: application/json' \
    --data "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$target_hex\",false],\"id\":1}" \
    | jq -r '.result.hash') || { echo "ERROR: Failed to fetch Ethereum block hash" >&2; exit 1; }

# Kaspa: pruning point hash
echo "  Kaspa..." >&2
KASPA_BLOCK_HASH=$(curl -sf --max-time 15 https://api.kaspa.org/info/blockdag \
    | jq -r '.pruningPointHash') || { echo "ERROR: Failed to fetch Kaspa block hash" >&2; exit 1; }

# Validate
[[ -n "$BITCOIN_BLOCK_HASH" && "$BITCOIN_BLOCK_HASH" != "null" ]] || { echo "ERROR: Bitcoin block hash is empty or null" >&2; exit 1; }
[[ -n "$ETHEREUM_BLOCK_HASH" && "$ETHEREUM_BLOCK_HASH" != "null" ]] || { echo "ERROR: Ethereum block hash is empty or null" >&2; exit 1; }
[[ -n "$KASPA_BLOCK_HASH" && "$KASPA_BLOCK_HASH" != "null" ]] || { echo "ERROR: Kaspa block hash is empty or null" >&2; exit 1; }

# Print for copy-paste
echo ""
echo "BITCOIN_BLOCK_HASH=$BITCOIN_BLOCK_HASH"
echo "ETHEREUM_BLOCK_HASH=$ETHEREUM_BLOCK_HASH"
echo "KASPA_BLOCK_HASH=$KASPA_BLOCK_HASH"
