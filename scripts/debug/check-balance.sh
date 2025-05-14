#!/bin/bash

# Ensure the path to your client is correct.
# If test_client is not in the current directory's target/release,
# you might need to adjust the path.
client_command="./build/repos/kaswallet/target/release/test_client"

echo "Starting balance monitor for $client_command"
echo "Press Ctrl+C to stop."

while true
do
    # Run the command and capture its output (both stdout and stderr)
    # The output is stored in the cmd_output variable
    cmd_output=$($client_command 2>&1)

    # Parse the available balance
    # 1. Use grep to find the line containing "Balance: Available="
    # 2. Use awk to split that line by "=" and then by "," and print the relevant part.
    #    -F'[=,]' sets the field separator to either '=' or ','.
    #    We want the second field after splitting by '=', which is the value and the rest of the line (e.g., "999999975475, Pending=0")
    #    Then, from that, we effectively want the part before the comma.
    #    awk -F'[=,]' '{print $2}' correctly extracts the numeric balance.
    available_balance=$(echo "$cmd_output" | grep 'Balance: Available=' | awk -F'[=,]' '{print $2}')

    # Get current timestamp
    current_time=$(date "+%Y-%m-%d %H:%M:%S")

    # Check if available_balance was successfully parsed
    if [ -n "$available_balance" ]; then
        echo "[$current_time] Available Balance: $available_balance"
    else
        echo "[$current_time] Error: Balance information not found in output"
        # Optionally, print the raw output for debugging if balance is not found
        # echo "Raw output:"
        # echo "$cmd_output"
    fi

    # Wait for 1 second
    sleep 1
done
