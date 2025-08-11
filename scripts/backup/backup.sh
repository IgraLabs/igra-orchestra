#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status.

# Check for container name argument
if [ -z "$1" ]; then
    echo "Error: Container name is required"
    echo "Usage: $0 <container_name>"
    exit 1
fi

# Source .env file if it exists
if [ -f ".env" ]; then
    while IFS= read -r line; do
        # Skip empty lines and comments
        if [[ -n "$line" && ! "$line" =~ ^[[:space:]]*# ]]; then
            # Remove inline comments and export
            export "${line%%#*}"
        fi
    done < .env
fi

# Get network from environment variable, error if not set
NETWORK=${NETWORK:?Error: NETWORK environment variable is not set}

# Configuration based on container name
CONTAINER_NAME="$1"
VOLUME_NAME="igra-orchestra-${NETWORK}_${CONTAINER_NAME}_data"
BACKUP_DIR="$HOME/.backups/${CONTAINER_NAME}-backups"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/${VOLUME_NAME}_$TIMESTAMP.tar.gz"
LOG_FILE="$BACKUP_DIR/backup_logs.log"
KEEP_BACKUPS=7 # Number of recent backups to keep
GZIP_LEVEL=1   # Compression level (1=fastest, 9=best, 6=default). Set to "" to use default.

# Function for logging
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | tee -a "$LOG_FILE"
}

# Check if the volume exists
log_message "Checking if volume $VOLUME_NAME exists..."
if ! docker volume inspect "$VOLUME_NAME" > /dev/null 2>&1; then
    log_message "ERROR: Volume $VOLUME_NAME does not exist. Cannot backup a non-existent volume."
    log_message "Available volumes:"
    docker volume ls --format "table {{.Name}}\t{{.Driver}}" | grep -E "(NAME|igra-orchestra)" || echo "No igra-orchestra volumes found"
    exit 1
fi
log_message "Volume $VOLUME_NAME exists and will be backed up."

# Ensure container is unpaused even if script exits unexpectedly
# Note: This trap might not catch all termination signals (like SIGKILL)
trap 'log_message "Attempting to unpause container $CONTAINER_NAME due to script exit..."; docker unpause "$CONTAINER_NAME" 2>/dev/null || true; log_message "Trap finished."' EXIT

# Create backup directory if it doesn't exist
mkdir -p "$BACKUP_DIR"

# Start time measurement
TOTAL_START_TIME=$(date +%s)
log_message "===== Backup Started ====="
log_message "Volume: $VOLUME_NAME"
log_message "Container: $CONTAINER_NAME"
log_message "Backup Dir: $BACKUP_DIR"
log_message "Keep Backups: $KEEP_BACKUPS"
log_message "Gzip Level: ${GZIP_LEVEL:-default}"

# Pause the container
log_message "Pausing container $CONTAINER_NAME..."
PAUSE_START_TIME=$(date +%s)
docker pause "$CONTAINER_NAME"
PAUSE_END_TIME=$(date +%s)
PAUSE_DURATION=$((PAUSE_END_TIME - PAUSE_START_TIME))
log_message "Container paused in $PAUSE_DURATION seconds."

# Perform the backup
log_message "Creating backup file (temporary)..."
BACKUP_START_TIME=$(date +%s)
TEMP_BACKUP_FILE="${BACKUP_FILE}.tmp"

# Construct the command to run inside the container
# Use pipe for specific gzip level, otherwise use tar's built-in -z
if [ -n "$GZIP_LEVEL" ]; then
  # Pipe tar output to gzip with specific level
  CONTAINER_CMD="tar -c -C /data . | gzip -${GZIP_LEVEL} > /backup/$(basename "$TEMP_BACKUP_FILE")"
  log_message "Using tar pipe to gzip level $GZIP_LEVEL"
else
  # Use tar's built-in gzip compression (default level)
  CONTAINER_CMD="tar -czf /backup/$(basename "$TEMP_BACKUP_FILE") -C /data ."
  log_message "Using tar built-in gzip compression"
fi

# Execute the command in the container
if ! docker run --rm -v "$VOLUME_NAME":/data:ro -v "$BACKUP_DIR":/backup:rw alpine sh -c "$CONTAINER_CMD"; then
    log_message "ERROR: Failed to create backup archive inside container. Check volume/permissions."
    # EXIT trap will handle unpausing
    exit 1
fi

BACKUP_END_TIME=$(date +%s)
BACKUP_DURATION=$((BACKUP_END_TIME - BACKUP_START_TIME))
log_message "Backup temporary file created in $BACKUP_DURATION seconds."

# Unpause the container (Moved EARLIER to reduce frozen time)
log_message "Unpausing container $CONTAINER_NAME..."
UNPAUSE_START_TIME=$(date +%s)
docker unpause "$CONTAINER_NAME"
UNPAUSE_END_TIME=$(date +%s)
UNPAUSE_DURATION=$((UNPAUSE_END_TIME - UNPAUSE_START_TIME))
log_message "Container unpaused in $UNPAUSE_DURATION seconds."

# Disable the EXIT trap now that we've successfully unpaused
trap - EXIT

# --- Container is now running ---

# Verify the backup integrity (Moved AFTER unpause)
log_message "Verifying backup integrity ($TEMP_BACKUP_FILE)..."
VERIFY_START_TIME=$(date +%s)
VERIFICATION_SUCCESSFUL=false
if gunzip -t "$TEMP_BACKUP_FILE"; then
  # Integrity check passed, rename the temp file
  mv "$TEMP_BACKUP_FILE" "$BACKUP_FILE"
  log_message "Backup verification successful. Renamed to $BACKUP_FILE."
  VERIFICATION_SUCCESSFUL=true
else
  log_message "Backup verification failed! Checksum error on $TEMP_BACKUP_FILE."
  rm -f "$TEMP_BACKUP_FILE" # Remove corrupted temp file
  log_message "Removed corrupted temporary file."
fi
VERIFY_END_TIME=$(date +%s)
VERIFY_DURATION=$((VERIFY_END_TIME - VERIFY_START_TIME))
log_message "Backup verified in $VERIFY_DURATION seconds."

# Get backup file size (Only if verification was successful)
BACKUP_SIZE="N/A"
if [ "$VERIFICATION_SUCCESSFUL" = true ]; then
    BACKUP_SIZE=$(du -sh "$BACKUP_FILE" | cut -f1)
    # Prune old backups (Only if a new backup was successfully created)
    log_message "Pruning old backups (keeping last $KEEP_BACKUPS)..."
    # List files matching the pattern, sort by time, take all but the last N, delete them
    ls -1t "$BACKUP_DIR"/"${VOLUME_NAME}"_*.tar.gz | tail -n +$((KEEP_BACKUPS + 1)) | xargs -r rm -fv | tee -a "$LOG_FILE"
    log_message "Pruning complete."
fi

# Check volume size (Moved AFTER unpause)
log_message "Calculating volume size..."
VOLUME_SIZE=$(docker run --rm -v "$VOLUME_NAME":/data:ro alpine sh -c "du -sh /data | cut -f1")
log_message "Volume size: $VOLUME_SIZE"


# Calculate times
TOTAL_END_TIME=$(date +%s)
TOTAL_DURATION=$((TOTAL_END_TIME - TOTAL_START_TIME))
# Recalculate frozen time (Verification is no longer included)
CONTAINER_FROZEN_TIME=$((PAUSE_DURATION + BACKUP_DURATION + UNPAUSE_DURATION))

# Summary
log_message ""
log_message "===== Backup Summary ====="
log_message "Backup completed at: $(date '+%Y-%m-%d %H:%M:%S')"
if [ "$VERIFICATION_SUCCESSFUL" = true ]; then
  log_message "Backup file: $BACKUP_FILE"
  log_message "Backup size: $BACKUP_SIZE"
else
  log_message "Backup file: FAILED_VERIFICATION ($TEMP_BACKUP_FILE removed)"
  log_message "Backup size: N/A"
fi
log_message "Volume size: $VOLUME_SIZE"
log_message ""
log_message "Time Measurements:"
log_message "  Container pause time: $PAUSE_DURATION seconds"
log_message "  Backup creation time: $BACKUP_DURATION seconds"
log_message "  Container unpause time: $UNPAUSE_DURATION seconds"
log_message "  --- Container Frozen Time: $CONTAINER_FROZEN_TIME seconds ---" # Highlight the key metric
log_message "  Backup verification time: $VERIFY_DURATION seconds (after unpause)"
log_message "  Total backup process time: $TOTAL_DURATION seconds"
log_message "============================="

if [ "$VERIFICATION_SUCCESSFUL" != true ]; then
  exit 1 # Exit with error if verification failed
fi

# Optional S3 upload integration
# Set S3_BACKUP_AUTO_UPLOAD=true in .env to enable automatic S3 upload after successful backup
if [ "$VERIFICATION_SUCCESSFUL" = true ] && [ "${S3_BACKUP_AUTO_UPLOAD,,}" = "true" ]; then
  log_message "S3 auto-upload is enabled, starting upload process..."
  
  # Get the directory where this script is located
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  S3_UPLOAD_SCRIPT="$SCRIPT_DIR/upload-to-s3.sh"
  
  if [ -x "$S3_UPLOAD_SCRIPT" ]; then
    log_message "Calling S3 upload script for container: $CONTAINER_NAME"
    if "$S3_UPLOAD_SCRIPT" "$CONTAINER_NAME" "$BACKUP_FILE"; then
      log_message "S3 upload completed successfully"
    else
      log_message "WARNING: S3 upload failed, but local backup was successful"
    fi
  else
    log_message "WARNING: S3 upload script not found or not executable: $S3_UPLOAD_SCRIPT"
  fi
fi