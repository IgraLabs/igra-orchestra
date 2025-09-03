#!/bin/bash

# Log Cleanup Automation Script
# Removes .gz compressed log files and truncates active logs to prevent disk exhaustion
# Designed for Ubuntu systems running Docker with syslog driver

set -euo pipefail

# Configuration Variables
LOG_RETENTION_LINES="${LOG_RETENTION_LINES:-10000}"
LOG_DIR="${LOG_DIR:-/var/log}"
DRY_RUN="${DRY_RUN:-false}"
MIN_DISK_SPACE_GB="${MIN_DISK_SPACE_GB:-5}"
AUDIT_LOG_DIR="/var/log/log-cleanup"
AUDIT_LOG_FILE="${AUDIT_LOG_DIR}/cleanup.log"
LOCK_FILE="/var/run/log-cleanup.lock"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Statistics tracking
TOTAL_FILES_REMOVED=0
TOTAL_SPACE_FREED=0
TOTAL_LOGS_TRUNCATED=0
INITIAL_DISK_USAGE=0
FINAL_DISK_USAGE=0
CLEANUP_ERRORS=""

# Create audit log directory if it doesn't exist
create_audit_dir() {
    if [[ ! -d "$AUDIT_LOG_DIR" ]]; then
        sudo mkdir -p "$AUDIT_LOG_DIR"
    fi
}

# Logging function
log_message() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    echo -e "${timestamp} [${level}] ${message}"
    
    # Also write to audit log if it exists
    if [[ -d "$AUDIT_LOG_DIR" ]]; then
        echo "${timestamp} [${level}] ${message}" >> "$AUDIT_LOG_FILE"
    fi
}

# Check if running with sufficient privileges
check_privileges() {
    if [[ $EUID -ne 0 ]]; then
        log_message "ERROR" "This script must be run with sudo privileges"
        exit 1
    fi
}

# Implement file locking to prevent concurrent runs
acquire_lock() {
    # Use flock for proper advisory locking
    exec 200>"$LOCK_FILE"
    if ! flock -n 200; then
        log_message "ERROR" "Another instance is already running"
        exit 1
    fi
    trap 'flock -u 200; rm -f "$LOCK_FILE"' EXIT
    log_message "DEBUG" "Lock acquired successfully"
}

# Get disk usage in GB for a directory
get_disk_usage() {
    local dir="$1"
    df "$dir" 2>/dev/null | awk 'NR==2 {printf "%.2f", $3/1048576}' || echo "0"
}

# Get available disk space in GB
get_available_space() {
    local dir="$1"
    df "$dir" 2>/dev/null | awk 'NR==2 {printf "%.2f", $4/1048576}' || echo "0"
}

# Check disk space before cleanup
check_disk_space() {
    local available=$(get_available_space "$LOG_DIR")
    
    log_message "INFO" "Available disk space: ${available} GB"
    
    # Use awk for more reliable arithmetic
    if awk -v a="$available" -v min="$MIN_DISK_SPACE_GB" 'BEGIN{exit !(a < min)}'; then
        log_message "WARNING" "Low disk space detected! Only ${available} GB available"
    fi
    
    INITIAL_DISK_USAGE=$(get_disk_usage "$LOG_DIR")
}

# Find and remove .gz compressed log files
remove_gz_files() {
    log_message "INFO" "Starting removal of .gz compressed log files"
    
    local count=0
    local total_size=0
    
    # Find all .gz files in log directory
    while IFS= read -r -d '' file; do
        if [[ -f "$file" ]]; then
            # Support both GNU and BSD stat
            local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo 0)
            local file_size_mb=$(echo "scale=2; $file_size / 1048576" | bc)
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_message "DRY-RUN" "Would remove: $file (${file_size_mb} MB)"
            else
                if rm -f "$file" 2>/dev/null; then
                    log_message "SUCCESS" "Removed: $file (${file_size_mb} MB)"
                    count=$((count + 1))
                    total_size=$((total_size + file_size))
                else
                    log_message "WARNING" "Failed to remove: $file"
                fi
            fi
        fi
    done < <(find "$LOG_DIR" -type f -name "*.gz" -print0 2>/dev/null)
    
    local total_size_mb=$(echo "scale=2; $total_size / 1048576" | bc)
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_message "INFO" "DRY-RUN: Would remove ${count} .gz files, freeing ${total_size_mb} MB"
    else
        log_message "INFO" "Removed ${count} .gz files, freed ${total_size_mb} MB"
        TOTAL_FILES_REMOVED=$count
        TOTAL_SPACE_FREED=$(echo "$TOTAL_SPACE_FREED + $total_size_mb" | bc)
    fi
}

# Truncate active log files while preserving recent lines
truncate_active_logs() {
    log_message "INFO" "Starting active log truncation (keeping last $LOG_RETENTION_LINES lines)"
    
    local count=0
    # Make log list configurable
    local logs_to_truncate=(${LOG_FILES_TO_TRUNCATE:-"syslog auth.log kern.log messages daemon.log user.log"})
    
    for log_name in "${logs_to_truncate[@]}"; do
        local log_file="${LOG_DIR}/${log_name}"
        
        if [[ -f "$log_file" ]] && [[ ! "$log_file" =~ \.gz$ ]]; then
            local original_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
            local original_size_mb=$(echo "scale=2; $original_size / 1048576" | bc)
            
            if [[ "$DRY_RUN" == "true" ]]; then
                log_message "DRY-RUN" "Would truncate: $log_file (current size: ${original_size_mb} MB)"
            else
                # Create secure temporary file with preserved lines
                local temp_file=$(mktemp -t log-cleanup.XXXXXX)
                chmod 600 "$temp_file"
                trap "rm -f '$temp_file'" EXIT
                
                if tail -n "$LOG_RETENTION_LINES" "$log_file" > "$temp_file" 2>/dev/null; then
                    # Preserve permissions and ownership (support both GNU and BSD)
                    local perms=$(stat -c %a "$log_file" 2>/dev/null || stat -f %A "$log_file" 2>/dev/null || echo "644")
                    local owner=$(stat -c %U:%G "$log_file" 2>/dev/null || stat -f %Su:%Sg "$log_file" 2>/dev/null || echo "root:root")
                    
                    # Replace original file
                    if mv -f "$temp_file" "$log_file" 2>/dev/null; then
                        chmod "$perms" "$log_file"
                        chown "$owner" "$log_file"
                        
                        local new_size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
                        local new_size_mb=$(echo "scale=2; $new_size / 1048576" | bc)
                        local freed_mb=$(echo "scale=2; ($original_size - $new_size) / 1048576" | bc)
                        
                        log_message "SUCCESS" "Truncated: $log_file (${original_size_mb} MB -> ${new_size_mb} MB, freed ${freed_mb} MB)"
                        count=$((count + 1))
                        TOTAL_SPACE_FREED=$(echo "$TOTAL_SPACE_FREED + $freed_mb" | bc)
                    else
                        log_message "WARNING" "Failed to truncate: $log_file"
                        rm -f "$temp_file"
                    fi
                else
                    log_message "WARNING" "Failed to read: $log_file"
                    rm -f "$temp_file"
                fi
            fi
        fi
    done
    
    # Handle Docker syslog entries
    truncate_docker_syslogs
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_message "INFO" "DRY-RUN: Would truncate ${count} log files"
    else
        log_message "INFO" "Truncated ${count} log files"
        TOTAL_LOGS_TRUNCATED=$count
    fi
}

# Handle Docker-specific syslog entries
truncate_docker_syslogs() {
    # Check if Docker is installed and running
    if ! command -v docker &> /dev/null; then
        log_message "DEBUG" "Docker not installed"
        return
    fi
    
    # Check Docker service with proper error handling
    if command -v systemctl &> /dev/null; then
        if ! systemctl is-active --quiet docker 2>/dev/null; then
            log_message "DEBUG" "Docker service not active"
            return
        fi
    elif command -v service &> /dev/null; then
        if ! service docker status &> /dev/null; then
            log_message "DEBUG" "Docker service not running"
            return
        fi
    fi
    
    log_message "INFO" "Checking for Docker syslog entries"
    
    # Look for igra-orchestra specific logs
    local docker_log_pattern="igra-orchestra"
    
    # Check main syslog for Docker entries
    if [[ -f "${LOG_DIR}/syslog" ]]; then
        local docker_lines=$(grep -c "$docker_log_pattern" "${LOG_DIR}/syslog" 2>/dev/null || echo 0)
        
        if [[ $docker_lines -gt 0 ]]; then
            log_message "INFO" "Found ${docker_lines} Docker-related entries in syslog"
            
            if [[ "$DRY_RUN" != "true" ]]; then
                # Simplified Docker log cleanup
                local temp_file=$(mktemp -t docker-cleanup.XXXXXX)
                chmod 600 "$temp_file"
                trap "rm -f '$temp_file'" EXIT
                
                # Simply truncate while keeping recent entries
                if tail -n "$LOG_RETENTION_LINES" "${LOG_DIR}/syslog" > "$temp_file" 2>/dev/null; then
                    mv -f "$temp_file" "${LOG_DIR}/syslog"
                else
                    log_message "WARNING" "Failed to truncate Docker syslog entries"
                    CLEANUP_ERRORS="${CLEANUP_ERRORS}docker-truncate;"
                fi
                
                log_message "SUCCESS" "Cleaned Docker-related syslog entries"
            fi
        fi
    fi
}

# Generate cleanup summary report
generate_summary() {
    FINAL_DISK_USAGE=$(get_disk_usage "$LOG_DIR")
    local space_freed_total=$(echo "$INITIAL_DISK_USAGE - $FINAL_DISK_USAGE" | bc)
    
    log_message "INFO" "========================================="
    log_message "INFO" "         CLEANUP SUMMARY REPORT          "
    log_message "INFO" "========================================="
    log_message "INFO" "Execution time: $(date '+%Y-%m-%d %H:%M:%S')"
    log_message "INFO" "Dry run mode: ${DRY_RUN}"
    log_message "INFO" "Files removed: ${TOTAL_FILES_REMOVED}"
    log_message "INFO" "Logs truncated: ${TOTAL_LOGS_TRUNCATED}"
    log_message "INFO" "Space freed (calculated): ${TOTAL_SPACE_FREED} MB"
    log_message "INFO" "Space freed (actual): ${space_freed_total} GB"
    log_message "INFO" "Initial disk usage: ${INITIAL_DISK_USAGE} GB"
    log_message "INFO" "Final disk usage: ${FINAL_DISK_USAGE} GB"
    log_message "INFO" "Available space: $(get_available_space "$LOG_DIR") GB"
    log_message "INFO" "========================================="
}

# Rotate audit logs if they get too large
rotate_audit_logs() {
    if [[ -f "$AUDIT_LOG_FILE" ]]; then
        local log_size=$(stat -c%s "$AUDIT_LOG_FILE" 2>/dev/null || echo 0)
        local max_size=$((10 * 1024 * 1024)) # 10 MB
        
        if [[ $log_size -gt $max_size ]]; then
            local timestamp=$(date '+%Y%m%d_%H%M%S')
            mv "$AUDIT_LOG_FILE" "${AUDIT_LOG_FILE}.${timestamp}"
            
            # Keep only last 5 rotated logs
            ls -t "${AUDIT_LOG_FILE}".* 2>/dev/null | tail -n +6 | xargs rm -f 2>/dev/null || true
            
            log_message "INFO" "Rotated audit log"
        fi
    fi
}

# Main execution
main() {
    log_message "INFO" "Starting log cleanup process"
    
    # Check privileges
    check_privileges
    
    # Create audit directory
    create_audit_dir
    
    # Rotate audit logs if needed
    rotate_audit_logs
    
    # Acquire lock
    acquire_lock
    
    # Check initial disk space
    check_disk_space
    
    # Remove .gz files
    remove_gz_files
    
    # Truncate active logs
    truncate_active_logs
    
    # Generate summary report
    generate_summary
    
    log_message "INFO" "Log cleanup completed successfully"
    
    # Exit with appropriate code
    if [[ "$DRY_RUN" == "true" ]]; then
        exit 0
    elif [[ -n "$CLEANUP_ERRORS" ]]; then
        log_message "ERROR" "Cleanup completed with errors: $CLEANUP_ERRORS"
        exit 2
    elif [[ "$TOTAL_FILES_REMOVED" -gt 0 ]] || [[ "$TOTAL_LOGS_TRUNCATED" -gt 0 ]]; then
        exit 0
    else
        log_message "INFO" "Nothing to clean"
        exit 1
    fi
}

# Validate numeric input
validate_number() {
    local value="$1"
    local name="$2"
    local min="${3:-1}"
    local max="${4:-999999}"
    
    if ! [[ "$value" =~ ^[0-9]+$ ]]; then
        echo "Error: $name must be a number" >&2
        exit 1
    fi
    
    if [[ $value -lt $min ]] || [[ $value -gt $max ]]; then
        echo "Error: $name must be between $min and $max" >&2
        exit 1
    fi
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --retention)
            validate_number "$2" "retention lines" 100 1000000
            LOG_RETENTION_LINES="$2"
            shift 2
            ;;
        --log-dir)
            if [[ ! -d "$2" ]]; then
                echo "Error: Log directory does not exist: $2" >&2
                exit 1
            fi
            LOG_DIR="$2"
            shift 2
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --dry-run          Run in dry-run mode (no actual changes)"
            echo "  --retention LINES  Number of lines to retain (default: 10000)"
            echo "  --log-dir PATH     Log directory path (default: /var/log)"
            echo "  --help             Show this help message"
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
main