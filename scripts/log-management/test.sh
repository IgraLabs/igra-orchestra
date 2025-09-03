#!/bin/bash

# Test script for log cleanup automation
# Creates test log files and validates cleanup functionality

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test directory
TEST_DIR="/tmp/log-cleanup-test"
TEST_LOG_DIR="${TEST_DIR}/var/log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup-logs.sh"

# Print colored message
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Create test environment
setup_test_env() {
    print_message "$BLUE" "Setting up test environment..."
    
    # Clean up any existing test directory
    rm -rf "$TEST_DIR"
    
    # Create test directories
    mkdir -p "${TEST_LOG_DIR}"
    mkdir -p "${TEST_LOG_DIR}/apache2"
    mkdir -p "${TEST_LOG_DIR}/nginx"
    
    print_message "$GREEN" "✓ Created test directories"
}

# Create test log files
create_test_files() {
    print_message "$BLUE" "Creating test log files..."
    
    # Create .gz files (to be removed)
    echo "Old log content" | gzip > "${TEST_LOG_DIR}/syslog.1.gz"
    echo "Old log content" | gzip > "${TEST_LOG_DIR}/syslog.2.gz"
    echo "Old log content" | gzip > "${TEST_LOG_DIR}/auth.log.1.gz"
    echo "Old log content" | gzip > "${TEST_LOG_DIR}/apache2/access.log.1.gz"
    echo "Old log content" | gzip > "${TEST_LOG_DIR}/nginx/error.log.1.gz"
    
    # Create active log files (to be truncated)
    for i in {1..20000}; do
        echo "Log line $i - $(date)" >> "${TEST_LOG_DIR}/syslog"
    done
    
    for i in {1..15000}; do
        echo "Auth log line $i - $(date)" >> "${TEST_LOG_DIR}/auth.log"
    done
    
    for i in {1..10000}; do
        echo "Kernel log line $i - $(date)" >> "${TEST_LOG_DIR}/kern.log"
    done
    
    # Count created files
    local gz_count=$(find "$TEST_LOG_DIR" -name "*.gz" | wc -l)
    local log_count=$(find "$TEST_LOG_DIR" -type f ! -name "*.gz" | wc -l)
    
    print_message "$GREEN" "✓ Created $gz_count .gz files and $log_count active log files"
}

# Test dry-run mode
test_dry_run() {
    print_message "$BLUE" "\nTesting dry-run mode..."
    
    # Count files before dry-run
    local gz_before=$(find "$TEST_LOG_DIR" -name "*.gz" | wc -l)
    
    # Run cleanup in dry-run mode
    sudo LOG_DIR="$TEST_LOG_DIR" DRY_RUN=true "$CLEANUP_SCRIPT" --dry-run > /tmp/dry-run.log 2>&1
    
    # Count files after dry-run
    local gz_after=$(find "$TEST_LOG_DIR" -name "*.gz" | wc -l)
    
    if [[ $gz_before -eq $gz_after ]]; then
        print_message "$GREEN" "✓ Dry-run mode: No files were removed (expected)"
    else
        print_message "$RED" "✗ Dry-run mode: Files were removed (unexpected)"
        return 1
    fi
    
    # Check if dry-run output contains expected messages
    if grep -q "DRY-RUN" /tmp/dry-run.log; then
        print_message "$GREEN" "✓ Dry-run mode: Output contains DRY-RUN messages"
    else
        print_message "$RED" "✗ Dry-run mode: No DRY-RUN messages found"
        return 1
    fi
}

# Test .gz file removal
test_gz_removal() {
    print_message "$BLUE" "\nTesting .gz file removal..."
    
    # Count .gz files before cleanup
    local gz_before=$(find "$TEST_LOG_DIR" -name "*.gz" | wc -l)
    print_message "$YELLOW" "  .gz files before cleanup: $gz_before"
    
    # Run cleanup
    sudo LOG_DIR="$TEST_LOG_DIR" "$CLEANUP_SCRIPT" > /tmp/cleanup.log 2>&1
    
    # Count .gz files after cleanup
    local gz_after=$(find "$TEST_LOG_DIR" -name "*.gz" | wc -l)
    print_message "$YELLOW" "  .gz files after cleanup: $gz_after"
    
    if [[ $gz_after -eq 0 ]]; then
        print_message "$GREEN" "✓ All .gz files removed successfully"
    else
        print_message "$RED" "✗ Some .gz files remain: $gz_after"
        find "$TEST_LOG_DIR" -name "*.gz" -ls
        return 1
    fi
}

# Test log truncation
test_log_truncation() {
    print_message "$BLUE" "\nTesting log truncation..."
    
    # Check syslog truncation
    if [[ -f "${TEST_LOG_DIR}/syslog" ]]; then
        local lines=$(wc -l < "${TEST_LOG_DIR}/syslog")
        print_message "$YELLOW" "  Syslog lines after truncation: $lines"
        
        if [[ $lines -le 10000 ]]; then
            print_message "$GREEN" "✓ Syslog truncated to <= 10000 lines"
        else
            print_message "$RED" "✗ Syslog not properly truncated: $lines lines"
            return 1
        fi
    fi
    
    # Check auth.log truncation
    if [[ -f "${TEST_LOG_DIR}/auth.log" ]]; then
        local lines=$(wc -l < "${TEST_LOG_DIR}/auth.log")
        print_message "$YELLOW" "  Auth.log lines after truncation: $lines"
        
        if [[ $lines -le 10000 ]]; then
            print_message "$GREEN" "✓ Auth.log truncated to <= 10000 lines"
        else
            print_message "$RED" "✗ Auth.log not properly truncated: $lines lines"
            return 1
        fi
    fi
}

# Test disk space reporting
test_disk_space_reporting() {
    print_message "$BLUE" "\nTesting disk space reporting..."
    
    if grep -q "CLEANUP SUMMARY REPORT" /tmp/cleanup.log; then
        print_message "$GREEN" "✓ Cleanup summary report generated"
        
        # Extract and display key metrics
        grep "Files removed:" /tmp/cleanup.log || true
        grep "Logs truncated:" /tmp/cleanup.log || true
        grep "Space freed" /tmp/cleanup.log || true
    else
        print_message "$RED" "✗ No cleanup summary found"
        return 1
    fi
}

# Test error handling
test_error_handling() {
    print_message "$BLUE" "\nTesting error handling..."
    
    # Create a file with restricted permissions
    touch "${TEST_LOG_DIR}/restricted.log"
    chmod 000 "${TEST_LOG_DIR}/restricted.log"
    
    # Run cleanup (should handle permission error gracefully)
    sudo LOG_DIR="$TEST_LOG_DIR" "$CLEANUP_SCRIPT" > /tmp/error-test.log 2>&1 || true
    
    # Check if script continued despite error
    if grep -q "WARNING" /tmp/error-test.log; then
        print_message "$GREEN" "✓ Script handled permission errors gracefully"
    else
        print_message "$YELLOW" "⚠ No warning messages found for permission errors"
    fi
    
    # Clean up
    sudo rm -f "${TEST_LOG_DIR}/restricted.log"
}

# Cleanup test environment
cleanup_test_env() {
    print_message "$BLUE" "\nCleaning up test environment..."
    rm -rf "$TEST_DIR"
    rm -f /tmp/dry-run.log /tmp/cleanup.log /tmp/error-test.log
    print_message "$GREEN" "✓ Test environment cleaned up"
}

# Display test summary
display_summary() {
    print_message "$GREEN" "\n=========================================="
    print_message "$GREEN" "       LOG CLEANUP TEST COMPLETED         "
    print_message "$GREEN" "=========================================="
    print_message "$GREEN" ""
    print_message "$GREEN" "All tests passed successfully!"
    print_message "$GREEN" ""
    print_message "$YELLOW" "Next steps:"
    print_message "$YELLOW" "1. Run installation: sudo ./install.sh"
    print_message "$YELLOW" "2. Configure: sudo nano /etc/log-cleanup.conf"
    print_message "$YELLOW" "3. Test on real logs: sudo /usr/local/bin/log-cleanup --dry-run"
    print_message "$GREEN" "=========================================="
}

# Main test execution
main() {
    print_message "$BLUE" "Log Cleanup Automation - Test Suite"
    print_message "$BLUE" "===================================="
    
    # Check if cleanup script exists
    if [[ ! -f "$CLEANUP_SCRIPT" ]]; then
        print_message "$RED" "Error: Cleanup script not found: $CLEANUP_SCRIPT"
        exit 1
    fi
    
    # Check for sudo
    if [[ $EUID -ne 0 ]]; then
        print_message "$RED" "Error: Tests must be run with sudo"
        print_message "$YELLOW" "Please run: sudo $0"
        exit 1
    fi
    
    # Run tests
    setup_test_env
    create_test_files
    test_dry_run
    
    # Recreate files for actual cleanup test
    create_test_files
    test_gz_removal
    test_log_truncation
    test_disk_space_reporting
    test_error_handling
    
    # Cleanup and show summary
    cleanup_test_env
    display_summary
}

# Run main function
main "$@"