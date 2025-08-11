#!/bin/bash

# IGRA Orchestra Cron Setup Script
# This script sets up automated backups via cron

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CRON_SCRIPT="$SCRIPT_DIR/cron-backup.sh"

# Function for colored output
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

print_info "===== IGRA Orchestra Cron Setup ====="
print_info "Project root: $PROJECT_ROOT"
print_info "Cron script: $CRON_SCRIPT"

# Check if cron script exists
if [ ! -f "$CRON_SCRIPT" ]; then
    print_error "Cron script not found: $CRON_SCRIPT"
    exit 1
fi

# Make cron script executable
chmod +x "$CRON_SCRIPT"
print_info "Made cron script executable"

# Function to check if cron job already exists
cron_job_exists() {
    crontab -l 2>/dev/null | grep -q "$CRON_SCRIPT"
}

# Function to add cron job
add_cron_job() {
    local schedule="$1"
    local job_cmd="cd $PROJECT_ROOT && $CRON_SCRIPT >> /dev/null 2>&1"

    # Create a temporary file for the new crontab
    local temp_cron=$(mktemp)

    # Get existing crontab (if any)
    crontab -l 2>/dev/null > "$temp_cron" || true

    # Add new cron job
    echo "$schedule $job_cmd" >> "$temp_cron"

    # Install the new crontab
    crontab "$temp_cron"

    # Clean up
    rm "$temp_cron"
}

# Function to remove existing cron jobs
remove_existing_jobs() {
    local temp_cron=$(mktemp)

    # Get existing crontab, remove our jobs
    crontab -l 2>/dev/null | grep -v "$CRON_SCRIPT" > "$temp_cron" || true

    # Install the cleaned crontab
    if [ -s "$temp_cron" ]; then
        crontab "$temp_cron"
    else
        # No other jobs left, remove crontab
        crontab -r 2>/dev/null || true
    fi

    # Clean up
    rm "$temp_cron"
}

# Parse command line arguments
ACTION="${1:-install}"

case "$ACTION" in
    install)
        print_info "Installing cron jobs for automated backups..."

        # Check if cron jobs already exist
        if cron_job_exists; then
            print_warning "Cron jobs already exist. Removing old entries..."
            remove_existing_jobs
        fi

        # Add cron jobs for 5 AM and 5 PM
        print_info "Adding cron job for 5:00 AM daily..."
        add_cron_job "0 5 * * *"

        print_info "Adding cron job for 7:00 PM daily..."
        add_cron_job "0 19 * * *"

        print_info "Cron jobs installed successfully!"
        print_info ""
        print_info "Current crontab entries for IGRA Orchestra:"
        crontab -l 2>/dev/null | grep "$CRON_SCRIPT" || print_warning "No entries found"

        print_info ""
        print_info "To configure backup settings, edit your .env file:"
        print_info "  CRON_BACKUP_CONTAINERS=\"viaduct kaspad\"  # Containers to backup"
        print_info "  S3_BACKUP_AUTO_UPLOAD=true                # Enable S3 upload"
        print_info "  AWS_PROFILE=igra-labs                     # AWS profile to use"
        ;;

    uninstall|remove)
        print_info "Removing cron jobs for automated backups..."

        if cron_job_exists; then
            remove_existing_jobs
            print_info "Cron jobs removed successfully!"
        else
            print_warning "No cron jobs found to remove"
        fi
        ;;

    status)
        print_info "Current cron jobs for IGRA Orchestra:"
        if cron_job_exists; then
            crontab -l 2>/dev/null | grep "$CRON_SCRIPT"
        else
            print_warning "No cron jobs installed"
        fi

        print_info ""
        print_info "Checking recent backup logs..."
        LOG_DIR="$HOME/.backups/cron-logs"
        if [ -d "$LOG_DIR" ]; then
            print_info "Recent log files:"
            ls -lt "$LOG_DIR" 2>/dev/null | head -6 | tail -5
        else
            print_warning "No log directory found at: $LOG_DIR"
        fi
        ;;

    test)
        print_info "Testing cron backup script..."
        print_info "This will run the backup script once for testing"
        print_info ""

        read -p "Continue with test? (y/N) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            "$CRON_SCRIPT"
        else
            print_info "Test cancelled"
        fi
        ;;

    *)
        print_error "Unknown action: $ACTION"
        print_info "Usage: $0 [install|uninstall|status|test]"
        print_info "  install    - Install cron jobs (default)"
        print_info "  uninstall  - Remove cron jobs"
        print_info "  status     - Show current cron jobs and recent logs"
        print_info "  test       - Run the backup script once for testing"
        exit 1
        ;;
esac

print_info "===== Setup Complete ====="