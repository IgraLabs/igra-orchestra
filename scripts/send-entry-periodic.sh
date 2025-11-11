#!/bin/bash
# Periodic Entry Transaction Sender
# Sends entry transactions from L1 (Kaspa) to L2 (IGRA) via Docker container

set -e -o pipefail

# ============================================================================
# CONFIGURATION
# ============================================================================

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Transaction configuration (configurable via environment variables)
CONTAINER_NAME="${CONTAINER_NAME:-rpc-provider-0}"
INTERVAL_SECONDS="${INTERVAL_SECONDS:-60}"
L2_ADDRESS="${L2_ADDRESS:-0x47b7a4a6e1d0c9c69d82ca35a40fc4a4ac6ad0c3}"
AMOUNT_KAS="${AMOUNT_KAS:-1}"
RECIPIENT="${RECIPIENT:-kaspatest:qzhtq9xqs984c4ymh63kvw8q3v0g6nqmsfghszzplnslmjlh9msp60qmgvrx6}"

# Container configuration
ENTRY_SENDER_PATH="/app/entry_transaction_sender"

# Statistics
TOTAL_SENT=0
SUCCESSFUL=0
FAILED=0
START_TIME=$(date +%s)
PREVIOUS_BALANCE=""

# RPC endpoint for balance checks
RPC_ENDPOINT="https://localhost:8545/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

print_message() {
    echo -e "$1"
}

display_statistics() {
    local current_time=$(date +%s)
    local elapsed=$((current_time - START_TIME))
    local hours=$((elapsed / 3600))
    local minutes=$(((elapsed % 3600) / 60))
    local seconds=$((elapsed % 60))

    echo ""
    echo -e "${BLUE}=== Statistics ===${NC}"
    echo "Running time: $(printf '%02d:%02d:%02d' $hours $minutes $seconds)"
    echo -e "Total sent:   ${YELLOW}$TOTAL_SENT${NC}"
    echo -e "Successful:   ${GREEN}$SUCCESSFUL${NC}"
    echo -e "Failed:       ${RED}$FAILED${NC}"
    if [ $TOTAL_SENT -gt 0 ]; then
        local success_rate=$((SUCCESSFUL * 100 / TOTAL_SENT))
        echo "Success rate: ${success_rate}%"
    fi
    echo "=================="
    echo ""
}

check_l2_balance() {
    local address="$1"

    # Query balance via RPC and convert hex to decimal (wei)
    local balance_wei=$(curl -sk -X POST "$RPC_ENDPOINT" \
        -H "Content-Type: application/json" \
        -d "{
            \"jsonrpc\": \"2.0\",
            \"method\": \"eth_getBalance\",
            \"params\": [\"$address\", \"latest\"],
            \"id\": 1
        }" 2>/dev/null | \
        jq -r '.result | ltrimstr("0x") | "ibase=16;\(ascii_upcase)"' 2>/dev/null | \
        bc 2>/dev/null || echo "0")

    echo "$balance_wei"
}

check_prerequisites() {
    # Check if Docker container is running
    if ! docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        print_message "${RED}Error: Container '${CONTAINER_NAME}' is not running${NC}\n"
        print_message "Start the container first:"
        print_message "  ${YELLOW}docker compose --profile frontend-w1 up -d${NC}\n"
        print_message "Available containers:"
        docker ps --format "table {{.Names}}\t{{.Status}}"
        exit 1
    fi

    # Verify entry_transaction_sender binary exists in container
    if ! docker exec "$CONTAINER_NAME" test -f "$ENTRY_SENDER_PATH" 2>/dev/null; then
        print_message "${RED}Error: entry_transaction_sender not found in container${NC}"
        print_message "  Container: $CONTAINER_NAME"
        print_message "  Expected: $ENTRY_SENDER_PATH"
        exit 1
    fi

    print_message "${GREEN}✓ Container '${CONTAINER_NAME}' is ready${NC}"
}

# ============================================================================
# TRANSACTION FUNCTIONS
# ============================================================================

send_entry_transaction() {
    TOTAL_SENT=$((TOTAL_SENT + 1))

    print_message "${BLUE}[TX #$TOTAL_SENT] Sending entry transaction...${NC}"
    print_message "  L2 Address: $L2_ADDRESS"
    print_message "  Amount:     $AMOUNT_KAS"
    print_message "  Recipient:  $RECIPIENT"

    # Execute entry transaction sender in Docker container
    if output=$(docker exec "$CONTAINER_NAME" "$ENTRY_SENDER_PATH" \
        --recipient "$RECIPIENT" \
        --amount "$AMOUNT_KAS" \
        --l2-address "$L2_ADDRESS" 2>&1); then

        SUCCESSFUL=$((SUCCESSFUL + 1))
        print_message "${GREEN}✅ Transaction #$TOTAL_SENT sent successfully${NC}"

        # Extract and display transaction ID if available
        if tx_id=$(echo "$output" | grep -i "transaction" | grep -oE '0x[a-fA-F0-9]{64}'); then
            print_message "  TX ID: $tx_id"
        fi

        # Check L2 balance and show increase
        print_message "${YELLOW}⏳ Checking L2 balance...${NC}"
        local current_balance=$(check_l2_balance "$L2_ADDRESS")

        print_message "  Current balance: ${GREEN}${current_balance} wei${NC}"

        # Check if balance increased from previous
        if [ -n "$PREVIOUS_BALANCE" ] && [ "$PREVIOUS_BALANCE" != "0" ]; then
            local increase=$((current_balance - PREVIOUS_BALANCE))
            if [ $increase -gt 0 ]; then
                print_message "  Increase: ${GREEN}+${increase} wei${NC}"
            elif [ $increase -eq 0 ]; then
                print_message "  Status: ${YELLOW}⚠ Balance unchanged${NC}"
            fi
        fi

        # Store current balance for next comparison
        PREVIOUS_BALANCE="$current_balance"

    else
        FAILED=$((FAILED + 1))
        print_message "${RED}❌ Transaction #$TOTAL_SENT failed${NC}"
        print_message "${RED}Error: $output${NC}"
    fi
}

# ============================================================================
# MAIN
# ============================================================================

main() {
    # Display header
    echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║        Periodic Entry Transaction Sender              ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo "Configuration:"
    echo "  Container:  $CONTAINER_NAME"
    echo "  Interval:   ${INTERVAL_SECONDS}s"
    echo "  L2 Address: $L2_ADDRESS"
    echo "  Amount:     $AMOUNT_KAS"
    echo "  Recipient:  $RECIPIENT"
    echo ""

    # Check prerequisites
    check_prerequisites
    echo ""

    # Get initial L2 balance
    print_message "${YELLOW}⏳ Checking initial L2 balance...${NC}"
    PREVIOUS_BALANCE=$(check_l2_balance "$L2_ADDRESS")
    print_message "  Initial balance: ${GREEN}${PREVIOUS_BALANCE} wei${NC}"
    echo ""

    # Setup clean shutdown handler
    trap 'echo -e "\n${YELLOW}Shutting down...${NC}"; display_statistics; exit 0' INT TERM

    # Main transaction loop
    while true; do
        send_entry_transaction
        display_statistics

        # Check if single-run mode
        if [ "$INTERVAL_SECONDS" -le 0 ]; then
            print_message "${YELLOW}Single transaction mode - exiting${NC}"
            break
        fi

        # Wait for next transaction
        print_message "${YELLOW}Waiting ${INTERVAL_SECONDS}s for next transaction...${NC}"
        sleep "$INTERVAL_SECONDS"
    done

    display_statistics
}

# ============================================================================
# ENTRY POINT
# ============================================================================

main "$@"
