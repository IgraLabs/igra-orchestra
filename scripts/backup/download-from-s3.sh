#!/bin/bash

# ================================================================
# IGRA Orchestra S3 Backup Download Script
# ================================================================
# Downloads the latest backup from AWS S3 bucket
# Works with public buckets - no AWS credentials required
# ================================================================

set -euo pipefail

# ================================================================
# Configuration
# ================================================================

# Script metadata
readonly SCRIPT_NAME=$(basename "$0")
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_VERSION="1.0.0"

# Exit codes
readonly EXIT_SUCCESS=0
readonly EXIT_INVALID_ARGS=1
readonly EXIT_FILE_NOT_FOUND=2
readonly EXIT_DOWNLOAD_FAILED=3
readonly EXIT_VERIFICATION_FAILED=4
readonly EXIT_CONFIG_ERROR=5

# Default values
DRY_RUN=false
LIST_ONLY=false
CONTAINER_NAME=""
DOWNLOAD_DIR=""
SPECIFIC_BACKUP=""

# ================================================================
# Helper Functions
# ================================================================

# Function to show usage
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] CONTAINER_NAME [BACKUP_FILE]

Download IGRA Orchestra backup files from AWS S3 public bucket.

ARGUMENTS:
    CONTAINER_NAME      Name of the container (required)
    BACKUP_FILE         Specific backup file to download (optional, downloads latest if not provided)

OPTIONS:
    --dry-run          Preview operations without executing them
    --list             List available S3 backups without downloading
    --output-dir DIR   Directory to save downloaded backup (default: ~/.backups/{container}-backups/)
    --help             Show this help message

EXAMPLES:
    # Download latest backup for viaduct container
    $SCRIPT_NAME viaduct

    # Download specific backup file
    $SCRIPT_NAME viaduct igra-orchestra-testnet_viaduct_data_20250812_173649.tar.gz

    # Download to specific directory
    $SCRIPT_NAME --output-dir /tmp/backups viaduct

    # List available backups
    $SCRIPT_NAME --list viaduct

ENVIRONMENT VARIABLES:
    S3_BACKUP_BUCKET        S3 bucket name (default: igralabs-viaduct-archival-data)
    S3_BACKUP_REGION        AWS region (default: eu-north-1)
    NETWORK                 Network identifier (default: testnet)
EOF
}

# Function to log messages
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    case "$level" in
        "ERROR")   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" >&2 ;;
        "WARNING") echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" ;;
        "INFO")    echo "[$timestamp] INFO: $message" ;;
        "SUCCESS") echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
        *)         echo "[$timestamp] $level: $message" ;;
    esac
}

# Function to parse command line arguments
parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --list)
                LIST_ONLY=true
                shift
                ;;
            --output-dir)
                DOWNLOAD_DIR="$2"
                shift 2
                ;;
            --help|-h)
                show_usage
                exit $EXIT_SUCCESS
                ;;
            -*)
                log_message "ERROR" "Unknown option: $1"
                show_usage
                exit $EXIT_INVALID_ARGS
                ;;
            *)
                if [ -z "$CONTAINER_NAME" ]; then
                    CONTAINER_NAME="$1"
                else
                    SPECIFIC_BACKUP="$1"
                fi
                shift
                ;;
        esac
    done
}

# Function to load configuration
load_configuration() {
    # Load from environment or .env file if exists
    if [ -f "$SCRIPT_DIR/../../.env" ]; then
        log_message "INFO" "Loading configuration from .env"
        # Parse .env file safely, ignoring comments and invalid lines
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            if [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]]; then
                continue
            fi
            # Remove leading/trailing whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            # Export only specific S3-related variables
            case "$key" in
                S3_BACKUP_BUCKET|S3_BACKUP_REGION|NETWORK)
                    export "$key=$value"
                    ;;
            esac
        done < "$SCRIPT_DIR/../../.env" 2>/dev/null || true
    fi
    
    # Set defaults if not provided
    S3_BACKUP_BUCKET="${S3_BACKUP_BUCKET:-igralabs-viaduct-archival-data}"
    S3_BACKUP_REGION="${S3_BACKUP_REGION:-eu-north-1}"
    NETWORK="${NETWORK:-testnet}"
    
    # Build S3 path
    S3_BASE_PATH="archival-data/igra-orchestra/${NETWORK}/"
    
    # Set download directory - default to ~/.backups/{container}-backups/
    if [ -z "$DOWNLOAD_DIR" ]; then
        DOWNLOAD_DIR="$HOME/.backups/${CONTAINER_NAME}-backups"
    fi
    
    # Create download directory if it doesn't exist
    if [ ! -d "$DOWNLOAD_DIR" ]; then
        if [ "$DRY_RUN" = false ]; then
            mkdir -p "$DOWNLOAD_DIR"
            log_message "INFO" "Created download directory: $DOWNLOAD_DIR"
        else
            log_message "INFO" "[DRY-RUN] Would create directory: $DOWNLOAD_DIR"
        fi
    fi
}

# Function to validate configuration
validate_configuration() {
    log_message "INFO" "Validating configuration..."
    
    if [ -z "$CONTAINER_NAME" ]; then
        log_message "ERROR" "Container name is required"
        show_usage
        exit $EXIT_INVALID_ARGS
    fi
    
    log_message "INFO" "Configuration validated:"
    log_message "INFO" "  - S3 Bucket: $S3_BACKUP_BUCKET"
    log_message "INFO" "  - S3 Region: $S3_BACKUP_REGION"
    log_message "INFO" "  - Network: $NETWORK"
    log_message "INFO" "  - S3 Base Path: $S3_BASE_PATH"
    log_message "INFO" "  - Download Directory: $DOWNLOAD_DIR"
    log_message "INFO" "  - Dry Run Mode: $DRY_RUN"
}

# Function to list S3 backups
list_s3_backups() {
    local s3_url="https://${S3_BACKUP_BUCKET}.s3.${S3_BACKUP_REGION}.amazonaws.com/?prefix=${S3_BASE_PATH}&list-type=2"
    
    # Download the S3 listing XML silently
    local xml_response
    xml_response=$(curl -s "$s3_url")
    
    # Parse XML to extract file names containing the container name
    echo "$xml_response" | grep -oE "<Key>[^<]*${CONTAINER_NAME}[^<]*</Key>" | \
        sed 's/<Key>//g' | sed 's/<\/Key>//g' | \
        grep -E "\.tar\.gz$" | \
        while read -r key; do
            basename "$key"
        done | sort -r
}

# Function to get the latest backup
get_latest_backup() {
    local backups
    backups=$(list_s3_backups)
    
    if [ -z "$backups" ]; then
        log_message "ERROR" "No backups found for container: $CONTAINER_NAME"
        exit $EXIT_FILE_NOT_FOUND
    fi
    
    # Get the first (most recent) backup
    echo "$backups" | head -1
}

# Function to get S3 file's ETag (MD5)
get_s3_etag() {
    local backup_file="$1"
    local s3_url="https://${S3_BACKUP_BUCKET}.s3.${S3_BACKUP_REGION}.amazonaws.com/${S3_BASE_PATH}${backup_file}"
    
    # Use curl to get headers and extract ETag
    local etag
    etag=$(curl -sI "$s3_url" | grep -i "^etag:" | sed 's/^[Ee][Tt][Aa][Gg]: *//;s/\r//;s/"//g')
    echo "$etag"
}

# Function to check if local file exists with same MD5
check_local_file_exists_with_md5() {
    local local_file="$1"
    local s3_etag="$2"
    
    if [ -f "$local_file" ]; then
        local local_md5
        local_md5=$(calculate_md5 "$local_file")
        
        if [ -n "$local_md5" ] && [ "$local_md5" = "$s3_etag" ]; then
            log_message "INFO" "File already exists locally with matching MD5: $local_md5"
            return 0  # File exists with same content
        else
            log_message "INFO" "File exists locally but MD5 differs (local: $local_md5, S3: $s3_etag)"
            return 1  # File exists but content differs
        fi
    fi
    
    return 2  # File doesn't exist locally
}

# Function to download backup
download_backup() {
    local backup_file="$1"
    local s3_url="https://${S3_BACKUP_BUCKET}.s3.${S3_BACKUP_REGION}.amazonaws.com/${S3_BASE_PATH}${backup_file}"
    local local_file="${DOWNLOAD_DIR}/${backup_file}"
    
    log_message "INFO" "Checking backup file:"
    log_message "INFO" "  S3: $s3_url"
    log_message "INFO" "  Local: $local_file"
    
    if [ "$DRY_RUN" = true ]; then
        log_message "INFO" "[DRY-RUN] Would download: $backup_file"
        return 0
    fi
    
    # Get S3 file's ETag (MD5)
    local s3_etag
    s3_etag=$(get_s3_etag "$backup_file")
    
    if [ -n "$s3_etag" ]; then
        # Check if file already exists locally with same MD5
        check_local_file_exists_with_md5 "$local_file" "$s3_etag"
        local check_result=$?
        
        if [ $check_result -eq 0 ]; then
            # File exists with same MD5, skip download
            log_message "SUCCESS" "Skipping download - identical file already exists locally"
            
            # Still verify it's a valid archive
            if tar -tzf "$local_file" > /dev/null 2>&1; then
                log_message "SUCCESS" "Local archive verification passed"
                return 0  # Skip download only if MD5 matches AND archive is valid
            else
                log_message "WARNING" "Local archive verification failed - file may be corrupted, re-downloading"
                # Continue with download if archive is corrupted
            fi
        elif [ $check_result -eq 1 ]; then
            log_message "INFO" "Local file differs from S3 version - will re-download"
        fi
    else
        log_message "WARNING" "Could not retrieve S3 ETag for MD5 comparison"
    fi
    
    log_message "INFO" "Downloading backup from S3..."
    
    # Download with progress bar
    if curl -L --progress-bar -o "$local_file" "$s3_url"; then
        log_message "SUCCESS" "Download completed: $local_file"
        
        # Verify the download
        if [ -f "$local_file" ]; then
            local file_size
            file_size=$(stat -f%z "$local_file" 2>/dev/null || stat -c%s "$local_file" 2>/dev/null)
            log_message "INFO" "Downloaded file size: $(numfmt --to=iec-i --suffix=B "$file_size" 2>/dev/null || echo "${file_size} bytes")"
            
            # Calculate and log MD5 of downloaded file
            local downloaded_md5
            downloaded_md5=$(calculate_md5 "$local_file")
            if [ -n "$downloaded_md5" ]; then
                log_message "INFO" "Downloaded file MD5: $downloaded_md5"
                if [ -n "$s3_etag" ] && [ "$downloaded_md5" = "$s3_etag" ]; then
                    log_message "SUCCESS" "MD5 checksum verification passed"
                elif [ -n "$s3_etag" ]; then
                    log_message "WARNING" "MD5 mismatch (expected: $s3_etag, got: $downloaded_md5)"
                fi
            fi
            
            # Verify it's a valid tar.gz file
            if tar -tzf "$local_file" > /dev/null 2>&1; then
                log_message "SUCCESS" "Archive verification passed"
            else
                log_message "WARNING" "Archive verification failed - file may be corrupted"
            fi
        fi
        
        return 0
    else
        log_message "ERROR" "Download failed"
        return 1
    fi
}

# Function to calculate MD5 checksum
calculate_md5() {
    local file="$1"
    if command -v md5sum &> /dev/null; then
        md5sum "$file" | cut -d' ' -f1
    elif command -v md5 &> /dev/null; then
        md5 -q "$file"
    else
        log_message "WARNING" "No MD5 tool available for checksum verification"
        echo ""
    fi
}

# ================================================================
# Main Execution
# ================================================================

main() {
    log_message "INFO" "===== Starting S3 Backup Download ====="
    log_message "INFO" "Script: $SCRIPT_NAME"
    
    # Parse arguments
    parse_arguments "$@"
    
    # Load and validate configuration
    load_configuration
    validate_configuration
    
    # List mode
    if [ "$LIST_ONLY" = true ]; then
        log_message "INFO" "Available backups for $CONTAINER_NAME:"
        echo ""
        list_s3_backups | while read -r backup; do
            echo "  - $backup"
        done
        echo ""
        exit $EXIT_SUCCESS
    fi
    
    # Determine which backup to download
    local backup_to_download
    if [ -n "$SPECIFIC_BACKUP" ]; then
        backup_to_download="$SPECIFIC_BACKUP"
        log_message "INFO" "Downloading specific backup: $backup_to_download"
    else
        log_message "INFO" "Finding latest backup..."
        backup_to_download=$(get_latest_backup)
        log_message "SUCCESS" "Found latest backup: $backup_to_download"
    fi
    
    # Download the backup
    if download_backup "$backup_to_download"; then
        log_message "SUCCESS" "Backup download completed successfully"
        
        # Calculate checksum for verification
        if [ "$DRY_RUN" = false ]; then
            local local_file="${DOWNLOAD_DIR}/${backup_to_download}"
            if [ -f "$local_file" ]; then
                local md5_hash
                md5_hash=$(calculate_md5 "$local_file")
                if [ -n "$md5_hash" ]; then
                    log_message "INFO" "MD5 checksum: $md5_hash"
                fi
            fi
        fi
        
        exit $EXIT_SUCCESS
    else
        log_message "ERROR" "Backup download failed"
        exit $EXIT_DOWNLOAD_FAILED
    fi
}

# Run main function
main "$@"