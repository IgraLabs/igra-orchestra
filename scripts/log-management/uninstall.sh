#!/bin/bash

# Log Cleanup Automation - Uninstallation Script
# Removes log cleanup script, cron job, and related configurations

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
INSTALLED_SCRIPT="/usr/local/bin/log-cleanup"
CONFIG_FILE="/etc/log-cleanup.conf"
CRON_FILE="/etc/cron.d/log-cleanup"
AUDIT_LOG_DIR="/var/log/log-cleanup"
SYSTEMD_SERVICE="/etc/systemd/system/log-cleanup.service"
SYSTEMD_TIMER="/etc/systemd/system/log-cleanup.timer"

# Print colored message
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Check if running with sudo
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        print_message "$RED" "Error: This uninstallation script must be run with sudo privileges"
        print_message "$YELLOW" "Please run: sudo $0"
        exit 1
    fi
}

# Remove cron job
remove_cron_job() {
    print_message "$BLUE" "Removing cron job..."
    
    if [[ -f "$CRON_FILE" ]]; then
        rm -f "$CRON_FILE"
        
        # Reload cron service
        if command -v systemctl &> /dev/null; then
            systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
        else
            service cron reload 2>/dev/null || service crond reload 2>/dev/null || true
        fi
        
        print_message "$GREEN" "✓ Removed cron job: $CRON_FILE"
    else
        print_message "$YELLOW" "  Cron job not found (already removed or not installed)"
    fi
}

# Remove systemd timer and service
remove_systemd_units() {
    print_message "$BLUE" "Removing systemd units..."
    
    local units_removed=false
    
    # Stop and disable timer if it exists and is enabled
    if [[ -f "$SYSTEMD_TIMER" ]]; then
        if systemctl is-enabled --quiet log-cleanup.timer 2>/dev/null; then
            systemctl stop log-cleanup.timer
            systemctl disable log-cleanup.timer
        fi
        rm -f "$SYSTEMD_TIMER"
        print_message "$GREEN" "✓ Removed systemd timer"
        units_removed=true
    fi
    
    # Remove service unit
    if [[ -f "$SYSTEMD_SERVICE" ]]; then
        rm -f "$SYSTEMD_SERVICE"
        print_message "$GREEN" "✓ Removed systemd service"
        units_removed=true
    fi
    
    # Reload systemd if units were removed
    if [[ "$units_removed" == "true" ]]; then
        systemctl daemon-reload
    else
        print_message "$YELLOW" "  Systemd units not found (already removed or not installed)"
    fi
}

# Remove installed script
remove_script() {
    print_message "$BLUE" "Removing cleanup script..."
    
    if [[ -f "$INSTALLED_SCRIPT" ]]; then
        rm -f "$INSTALLED_SCRIPT"
        print_message "$GREEN" "✓ Removed cleanup script: $INSTALLED_SCRIPT"
    else
        print_message "$YELLOW" "  Cleanup script not found (already removed)"
    fi
}

# Handle configuration file
handle_config_file() {
    if [[ -f "$CONFIG_FILE" ]]; then
        print_message "$BLUE" "Configuration file found: $CONFIG_FILE"
        read -p "Do you want to remove the configuration file? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            rm -f "$CONFIG_FILE"
            print_message "$GREEN" "✓ Removed configuration file"
        else
            print_message "$YELLOW" "  Kept configuration file: $CONFIG_FILE"
        fi
    else
        print_message "$YELLOW" "  Configuration file not found"
    fi
}

# Handle audit logs
handle_audit_logs() {
    if [[ -d "$AUDIT_LOG_DIR" ]]; then
        # Check if directory contains logs
        if [[ -n "$(ls -A "$AUDIT_LOG_DIR" 2>/dev/null)" ]]; then
            print_message "$BLUE" "Audit log directory found: $AUDIT_LOG_DIR"
            
            # Show size of logs
            local log_size=$(du -sh "$AUDIT_LOG_DIR" 2>/dev/null | cut -f1)
            print_message "$YELLOW" "  Directory size: $log_size"
            
            read -p "Do you want to remove audit logs? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                rm -rf "$AUDIT_LOG_DIR"
                print_message "$GREEN" "✓ Removed audit log directory"
            else
                print_message "$YELLOW" "  Kept audit logs: $AUDIT_LOG_DIR"
            fi
        else
            # Empty directory, remove it
            rmdir "$AUDIT_LOG_DIR" 2>/dev/null || true
            print_message "$GREEN" "✓ Removed empty audit log directory"
        fi
    else
        print_message "$YELLOW" "  Audit log directory not found"
    fi
}

# Check for any remaining processes
check_running_processes() {
    print_message "$BLUE" "Checking for running cleanup processes..."
    
    local pids=$(pgrep -f "log-cleanup" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        print_message "$YELLOW" "Warning: Found running cleanup processes (PIDs: $pids)"
        read -p "Do you want to terminate them? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            pkill -f "log-cleanup" 2>/dev/null || true
            print_message "$GREEN" "✓ Terminated running processes"
        fi
    else
        print_message "$GREEN" "✓ No running cleanup processes found"
    fi
}

# Display uninstallation summary
display_summary() {
    print_message "$GREEN" ""
    print_message "$GREEN" "=========================================="
    print_message "$GREEN" "  LOG CLEANUP UNINSTALLATION COMPLETED    "
    print_message "$GREEN" "=========================================="
    print_message "$GREEN" ""
    print_message "$GREEN" "The following components have been handled:"
    print_message "$GREEN" "  • Cleanup script"
    print_message "$GREEN" "  • Cron job"
    print_message "$GREEN" "  • Systemd units (if present)"
    print_message "$GREEN" "  • Configuration file (if requested)"
    print_message "$GREEN" "  • Audit logs (if requested)"
    print_message "$GREEN" ""
    
    # Check if anything was kept
    local kept_items=()
    [[ -f "$CONFIG_FILE" ]] && kept_items+=("Configuration: $CONFIG_FILE")
    [[ -d "$AUDIT_LOG_DIR" ]] && kept_items+=("Audit logs: $AUDIT_LOG_DIR")
    
    if [[ ${#kept_items[@]} -gt 0 ]]; then
        print_message "$YELLOW" "The following items were kept:"
        for item in "${kept_items[@]}"; do
            print_message "$YELLOW" "  • $item"
        done
        print_message "$YELLOW" ""
        print_message "$YELLOW" "To completely remove all traces, manually delete:"
        for item in "${kept_items[@]}"; do
            print_message "$YELLOW" "  sudo rm -rf ${item#*: }"
        done
    else
        print_message "$GREEN" "All components have been removed successfully"
    fi
    
    print_message "$GREEN" "=========================================="
}

# Confirmation prompt
confirm_uninstall() {
    print_message "$YELLOW" "WARNING: This will uninstall the log cleanup automation system"
    print_message "$YELLOW" "The following will be removed:"
    print_message "$YELLOW" "  • Cleanup script from $INSTALLED_SCRIPT"
    print_message "$YELLOW" "  • Cron job from $CRON_FILE"
    print_message "$YELLOW" "  • Systemd units (if present)"
    print_message "$YELLOW" ""
    print_message "$YELLOW" "You will be asked about:"
    print_message "$YELLOW" "  • Configuration file"
    print_message "$YELLOW" "  • Audit log directory"
    echo
    
    read -p "Do you want to continue with uninstallation? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_message "$RED" "Uninstallation cancelled"
        exit 0
    fi
}

# Main uninstallation process
main() {
    print_message "$BLUE" "Log Cleanup Automation - Uninstallation Script"
    print_message "$BLUE" "==============================================="
    echo
    
    # Run uninstallation steps
    check_privileges
    confirm_uninstall
    check_running_processes
    remove_cron_job
    remove_systemd_units
    remove_script
    handle_config_file
    handle_audit_logs
    
    # Display summary
    display_summary
}

# Handle command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --force)
            # Skip confirmation prompt
            FORCE_MODE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --force    Skip confirmation prompts"
            echo "  --help     Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Run main function
main "$@"