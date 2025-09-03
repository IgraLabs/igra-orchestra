#!/bin/bash

# Log Cleanup Automation - Installation Script
# Installs log cleanup script and sets up cron job for Ubuntu systems

set -euo pipefail

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLEANUP_SCRIPT="${SCRIPT_DIR}/cleanup-logs.sh"
INSTALL_DIR="/usr/local/bin"
INSTALLED_SCRIPT="${INSTALL_DIR}/log-cleanup"
CONFIG_FILE="/etc/log-cleanup.conf"
CRON_FILE="/etc/cron.d/log-cleanup"
AUDIT_LOG_DIR="/var/log/log-cleanup"

# Print colored message
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${NC}"
}

# Check if running with sudo
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        print_message "$RED" "Error: This installation script must be run with sudo privileges"
        print_message "$YELLOW" "Please run: sudo $0"
        exit 1
    fi
}

# Check Ubuntu distribution
check_distribution() {
    if [[ ! -f /etc/os-release ]]; then
        print_message "$RED" "Error: Cannot determine OS distribution"
        exit 1
    fi
    
    . /etc/os-release
    
    if [[ "$ID" != "ubuntu" ]] && [[ "$ID_LIKE" != *"ubuntu"* ]]; then
        print_message "$YELLOW" "Warning: This script is designed for Ubuntu systems"
        print_message "$YELLOW" "Current distribution: $ID"
        read -p "Continue anyway? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_message "$RED" "Installation cancelled"
            exit 1
        fi
    else
        print_message "$GREEN" "✓ Ubuntu distribution detected: $PRETTY_NAME"
    fi
}

# Check required commands
check_requirements() {
    local missing_commands=()
    local required_commands=("find" "tail" "df" "awk" "sort" "mktemp" "flock")
    
    # Check for systemctl or service
    if command -v systemctl &>/dev/null; then
        required_commands+=("systemctl")
    elif command -v service &>/dev/null; then
        required_commands+=("service")
    else
        missing_commands+=("systemctl or service")
    fi
    
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            missing_commands+=("$cmd")
        fi
    done
    
    if [[ ${#missing_commands[@]} -gt 0 ]]; then
        print_message "$RED" "Error: Missing required commands: ${missing_commands[*]}"
        print_message "$YELLOW" "Please install missing dependencies first"
        exit 1
    fi
    
    print_message "$GREEN" "✓ All required commands are available"
}

# Check if already installed
check_existing_installation() {
    if [[ -f "$INSTALLED_SCRIPT" ]]; then
        print_message "$YELLOW" "Warning: Log cleanup script is already installed"
        read -p "Do you want to reinstall/update? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_message "$RED" "Installation cancelled"
            exit 1
        fi
    fi
}

# Create audit log directory
create_directories() {
    print_message "$BLUE" "Creating directories..."
    
    if [[ ! -d "$AUDIT_LOG_DIR" ]]; then
        mkdir -p "$AUDIT_LOG_DIR"
        chmod 755 "$AUDIT_LOG_DIR"
        print_message "$GREEN" "✓ Created audit log directory: $AUDIT_LOG_DIR"
    else
        print_message "$GREEN" "✓ Audit log directory already exists"
    fi
    
    if [[ ! -d "$INSTALL_DIR" ]]; then
        mkdir -p "$INSTALL_DIR"
        print_message "$GREEN" "✓ Created installation directory: $INSTALL_DIR"
    fi
}

# Install the cleanup script
install_cleanup_script() {
    print_message "$BLUE" "Installing cleanup script..."
    
    if [[ ! -f "$CLEANUP_SCRIPT" ]]; then
        print_message "$RED" "Error: Cleanup script not found: $CLEANUP_SCRIPT"
        exit 1
    fi
    
    # Copy script to installation directory
    cp "$CLEANUP_SCRIPT" "$INSTALLED_SCRIPT"
    chmod 755 "$INSTALLED_SCRIPT"
    chown root:root "$INSTALLED_SCRIPT"
    
    print_message "$GREEN" "✓ Installed cleanup script to: $INSTALLED_SCRIPT"
}

# Create configuration file
create_config_file() {
    print_message "$BLUE" "Creating configuration file..."
    
    cat > "$CONFIG_FILE" << 'EOF'
# Log Cleanup Configuration File
# Edit these values to customize log cleanup behavior

# Number of lines to retain in truncated logs
LOG_RETENTION_LINES=10000

# Log directory to clean
LOG_DIR=/var/log

# Minimum disk space threshold in GB
MIN_DISK_SPACE_GB=5

# Dry run mode (true/false)
DRY_RUN=false

# Audit log directory
AUDIT_LOG_DIR=/var/log/log-cleanup
EOF
    
    # Set restrictive permissions for security
    chmod 600 "$CONFIG_FILE"
    chown root:root "$CONFIG_FILE"
    print_message "$GREEN" "✓ Created configuration file: $CONFIG_FILE (mode 600)"
}

# Install cron job
install_cron_job() {
    print_message "$BLUE" "Installing cron job..."
    
    # Detect and start cron service if needed
    local cron_service=""
    if command -v systemctl &>/dev/null; then
        if systemctl list-units --type=service | grep -q "cron.service"; then
            cron_service="cron"
        elif systemctl list-units --type=service | grep -q "crond.service"; then
            cron_service="crond"
        fi
        
        if [[ -n "$cron_service" ]] && ! systemctl is-active --quiet "$cron_service"; then
            print_message "$YELLOW" "Starting $cron_service service..."
            systemctl start "$cron_service"
        fi
    elif command -v service &>/dev/null; then
        if service cron status &>/dev/null; then
            cron_service="cron"
        elif service crond status &>/dev/null; then
            cron_service="crond"
        fi
    fi
    
    # Create cron job file
    cat > "$CRON_FILE" << EOF
# Log Cleanup Automation - Daily at 3:00 AM
# Installed by log-cleanup installation script

# Load configuration
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

# Run cleanup daily at 3:00 AM (secure environment loading)
0 3 * * * root /bin/bash -c "test -f $CONFIG_FILE && . $CONFIG_FILE && $INSTALLED_SCRIPT" >> $AUDIT_LOG_DIR/cron.log 2>&1
EOF
    
    chmod 644 "$CRON_FILE"
    
    # Reload cron service
    if command -v systemctl &> /dev/null; then
        systemctl reload cron 2>/dev/null || systemctl reload crond 2>/dev/null || true
    else
        service cron reload 2>/dev/null || service crond reload 2>/dev/null || true
    fi
    
    print_message "$GREEN" "✓ Installed cron job: $CRON_FILE"
    print_message "$GREEN" "✓ Cleanup will run daily at 3:00 AM"
}

# Create systemd timer as alternative (optional)
create_systemd_timer() {
    print_message "$BLUE" "Creating systemd timer (optional alternative to cron)..."
    
    # Create service unit
    cat > /etc/systemd/system/log-cleanup.service << EOF
[Unit]
Description=Log Cleanup Service
After=multi-user.target

[Service]
Type=oneshot
EnvironmentFile=-$CONFIG_FILE
ExecStart=$INSTALLED_SCRIPT
StandardOutput=append:$AUDIT_LOG_DIR/systemd.log
StandardError=append:$AUDIT_LOG_DIR/systemd-error.log

[Install]
WantedBy=multi-user.target
EOF
    
    # Create timer unit
    cat > /etc/systemd/system/log-cleanup.timer << EOF
[Unit]
Description=Daily Log Cleanup Timer
Requires=log-cleanup.service

[Timer]
OnCalendar=daily
OnCalendar=*-*-* 03:00:00
AccuracySec=1h
Persistent=true

[Install]
WantedBy=timers.target
EOF
    
    # Reload systemd but don't enable by default
    systemctl daemon-reload
    
    print_message "$GREEN" "✓ Created systemd timer (not enabled by default)"
    print_message "$YELLOW" "  To use systemd instead of cron, run:"
    print_message "$YELLOW" "  sudo systemctl enable --now log-cleanup.timer"
    print_message "$YELLOW" "  sudo rm $CRON_FILE"
}

# Run initial cleanup (optional)
run_initial_cleanup() {
    print_message "$BLUE" "Running initial cleanup in dry-run mode..."
    
    # Run with timeout and error handling
    if timeout 300 env DRY_RUN=true "$INSTALLED_SCRIPT" --dry-run; then
        print_message "$GREEN" "✓ Dry-run completed successfully"
    else
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
            print_message "$RED" "✗ Dry-run timed out after 5 minutes"
        else
            print_message "$YELLOW" "⚠ Dry-run completed with warnings"
        fi
    fi
    
    read -p "Do you want to run actual cleanup now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_message "$BLUE" "Running actual cleanup..."
        if timeout 600 "$INSTALLED_SCRIPT"; then
            print_message "$GREEN" "✓ Initial cleanup completed"
        else
            print_message "$YELLOW" "⚠ Cleanup completed with warnings"
        fi
    fi
}

# Display installation summary
display_summary() {
    print_message "$GREEN" ""
    print_message "$GREEN" "=========================================="
    print_message "$GREEN" "   LOG CLEANUP INSTALLATION COMPLETED     "
    print_message "$GREEN" "=========================================="
    print_message "$GREEN" ""
    print_message "$GREEN" "Installed components:"
    print_message "$GREEN" "  • Cleanup script: $INSTALLED_SCRIPT"
    print_message "$GREEN" "  • Configuration: $CONFIG_FILE"
    print_message "$GREEN" "  • Cron job: $CRON_FILE"
    print_message "$GREEN" "  • Audit logs: $AUDIT_LOG_DIR"
    print_message "$GREEN" ""
    print_message "$YELLOW" "Next steps:"
    print_message "$YELLOW" "  1. Edit configuration: sudo nano $CONFIG_FILE"
    print_message "$YELLOW" "  2. Test dry-run: sudo $INSTALLED_SCRIPT --dry-run"
    print_message "$YELLOW" "  3. Manual run: sudo $INSTALLED_SCRIPT"
    print_message "$YELLOW" "  4. View logs: tail -f $AUDIT_LOG_DIR/cleanup.log"
    print_message "$GREEN" ""
    print_message "$GREEN" "Automatic cleanup will run daily at 3:00 AM"
    print_message "$GREEN" "=========================================="
}

# Main installation process
main() {
    print_message "$BLUE" "Log Cleanup Automation - Installation Script"
    print_message "$BLUE" "============================================"
    echo
    
    # Run installation steps
    check_privileges
    check_distribution
    check_requirements
    check_existing_installation
    create_directories
    install_cleanup_script
    create_config_file
    install_cron_job
    create_systemd_timer
    
    # Optional initial run
    read -p "Do you want to test the installation now? (Y/n): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Nn]$ ]]; then
        run_initial_cleanup
    fi
    
    # Display summary
    display_summary
}

# Run main function
main "$@"