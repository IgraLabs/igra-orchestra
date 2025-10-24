#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# S3 Backup Upload Script for IGRA Orchestra
# This script uploads backup files to AWS S3 with retention management and verification

# Global variables
SCRIPT_NAME="$(basename "$0")"
START_TIME=$(date +%s)
DRY_RUN=false
LIST_ONLY=false
UPLOAD_SUCCESS=false
BACKUP_FILE=""
CONTAINER_NAME=""
LOG_FILE=""
LOCK_FILE=""
UPLOADED_S3_KEY=""
ROLLBACK_NEEDED=false

# Optional dependency checks
HAS_JQ=true
HAS_NUMFMT=true
command -v jq >/dev/null 2>&1 || HAS_JQ=false
command -v numfmt >/dev/null 2>&1 || HAS_NUMFMT=false

# Exit codes
EXIT_SUCCESS=0
EXIT_INVALID_ARGS=1
EXIT_CONFIG_ERROR=2
EXIT_AWS_CLI_MISSING=3
EXIT_AWS_CREDENTIALS_ERROR=4
EXIT_FILE_NOT_FOUND=5
EXIT_UPLOAD_FAILED=6
# Note: EXIT_VERIFICATION_FAILED and EXIT_RETENTION_FAILED not currently used but kept for future expansion
# shellcheck disable=SC2034
EXIT_VERIFICATION_FAILED=7
# shellcheck disable=SC2034
EXIT_RETENTION_FAILED=8
EXIT_LOCK_ERROR=9

# Function to display usage information
show_usage() {
    cat << EOF
Usage: $SCRIPT_NAME [OPTIONS] CONTAINER_NAME [BACKUP_FILE]

Upload IGRA Orchestra backup files to AWS S3 with automated retention management.

ARGUMENTS:
    CONTAINER_NAME      Name of the container (required)
    BACKUP_FILE         Specific backup file path (optional, auto-detects latest if not provided)

OPTIONS:
    --dry-run          Preview operations without executing them
    --list             List current S3 backups without uploading
    --help             Show this help message

EXAMPLES:
    # Upload latest backup for kaspad container
    $SCRIPT_NAME kaspad

    # Upload specific backup file
    $SCRIPT_NAME kaspad /path/to/backup.tar.gz

    # Preview operations without uploading
    $SCRIPT_NAME --dry-run kaspad

    # List current S3 backups
    $SCRIPT_NAME --list kaspad

ENVIRONMENT VARIABLES:
    Required:
        S3_BACKUP_BUCKET        S3 bucket name
        S3_BACKUP_REGION        AWS region
        NETWORK                 Network identifier (testnet/mainnet)

    Optional:
        S3_BACKUP_RETENTION_COUNT   Number of backups to keep (default: 3)
        S3_BACKUP_DRY_RUN          Enable dry-run mode (true/false)
        S3_BACKUP_PREFIX           Custom S3 prefix (default: archival-data/igra-orchestra/)
        S3_BACKUP_STORAGE_CLASS    S3 storage class (default: STANDARD_IA)

EOF
}

# Function for structured logging with timestamps and levels
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    local formatted_message
    formatted_message=$(format_log_message "$level" "$timestamp" "$message")

    output_log_message "$formatted_message"
}

# Function to format log messages with colors
format_log_message() {
    local level="$1"
    local timestamp="$2"
    local message="$3"

    case "$level" in
        "ERROR")   echo -e "\033[31m[$timestamp] ERROR: $message\033[0m" ;;
        "WARNING") echo -e "\033[33m[$timestamp] WARNING: $message\033[0m" ;;
        "INFO")    echo "[$timestamp] INFO: $message" ;;
        "SUCCESS") echo -e "\033[32m[$timestamp] SUCCESS: $message\033[0m" ;;
        *)         echo "[$timestamp] $level: $message" ;;
    esac
}

# Function to output log messages to console and file
output_log_message() {
    local formatted_message="$1"

    if [ -n "$LOG_FILE" ]; then
        echo "$formatted_message" | tee -a "$LOG_FILE"
    else
        echo "$formatted_message"
    fi
}

# Function to validate AWS CLI availability
check_aws_cli() {
    log_message "INFO" "Checking AWS CLI availability..."

    if ! command -v aws &> /dev/null; then
        log_aws_cli_missing_error
        exit $EXIT_AWS_CLI_MISSING
    fi

    log_aws_cli_version
}

# Function to log AWS CLI missing error
log_aws_cli_missing_error() {
    log_message "ERROR" "AWS CLI is not installed or not in PATH"
    log_message "ERROR" "Please install AWS CLI: https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
}

# Function to log AWS CLI version
log_aws_cli_version() {
    local aws_version
    aws_version=$(aws --version 2>&1 | head -n1)
    log_message "INFO" "Found AWS CLI: $aws_version"
}

# Function to validate AWS credentials
check_aws_credentials() {
    log_message "INFO" "Validating AWS credentials..."

    if ! aws_identity_exists; then
        log_aws_credentials_error
        exit $EXIT_AWS_CREDENTIALS_ERROR
    fi

    log_aws_identity_info
}

# Function to check if AWS identity exists
aws_identity_exists() {
    aws sts get-caller-identity &> /dev/null
}

# Function to log AWS credentials configuration error
log_aws_credentials_error() {
    log_message "ERROR" "AWS credentials not configured or invalid"
    log_message "ERROR" "Please configure AWS credentials using one of:"
    log_message "ERROR" "  - aws configure"
    log_message "ERROR" "  - AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY environment variables"
    log_message "ERROR" "  - IAM role (for EC2 instances)"
}

# Function to log AWS identity information
log_aws_identity_info() {
    local aws_identity
    aws_identity=$(aws sts get-caller-identity --query '[Account,Arn]' --output text 2>/dev/null)
    log_message "INFO" "AWS identity validated: $aws_identity"
}

# Function to source .env file (similar to backup.sh)
source_env_file() {
    local env_file=".env"

    if [ -f "$env_file" ]; then
        log_message "INFO" "Loading configuration from $env_file"
        while IFS= read -r line; do
            # Skip empty lines and comments
            if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
                # Remove inline comments and export
                export "${line%%#*}"
            fi
        done < "$env_file"
    else
        log_message "WARNING" "No .env file found, relying on environment variables"
    fi
}

# Function to validate required environment variables
validate_environment() {
    log_message "INFO" "Validating environment configuration..."

    check_required_environment_variables
    set_default_environment_values
    configure_dry_run_mode
    build_s3_paths
    log_environment_configuration
}

# Function to check required environment variables
check_required_environment_variables() {
    local required_vars=("NETWORK" "S3_BACKUP_BUCKET" "S3_BACKUP_REGION")
    local missing_vars=()

    for var in "${required_vars[@]}"; do
        if [ -z "${!var}" ]; then
            missing_vars+=("$var")
        fi
    done

    if [ ${#missing_vars[@]} -gt 0 ]; then
        log_missing_environment_variables "${missing_vars[@]}"
        exit $EXIT_CONFIG_ERROR
    fi
}

# Function to log missing environment variables
log_missing_environment_variables() {
    local missing_vars=("$@")

    log_message "ERROR" "Missing required environment variables:"
    for var in "${missing_vars[@]}"; do
        log_message "ERROR" "  - $var"
    done
    log_message "ERROR" "Please set these variables in .env file or environment"
}

# Function to set default environment values
set_default_environment_values() {
    S3_BACKUP_RETENTION_COUNT=${S3_BACKUP_RETENTION_COUNT:-3}
    S3_BACKUP_PREFIX=${S3_BACKUP_PREFIX:-"archival-data/igra-orchestra/"}
    S3_BACKUP_STORAGE_CLASS=${S3_BACKUP_STORAGE_CLASS:-"STANDARD_IA"}
}

# Function to configure dry-run mode
configure_dry_run_mode() {
    # Use portable method for case comparison
    case "$S3_BACKUP_DRY_RUN" in
        [Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|1)
            DRY_RUN=true
            ;;
    esac
}

# Function to build S3 paths
build_s3_paths() {
    S3_BASE_PATH="${S3_BACKUP_PREFIX}${NETWORK}/"
}

# Function to log environment configuration
log_environment_configuration() {
    log_message "INFO" "Configuration validated:"
    log_message "INFO" "  - S3 Bucket: $S3_BACKUP_BUCKET"
    log_message "INFO" "  - S3 Region: $S3_BACKUP_REGION"
    log_message "INFO" "  - Network: $NETWORK"
    log_message "INFO" "  - S3 Base Path: $S3_BASE_PATH"
    log_message "INFO" "  - Retention Count: $S3_BACKUP_RETENTION_COUNT"
    log_message "INFO" "  - Storage Class: $S3_BACKUP_STORAGE_CLASS"
    log_message "INFO" "  - Dry Run Mode: $DRY_RUN"
    if [ "$HAS_JQ" != true ]; then
        log_message "WARNING" "jq not found; using basic parsing fallbacks"
    fi
    if [ "$HAS_NUMFMT" != true ]; then
        log_message "WARNING" "numfmt not found; using built-in size formatter"
    fi
}

# Function to test S3 bucket access and permissions
test_s3_access() {
    log_message "INFO" "Testing S3 bucket access and permissions..."

    if ! test_s3_bucket_access; then
        log_s3_bucket_access_error
        exit $EXIT_CONFIG_ERROR
    fi

    log_message "SUCCESS" "S3 bucket access confirmed"
    test_s3_permissions
}

# Function to test S3 bucket access
test_s3_bucket_access() {
    aws s3 ls "s3://$S3_BACKUP_BUCKET/" --region "$S3_BACKUP_REGION" &> /dev/null
}

# Function to log S3 bucket access error
log_s3_bucket_access_error() {
    log_message "ERROR" "Cannot access S3 bucket: $S3_BACKUP_BUCKET"
    log_message "ERROR" "Please check:"
    log_message "ERROR" "  - Bucket exists and is in region $S3_BACKUP_REGION"
    log_message "ERROR" "  - AWS credentials have s3:ListBucket permission"
}

# Function to test S3 permissions comprehensively
test_s3_permissions() {
    if [ "$DRY_RUN" = true ]; then
        log_message "INFO" "[DRY-RUN] Skipping S3 permission test"
        return 0
    fi

    log_message "INFO" "Testing S3 write permissions..."

    local test_context
    test_context=$(create_s3_permission_test_context)

    local test_key test_content temp_test_file
    test_key=$(echo "$test_context" | cut -d'|' -f1)
    test_content=$(echo "$test_context" | cut -d'|' -f2)
    temp_test_file=$(echo "$test_context" | cut -d'|' -f3)

    test_s3_upload_permission "$temp_test_file" "$test_key"
    test_s3_download_permission "$test_key" "$test_content"
    test_s3_delete_permission "$test_key"

    cleanup_s3_permission_test "$temp_test_file"
    log_message "SUCCESS" "S3 permission testing completed"
}

# Function to create S3 permission test context
create_s3_permission_test_context() {
    local test_key
    test_key="${S3_BASE_PATH}test-permissions-$(date +%s).tmp"
    local test_content="IGRA Orchestra S3 permission test"
    local temp_test_file
    temp_test_file=$(mktemp)

    echo "$test_content" > "$temp_test_file"
    echo "$test_key|$test_content|$temp_test_file"
}

# Function to test S3 upload permission
test_s3_upload_permission() {
    local temp_test_file="$1"
    local test_key="$2"

    if ! aws s3 cp "$temp_test_file" "s3://$S3_BACKUP_BUCKET/$test_key" \
        --region "$S3_BACKUP_REGION" \
        --storage-class "$S3_BACKUP_STORAGE_CLASS" \
        --only-show-errors 2>/dev/null; then
        rm -f "$temp_test_file"
        log_message "ERROR" "S3 upload permission test failed"
        log_message "ERROR" "AWS credentials need s3:PutObject permission"
        exit $EXIT_CONFIG_ERROR
    fi

    log_message "SUCCESS" "S3 upload permission confirmed"
}

# Function to test S3 download permission
test_s3_download_permission() {
    local test_key="$1"
    local expected_content="$2"

    local downloaded_content
    if downloaded_content=$(aws s3 cp "s3://$S3_BACKUP_BUCKET/$test_key" - \
        --region "$S3_BACKUP_REGION" 2>/dev/null); then
        log_message "SUCCESS" "S3 download permission confirmed"
        verify_s3_content_integrity "$downloaded_content" "$expected_content"
    else
        log_message "WARNING" "S3 download permission test failed (upload may have worked)"
    fi
}

# Function to verify S3 content integrity
verify_s3_content_integrity() {
    local downloaded_content="$1"
    local expected_content="$2"

    if [ "$downloaded_content" = "$expected_content" ]; then
        log_message "SUCCESS" "S3 upload/download integrity verified"
    else
        log_message "WARNING" "S3 content integrity check failed"
    fi
}

# Function to test S3 delete permission
test_s3_delete_permission() {
    local test_key="$1"

    if aws s3 rm "s3://$S3_BACKUP_BUCKET/$test_key" \
        --region "$S3_BACKUP_REGION" \
        --only-show-errors 2>/dev/null; then
        log_message "SUCCESS" "S3 delete permission confirmed"
    else
        log_message "WARNING" "S3 delete permission test failed - retention management may not work"
        log_message "WARNING" "Please ensure AWS credentials have s3:DeleteObject permission"
    fi
}

# Function to cleanup S3 permission test
cleanup_s3_permission_test() {
    local temp_test_file="$1"
    rm -f "$temp_test_file"
}

# Function to find the latest backup file
find_latest_backup() {
    local container="$1"
    local backup_dir="$HOME/.backups/${container}-backups"

    log_message "INFO" "Looking for latest backup in: $backup_dir"

    if [ ! -d "$backup_dir" ]; then
        log_message "ERROR" "Backup directory not found: $backup_dir"
        log_message "ERROR" "Run backup.sh first to create backups"
        exit $EXIT_FILE_NOT_FOUND
    fi

    # Find the most recent backup file (portable for macOS and Linux)
    local latest_backup
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS version using stat
        latest_backup=$(find "$backup_dir" -name "*.tar.gz" -type f -exec stat -f "%m %N" {} \; 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    else
        # Linux version using find -printf
        latest_backup=$(find "$backup_dir" -name "*.tar.gz" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
    fi

    if [ -z "$latest_backup" ]; then
        log_message "ERROR" "No backup files found in: $backup_dir"
        log_message "ERROR" "Run backup.sh first to create backups"
        exit $EXIT_FILE_NOT_FOUND
    fi

    log_message "SUCCESS" "Found latest backup: $latest_backup"
    # Return only the file path, not log messages
    echo "$latest_backup"
}

# Function to validate backup file
validate_backup_file() {
    local file="$1"

    log_message "INFO" "Validating backup file: $file"

    check_backup_file_exists "$file"
    check_backup_file_size "$file"
    check_backup_file_readable "$file"

    log_backup_file_validation_success "$file"
}

# Function to check if backup file exists
check_backup_file_exists() {
    local file="$1"

    if [ ! -f "$file" ]; then
        log_message "ERROR" "Backup file not found: $file"
        exit $EXIT_FILE_NOT_FOUND
    fi
}

# Function to check backup file size
check_backup_file_size() {
    local file="$1"

    local file_size
    file_size=$(get_file_size "$file")

    if [ "$file_size" -eq 0 ]; then
        log_message "ERROR" "Backup file is empty: $file"
        exit $EXIT_FILE_NOT_FOUND
    fi
}

# Function to get file size (cross-platform)
get_file_size() {
    local file="$1"
    stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null
}

# Function to check if backup file is readable
check_backup_file_readable() {
    local file="$1"

    if [ ! -r "$file" ]; then
        log_message "ERROR" "Backup file is not readable: $file"
        exit $EXIT_FILE_NOT_FOUND
    fi
}

# Function to log successful backup file validation
log_backup_file_validation_success() {
    local file="$1"
    local file_size

    file_size=$(get_file_size "$file")

    log_message "SUCCESS" "Backup file validation passed"
    log_message "INFO" "File size: $(format_bytes "$file_size")"
}

# Function to calculate MD5 checksum
calculate_md5() {
    local file="$1"
    local start_time
    start_time=$(date +%s)

    log_message "INFO" "Calculating MD5 checksum for $(basename "$file")..."

    local md5sum_result
    md5sum_result=$(get_md5_checksum "$file")

    local duration
    duration=$(calculate_duration "$start_time")

    log_message "SUCCESS" "MD5 checksum calculated in ${duration}s: $md5sum_result"
    echo "$md5sum_result"
}

# Function to get MD5 checksum (cross-platform)
get_md5_checksum() {
    local file="$1"

    if command -v md5sum &> /dev/null; then
        md5sum "$file" | cut -d' ' -f1
    elif command -v md5 &> /dev/null; then
        md5 -q "$file"
    else
        log_message "ERROR" "Neither md5sum nor md5 command found"
        exit $EXIT_CONFIG_ERROR
    fi
}

# Function to calculate duration
calculate_duration() {
    local start_time="$1"
    local end_time
    end_time=$(date +%s)
    echo $((end_time - start_time))
}

# Function to list current S3 backups
list_s3_backups() {
    log_message "INFO" "Listing S3 backups for $CONTAINER_NAME in $S3_BASE_PATH"

    # Note: Match the backup naming pattern from backup.sh
    local prefix_filter="igra-orchestra-${NETWORK}_${CONTAINER_NAME}_"

    # List objects with detailed information
    if ! aws s3api list-objects-v2 \
        --bucket "$S3_BACKUP_BUCKET" \
        --prefix "$S3_BASE_PATH" \
        --region "$S3_BACKUP_REGION" \
        --query "Contents[?contains(Key, '_${CONTAINER_NAME}_')].{Key:Key,Size:Size,LastModified:LastModified}" \
        --output table 2>/dev/null; then
        log_message "WARNING" "No backups found or failed to list S3 objects"
        return 1
    fi

    return 0
}

# Function to get existing S3 backups sorted by date
get_s3_backups_sorted() {
    local prefix_filter="${S3_BASE_PATH}igra-orchestra-${NETWORK}_${CONTAINER_NAME}_"

    # Get list of matching objects sorted by LastModified (oldest first)
    aws s3api list-objects-v2 \
        --bucket "$S3_BACKUP_BUCKET" \
        --prefix "$prefix_filter" \
        --region "$S3_BACKUP_REGION" \
        --query 'sort_by(Contents, &LastModified)[].{Key:Key,LastModified:LastModified}' \
        --output json 2>/dev/null || echo "[]"
}

# Function to manage S3 backup retention
manage_s3_retention() {
    log_message "INFO" "Managing S3 backup retention (keeping latest $S3_BACKUP_RETENTION_COUNT backups)"

    local backups_json
    backups_json=$(get_s3_backups_sorted)

    if ! has_existing_backups "$backups_json"; then
        log_message "INFO" "No existing backups found for retention management"
        return 0
    fi

    local backup_count delete_count
    backup_count=$(count_existing_backups "$backups_json")
    delete_count=$(calculate_backups_to_delete "$backup_count")

    if [ "$delete_count" -le 0 ]; then
        log_message "INFO" "No backups need to be deleted (within retention limit)"
        return 0
    fi

    delete_old_backups "$backups_json" "$delete_count"
}

# Function to check if backups exist
has_existing_backups() {
    local backups_json="$1"
    [ "$backups_json" != "[]" ] && [ -n "$backups_json" ]
}

# Function to count existing backups
count_existing_backups() {
    local backups_json="$1"
    if [ "$HAS_JQ" = true ]; then
        echo "$backups_json" | jq length 2>/dev/null || echo "0"
    else
        echo "$backups_json" | grep -o '"Key"' | wc -l | tr -d ' ' || echo "0"
    fi
}

# Function to calculate how many backups to delete
calculate_backups_to_delete() {
    local backup_count="$1"
    # Don't add +1 since we call this after upload, so the new backup is already counted
    echo $((backup_count - S3_BACKUP_RETENTION_COUNT))
}

# Function to delete old backups
delete_old_backups() {
    local backups_json="$1"
    local delete_count="$2"

    log_message "INFO" "Will delete $delete_count old backup(s) to maintain retention policy"

    local keys_to_delete
    keys_to_delete=$(get_keys_to_delete "$backups_json" "$delete_count")

    if [ -z "$keys_to_delete" ]; then
        log_message "WARNING" "No keys found for deletion"
        return 0
    fi

    process_backup_deletions "$keys_to_delete"
}

# Function to get keys to delete
get_keys_to_delete() {
    local backups_json="$1"
    local delete_count="$2"
    if [ "$HAS_JQ" = true ]; then
        echo "$backups_json" | jq -r ".[0:$delete_count][].Key" 2>/dev/null
    else
        echo "$backups_json" | sed -n 's/.*"Key"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n "$delete_count"
    fi
}

# Function to process backup deletions
process_backup_deletions() {
    local keys_to_delete="$1"
    local deleted_count=0

    while IFS= read -r key; do
        [ -z "$key" ] && continue

        local filename
        filename=$(basename "$key")
        if delete_single_backup "$key" "$filename"; then
            ((++deleted_count))
        else
            return 1
        fi
    done <<< "$keys_to_delete"

    log_deletion_summary "$deleted_count"
}

# Function to delete a single backup
delete_single_backup() {
    local key="$1"
    local filename="$2"

    if [ "$DRY_RUN" = true ]; then
        log_message "INFO" "[DRY-RUN] Would delete: $filename"
        return 0
    fi

    log_message "INFO" "Deleting old backup: $filename"
    if aws s3 rm "s3://$S3_BACKUP_BUCKET/$key" --region "$S3_BACKUP_REGION" &> /dev/null; then
        log_message "SUCCESS" "Deleted: $filename"
        return 0
    else
        log_message "ERROR" "Failed to delete: $filename"
        return 1
    fi
}

# Function to log deletion summary
log_deletion_summary() {
    local deleted_count="$1"

    if [ "$DRY_RUN" != true ]; then
        log_message "SUCCESS" "Retention management completed: deleted $deleted_count backup(s)"
    fi
}

# Function to upload file to S3 with progress and verification
upload_to_s3() {
    local local_file="$1"
    local upload_context
    upload_context=$(create_upload_context "$local_file")

    local s3_key s3_uri
    s3_key=$(echo "$upload_context" | cut -d'|' -f1)
    s3_uri=$(echo "$upload_context" | cut -d'|' -f2)

    # Store S3 key for potential rollback
    UPLOADED_S3_KEY="$s3_key"

    log_upload_start_info "$local_file" "$s3_uri"

    if [ "$DRY_RUN" = true ]; then
        log_message "INFO" "[DRY-RUN] Would upload to: $s3_uri"
        return 0
    fi

    local local_md5
    local_md5=$(calculate_md5 "$local_file" | tail -1)

    execute_upload_with_retry "$local_file" "$s3_uri" "$s3_key" "$local_md5"
}

# Function to create upload context
create_upload_context() {
    local local_file="$1"
    local filename
    filename=$(basename "$local_file")
    local s3_key="${S3_BASE_PATH}${filename}"
    local s3_uri="s3://$S3_BACKUP_BUCKET/$s3_key"

    echo "$s3_key|$s3_uri"
}

# Function to log upload start information
log_upload_start_info() {
    local local_file="$1"
    local s3_uri="$2"

    log_message "INFO" "Starting S3 upload..."
    log_message "INFO" "  Local: $local_file"
    log_message "INFO" "  S3 URI: $s3_uri"
    log_message "INFO" "  Storage Class: $S3_BACKUP_STORAGE_CLASS"
}

# Function to execute upload with retry logic
execute_upload_with_retry() {
    local local_file="$1"
    local s3_uri="$2"
    local s3_key="$3"
    local local_md5="$4"

    # Check if file already exists in S3 with same MD5
    check_s3_file_exists_with_md5 "$s3_key" "$local_md5"
    local check_result=$?

    if [ $check_result -eq 0 ]; then
        # File exists with same MD5, skip upload
        log_message "SUCCESS" "Skipping upload - identical file already exists in S3"
        UPLOAD_SUCCESS=true
        UPLOADED_S3_KEY="$s3_key"
        return 0
    elif [ $check_result -eq 1 ]; then
        # File exists but MD5 differs, will overwrite
        log_message "WARNING" "File exists in S3 with different content - will overwrite"
    fi
    # If check_result is 2, file doesn't exist, proceed with normal upload

    local max_attempts=3
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_message "INFO" "Upload attempt $attempt of $max_attempts..."

        if attempt_single_upload "$local_file" "$s3_uri" "$s3_key" "$local_md5"; then
            return 0
        fi

        handle_upload_attempt_failure "$attempt" "$max_attempts"
        ((attempt++))
    done

    log_upload_final_failure "$max_attempts"
    return 1
}

# Function to attempt a single upload
attempt_single_upload() {
    local local_file="$1"
    local s3_uri="$2"
    local s3_key="$3"
    local local_md5="$4"

    local upload_start
    upload_start=$(date +%s)

    if perform_s3_upload "$local_file" "$s3_uri"; then
        local upload_duration
        upload_duration=$(calculate_duration "$upload_start")
        log_message "SUCCESS" "Upload completed in ${upload_duration}s"

        # Mark that rollback might be needed (file exists in S3 but not verified)
        ROLLBACK_NEEDED=true

        if verify_s3_upload "$local_file" "$s3_key" "$local_md5"; then
            UPLOAD_SUCCESS=true
            ROLLBACK_NEEDED=false  # Upload successful, no rollback needed
            return 0
        else
            log_message "ERROR" "Upload verification failed on attempt $attempt"
            return 1
        fi
    else
        log_message "ERROR" "Upload failed on attempt $attempt"
        ROLLBACK_NEEDED=false  # File might not have been uploaded
        return 1
    fi
}

# Function to check if file already exists in S3 with same MD5
check_s3_file_exists_with_md5() {
    local s3_key="$1"
    local local_md5="$2"

    # Check if file exists in S3
    if aws s3api head-object \
        --bucket "$S3_BACKUP_BUCKET" \
        --key "$s3_key" \
        --region "$S3_BACKUP_REGION" &>/dev/null; then

        # Get S3 file's ETag (MD5 for single-part uploads)
        local s3_etag
        s3_etag=$(aws s3api head-object \
            --bucket "$S3_BACKUP_BUCKET" \
            --key "$s3_key" \
            --region "$S3_BACKUP_REGION" \
            --query 'ETag' \
            --output text | tr -d '"')

        # Compare MD5 checksums
        if [ "$s3_etag" = "$local_md5" ]; then
            log_message "INFO" "File already exists in S3 with matching MD5: $s3_etag"
            return 0  # File exists with same content
        else
            log_message "INFO" "File exists in S3 but MD5 differs (local: $local_md5, S3: $s3_etag)"
            return 1  # File exists but content differs
        fi
    fi

    return 2  # File doesn't exist in S3
}

# Function to perform S3 upload
perform_s3_upload() {
    local local_file="$1"
    local s3_uri="$2"
    local file_size
    file_size=$(get_file_size "$local_file")

    # Show progress for files larger than 5MB
    if [ "$file_size" -gt 5242880 ]; then
        log_message "INFO" "Upload progress:"
        # AWS CLI shows progress by default when output is a TTY
        aws s3 cp "$local_file" "$s3_uri" \
            --region "$S3_BACKUP_REGION" \
            --storage-class "$S3_BACKUP_STORAGE_CLASS"
    else
        # For small files, hide progress to reduce clutter
        aws s3 cp "$local_file" "$s3_uri" \
            --region "$S3_BACKUP_REGION" \
            --storage-class "$S3_BACKUP_STORAGE_CLASS" \
            --only-show-errors
    fi
}

# Function to handle upload attempt failure
handle_upload_attempt_failure() {
    local attempt="$1"
    local max_attempts="$2"

    if [ $((attempt + 1)) -le "$max_attempts" ]; then
        log_message "INFO" "Retrying in 5 seconds..."
        sleep 5
    fi
}

# Function to log final upload failure
log_upload_final_failure() {
    local max_attempts="$1"

    log_message "ERROR" "Upload failed after $max_attempts attempts"
    log_message "INFO" "Rollback will be attempted to clean up any partial uploads"
}

# Function to verify S3 upload
verify_s3_upload() {
    local local_file="$1"
    local s3_key="$2"
    local local_md5="$3"

    log_message "INFO" "Verifying S3 upload..."

    local s3_metadata
    s3_metadata=$(get_s3_object_metadata "$s3_key")

    if [ -z "$s3_metadata" ]; then
        log_message "ERROR" "Failed to get S3 object metadata"
        return 1
    fi

    local verification_context
    verification_context=$(create_verification_context "$s3_metadata" "$local_file")

    local s3_etag s3_size local_size
    s3_etag=$(echo "$verification_context" | cut -d'|' -f1)
    s3_size=$(echo "$verification_context" | cut -d'|' -f2)
    local_size=$(echo "$verification_context" | cut -d'|' -f3)

    if ! verify_file_size "$local_size" "$s3_size"; then
        return 1
    fi

    verify_checksum "$local_md5" "$s3_etag"
    log_message "SUCCESS" "Upload verification completed successfully"
    return 0
}

# Function to get S3 object metadata
get_s3_object_metadata() {
    local s3_key="$1"

    aws s3api head-object \
        --bucket "$S3_BACKUP_BUCKET" \
        --key "$s3_key" \
        --region "$S3_BACKUP_REGION" 2>/dev/null
}

# Function to create verification context
create_verification_context() {
    local s3_metadata="$1"
    local local_file="$2"

    local s3_etag s3_size local_size
    if [ "$HAS_JQ" = true ]; then
        s3_etag=$(echo "$s3_metadata" | jq -r '.ETag // empty' | tr -d '"')
        s3_size=$(echo "$s3_metadata" | jq -r '.ContentLength // empty')
    else
        s3_etag=$(echo "$s3_metadata" | sed -n 's/.*"ETag"[[:space:]]*:[[:space:]]*"\([^"]\+\)".*/\1/p' | head -n1 | tr -d '"')
        s3_size=$(echo "$s3_metadata" | sed -n 's/.*"ContentLength"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
    fi
    local_size=$(get_file_size "$local_file")

    echo "$s3_etag|$s3_size|$local_size"
}

# Function to verify file size
verify_file_size() {
    local local_size="$1"
    local s3_size="$2"

    if [ "$local_size" != "$s3_size" ]; then
        log_message "ERROR" "File size mismatch: local=$local_size, S3=$s3_size"
        return 1
    fi

    log_message "SUCCESS" "File size verification passed: $(format_bytes "$local_size")"
    return 0
}

# Format bytes using built-in calculator if numfmt is unavailable
format_bytes() {
    local bytes="$1"
    if [ "$HAS_NUMFMT" = true ]; then
        numfmt --to=iec --suffix=B "$bytes" 2>/dev/null && return 0
    fi
    # Fallback implementation (integer-only)
    local units=(B KiB MiB GiB TiB PiB)
    local idx=0
    local value="$bytes"
    if ! echo "$value" | grep -Eq '^[0-9]+$'; then
        echo "$value B"
        return 0
    fi
    while [ "$value" -ge 1024 ] && [ $idx -lt 5 ]; do
        value=$((value / 1024))
        idx=$((idx + 1))
    done
    echo "$value ${units[$idx]}"
}

# Function to verify checksum
verify_checksum() {
    local local_md5="$1"
    local s3_etag="$2"

    # For single-part uploads, ETag should match MD5
    # For multipart uploads, ETag has a different format (contains hyphen)
    if [[ "$s3_etag" != *"-"* ]]; then
        verify_single_part_checksum "$local_md5" "$s3_etag"
    else
        log_message "INFO" "Multipart upload detected, skipping MD5 verification (ETag: $s3_etag)"
    fi
}

# Function to verify single-part upload checksum
verify_single_part_checksum() {
    local local_md5="$1"
    local s3_etag="$2"

    if [ "$local_md5" != "$s3_etag" ]; then
        log_message "ERROR" "MD5 checksum mismatch: local=$local_md5, S3=$s3_etag"
        return 1
    fi

    log_message "SUCCESS" "MD5 checksum verification passed: $local_md5"
    return 0
}

# Function to create lock file
create_lock() {
    LOCK_FILE="/tmp/${SCRIPT_NAME}_${CONTAINER_NAME}.lock"

    if [ -f "$LOCK_FILE" ]; then
        local lock_pid
        lock_pid=$(cat "$LOCK_FILE" 2>/dev/null)

        if kill -0 "$lock_pid" 2>/dev/null; then
            log_message "ERROR" "Another upload process is already running (PID: $lock_pid)"
            log_message "ERROR" "Lock file: $LOCK_FILE"
            exit $EXIT_LOCK_ERROR
        else
            log_message "WARNING" "Stale lock file found, removing it"
            rm -f "$LOCK_FILE"
        fi
    fi

    echo $$ > "$LOCK_FILE"
    log_message "INFO" "Lock file created: $LOCK_FILE"
}

# Function to rollback partial uploads
# Called from cleanup() trap handler
# shellcheck disable=SC2329
rollback_failed_upload() {
    if [ "$ROLLBACK_NEEDED" = true ] && [ -n "$UPLOADED_S3_KEY" ]; then
        log_message "WARNING" "Rolling back failed upload..."

        if [ "$DRY_RUN" = true ]; then
            log_message "INFO" "[DRY-RUN] Would rollback S3 object: $UPLOADED_S3_KEY"
            return 0
        fi

        # Attempt to delete the partially uploaded or failed file
        if aws s3 rm "s3://$S3_BACKUP_BUCKET/$UPLOADED_S3_KEY" \
            --region "$S3_BACKUP_REGION" \
            --only-show-errors 2>/dev/null; then
            log_message "SUCCESS" "Rollback completed: removed failed upload from S3"
        else
            log_message "WARNING" "Rollback failed: could not remove failed upload from S3"
            log_message "WARNING" "Manual cleanup may be required for: s3://$S3_BACKUP_BUCKET/$UPLOADED_S3_KEY"
        fi
    fi
}

# Function to clean up lock file
# Called from cleanup() trap handler
# shellcheck disable=SC2329
cleanup_lock() {
    if [ -n "$LOCK_FILE" ] && [ -f "$LOCK_FILE" ]; then
        rm -f "$LOCK_FILE"
        # Only log if LOG_FILE is set (avoids issues with --help)
        if [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "" ]; then
            log_message "INFO" "Lock file removed"
        fi
    fi
}

# Function to display summary report
# Called from cleanup() trap handler
# shellcheck disable=SC2329
show_summary() {
    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - START_TIME))

    log_message "INFO" ""
    log_message "INFO" "===== S3 Upload Summary ====="
    log_message "INFO" "Container: $CONTAINER_NAME"
    log_message "INFO" "Network: $NETWORK"
    log_message "INFO" "S3 Bucket: $S3_BACKUP_BUCKET ($S3_BACKUP_REGION)"
    if [ -n "$BACKUP_FILE" ]; then
        log_message "INFO" "Backup File: $BACKUP_FILE"
        if [ "$UPLOAD_SUCCESS" = true ]; then
            log_message "SUCCESS" "Upload Status: SUCCESS"
        elif [ "$DRY_RUN" = true ]; then
            log_message "INFO" "Upload Status: DRY-RUN PREVIEW"
        else
            log_message "ERROR" "Upload Status: FAILED"
        fi
    fi
    log_message "INFO" "Total Execution Time: ${total_duration}s"
    log_message "INFO" "Completed at: $(date '+%Y-%m-%d %H:%M:%S')"
    log_message "INFO" "=============================="
}

# Trap function for cleanup
# Called by EXIT trap (set below)
# shellcheck disable=SC2329
cleanup() {
    # Perform rollback if needed
    if [ "$UPLOAD_SUCCESS" != true ]; then
        rollback_failed_upload
    fi

    # Only show summary if we're not just displaying help
    if [ -n "$LOG_FILE" ] && [ "$LOG_FILE" != "" ]; then
        show_summary
    fi
    cleanup_lock
}

# Set up trap for cleanup
trap cleanup EXIT

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --list)
            LIST_ONLY=true
            shift
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
            elif [ -z "$BACKUP_FILE" ]; then
                BACKUP_FILE="$1"
            else
                log_message "ERROR" "Too many arguments"
                show_usage
                exit $EXIT_INVALID_ARGS
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [ -z "$CONTAINER_NAME" ]; then
    log_message "ERROR" "Container name is required"
    show_usage
    exit $EXIT_INVALID_ARGS
fi

# Set up logging
BACKUP_DIR="$HOME/.backups/${CONTAINER_NAME}-backups"
mkdir -p "$BACKUP_DIR"
LOG_FILE="$BACKUP_DIR/s3_upload_logs.log"

# Create lock file to prevent concurrent uploads
create_lock

log_message "INFO" "===== Starting S3 Backup Upload ====="
log_message "INFO" "Script: $SCRIPT_NAME"
log_message "INFO" "Container: $CONTAINER_NAME"
log_message "INFO" "Dry Run: $DRY_RUN"
log_message "INFO" "List Only: $LIST_ONLY"

# Source environment configuration
source_env_file

# Validate environment and prerequisites
validate_environment
check_aws_cli
check_aws_credentials
test_s3_access

# Handle list-only mode
if [ "$LIST_ONLY" = true ]; then
    list_s3_backups
    exit $EXIT_SUCCESS
fi

# Find or validate backup file
if [ -z "$BACKUP_FILE" ]; then
    # Capture all output including logs, then extract just the file path (last line)
    BACKUP_FILE=$(find_latest_backup "$CONTAINER_NAME" | tail -1)
else
    validate_backup_file "$BACKUP_FILE"
fi

# Upload backup file
if upload_to_s3 "$BACKUP_FILE"; then
    # Manage retention after successful upload
    if [ "$UPLOAD_SUCCESS" = true ]; then
        manage_s3_retention
    fi
else
    log_message "ERROR" "S3 upload failed"
    exit $EXIT_UPLOAD_FAILED
fi

log_message "SUCCESS" "S3 backup upload process completed successfully"
exit $EXIT_SUCCESS