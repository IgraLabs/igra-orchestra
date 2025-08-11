#!/bin/bash

# IGRA Orchestra Automated Backup Script for Cron
# This script is designed to be run by cron for automated backups
# It calls backup.sh which handles both backup and S3 upload

set -e

# Script configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOG_DIR="$HOME/.backups/cron-logs"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
LOG_FILE="$LOG_DIR/backup_cron_${TIMESTAMP}.log"

# Create log directory if it doesn't exist
mkdir -p "$LOG_DIR"

# Function for logging
log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

# Redirect all output to log file and console
exec > >(tee -a "$LOG_FILE")
exec 2>&1

log_message "===== Automated Backup Started ====="
log_message "Script Directory: $SCRIPT_DIR"
log_message "Project Root: $PROJECT_ROOT"

# Change to project directory
cd "$PROJECT_ROOT" || {
    log_message "ERROR: Failed to change to project directory: $PROJECT_ROOT"
    exit 1
}

# Check if .env file exists
if [ ! -f ".env" ]; then
    log_message "ERROR: .env file not found in project root"
    exit 1
fi

# Source .env file to get configuration
# Use a simpler approach that handles most .env formats
set -a  # Mark all new variables for export
source .env
set +a  # Turn off auto-export

# Get containers to backup from environment or use defaults
BACKUP_CONTAINERS="${CRON_BACKUP_CONTAINERS:-viaduct}"
# Remove any quotes that might have been added
BACKUP_CONTAINERS=$(echo "$BACKUP_CONTAINERS" | tr -d '"')
log_message "Containers to backup: $BACKUP_CONTAINERS"

# Debug: Show relevant environment variables (after parsing)
log_message "DEBUG: Environment variables after .env parsing:"
log_message "  NETWORK=${NETWORK:-<not set>}"
log_message "  AWS_PROFILE=${AWS_PROFILE:-<not set>}"
log_message "  S3_BACKUP_AUTO_UPLOAD=${S3_BACKUP_AUTO_UPLOAD:-<not set>}"
log_message "  CRON_BACKUP_CONTAINERS=${CRON_BACKUP_CONTAINERS:-<not set>}"

# Check S3 configuration status
# Remove any quotes from the S3_BACKUP_AUTO_UPLOAD value
S3_UPLOAD_ENABLED=$(echo "${S3_BACKUP_AUTO_UPLOAD:-false}" | tr -d '"' | tr '[:upper:]' '[:lower:]')
if [ "$S3_UPLOAD_ENABLED" = "true" ]; then
    log_message "S3 auto-upload is ENABLED (backup.sh will handle upload)"
    
    # Check for AWS credentials
    # Remove quotes from AWS_PROFILE if present
    AWS_PROFILE=$(echo "${AWS_PROFILE:-}" | tr -d '"')
    
    if [ -n "$AWS_PROFILE" ]; then
        log_message "Using AWS profile: $AWS_PROFILE"
        export AWS_PROFILE
        # Test with the profile
        if aws --profile "$AWS_PROFILE" sts get-caller-identity &>/dev/null; then
            log_message "AWS credentials verified successfully with profile: $AWS_PROFILE"
        else
            log_message "WARNING: AWS profile $AWS_PROFILE exists but credentials may not be valid"
            log_message "Testing command: aws --profile $AWS_PROFILE sts get-caller-identity"
        fi
    elif aws sts get-caller-identity &>/dev/null; then
        log_message "AWS credentials configured successfully (default profile)"
    else
        log_message "WARNING: AWS credentials not configured. S3 upload may fail."
        log_message "TIP: Configure AWS credentials with: aws configure --profile igra-labs"
        log_message "     Then set in .env: AWS_PROFILE=igra-labs"
    fi
else
    log_message "S3 auto-upload is DISABLED (local backup only)"
fi

# Track success and failure
TOTAL_CONTAINERS=0
SUCCESSFUL_BACKUPS=0
FAILED_BACKUPS=0

# Perform backups for each container
for container in $BACKUP_CONTAINERS; do
    TOTAL_CONTAINERS=$((TOTAL_CONTAINERS + 1))
    
    log_message "----------------------------------------"
    log_message "Processing container: $container"
    log_message "Executing: $SCRIPT_DIR/backup.sh $container"
    
    # Run backup.sh which handles everything
    if "$SCRIPT_DIR/backup.sh" "$container" 2>&1; then
        log_message "SUCCESS: Backup completed for container: $container"
        SUCCESSFUL_BACKUPS=$((SUCCESSFUL_BACKUPS + 1))
    else
        EXIT_CODE=$?
        log_message "ERROR: Backup failed for container: $container (exit code: $EXIT_CODE)"
        FAILED_BACKUPS=$((FAILED_BACKUPS + 1))
    fi
done

# Clean up old log files (keep last 30 days)
log_message "Cleaning up old log files..."
find "$LOG_DIR" -name "backup_cron_*.log" -type f -mtime +30 -delete 2>/dev/null || true
DELETED_COUNT=$(find "$LOG_DIR" -name "backup_cron_*.log" -type f -mtime +30 2>/dev/null | wc -l || echo "0")
if [ "$DELETED_COUNT" -gt 0 ]; then
    log_message "Deleted $DELETED_COUNT old log files"
fi

# Summary
log_message "===== Backup Summary ====="
log_message "Total containers: $TOTAL_CONTAINERS"
log_message "Successful backups: $SUCCESSFUL_BACKUPS"
log_message "Failed backups: $FAILED_BACKUPS"
log_message "Log file: $LOG_FILE"

# Show location of backup files
if [ "$SUCCESSFUL_BACKUPS" -gt 0 ]; then
    log_message ""
    log_message "Backup files location:"
    for container in $BACKUP_CONTAINERS; do
        BACKUP_DIR="$HOME/.backups/${container}-backups"
        if [ -d "$BACKUP_DIR" ]; then
            LATEST_BACKUP=$(ls -t "$BACKUP_DIR"/*.tar.gz 2>/dev/null | head -1)
            if [ -n "$LATEST_BACKUP" ]; then
                log_message "  $container: $LATEST_BACKUP"
            fi
        fi
    done
fi

log_message "===== Automated Backup Completed ====="

# Exit with error if any backups failed
if [ "$FAILED_BACKUPS" -gt 0 ]; then
    exit 1
fi

exit 0