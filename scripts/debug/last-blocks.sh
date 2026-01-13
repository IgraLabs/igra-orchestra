#!/bin/bash
# last_blocks.sh - Get last 10 blocks with DAA and timestamp

# Detect if kaspad is in Docker and get its IP
if docker ps --format '{{.Names}}' | grep -q '^kaspad$'; then
    KASPAD_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' kaspad)
    WS_URL="ws://${KASPAD_IP}:18110"
else
    WS_URL="ws://127.0.0.1:18110"
fi

# Function to make wRPC call
wrpc_call() {
    local method=$1
    local params=$2
    echo "{\"id\":1,\"method\":\"$method\",\"params\":$params}" | \
        websocat -n1 "$WS_URL" 2>/dev/null
}

# Get sink
SINK_RESPONSE=$(wrpc_call "getSink" "{}")
HASH=$(echo "$SINK_RESPONSE" | jq -r '.params.sink' 2>/dev/null)

if [ -z "$HASH" ] || [ "$HASH" == "null" ]; then
    echo "ERROR: Could not get sink hash. Is kaspad running?"
    exit 1
fi

echo "=== Last 10 Blocks ==="
echo ""
printf "%-3s  %-18s  %-12s  %-15s  %s\n" "#" "HASH" "DAA" "TIMESTAMP (ms)" "DATE/TIME"
printf "%-3s  %-18s  %-12s  %-15s  %s\n" "---" "------------------" "------------" "---------------" "-------------------"

for i in {1..10}; do
    BLOCK_RESPONSE=$(wrpc_call "getBlock" "{\"hash\":\"$HASH\",\"includeTransactions\":false}")

    BLOCK=$(echo "$BLOCK_RESPONSE" | jq '.params.block' 2>/dev/null)
    DAA=$(echo "$BLOCK" | jq -r '.header.daaScore' 2>/dev/null)
    TS=$(echo "$BLOCK" | jq -r '.header.timestamp' 2>/dev/null)

    # Get first parent from parentsByLevel[0][0]
    NEXT_HASH=$(echo "$BLOCK" | jq -r '.header.parentsByLevel[0][0] // empty' 2>/dev/null)

    # Convert timestamp
    if [ -n "$TS" ] && [ "$TS" != "null" ]; then
        TS_SEC=$((TS/1000))
        DATE=$(date -d "@$TS_SEC" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$TS_SEC" "+%Y-%m-%d %H:%M:%S" 2>/dev/null)
    else
        DATE="N/A"
    fi

    printf "%-3s  %s...  %-12s  %-15s  %s\n" "$i" "${HASH:0:16}" "$DAA" "$TS" "$DATE"

    [ -z "$NEXT_HASH" ] || [ "$NEXT_HASH" == "null" ] && break
    HASH=$NEXT_HASH
done

