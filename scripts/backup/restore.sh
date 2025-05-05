#!/bin/bash
set -e # Exit immediately if a command exits with a non-zero status, except where handled.

# Check for container name argument
if [ -z "$1" ]; then
    echo "Error: Container name is required"
    echo "Usage: $0 <container_name> [backup_file]"
    exit 1
fi

# Configuration based on container name
CONTAINER_NAME="$1"
VOLUME_NAME="igra-orchestra-devnet_${CONTAINER_NAME}_data"
BACKUP_DIR="$HOME/.backups/${CONTAINER_NAME}-backups"

# Function for logging/output
log_message() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - INFO - $1"
}

log_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - ERROR - $1" >&2 # Log errors to stderr
}

# --- Pre-flight Checks ---
log_message "Performing pre-flight checks..."

# Check if docker command exists
if ! command -v docker &> /dev/null; then
    log_error "Docker command not found. Please install Docker and ensure it's in your PATH."
    exit 1
fi

# Check if docker daemon is running
if ! docker info > /dev/null 2>&1; then
    log_error "Cannot connect to the Docker daemon. Is the docker daemon running?"
    exit 1
fi

# Check if backup directory exists
if [ ! -d "$BACKUP_DIR" ]; then
    log_error "Backup directory not found: $BACKUP_DIR"
    exit 1
fi

# --- Determine Backup File ---
BACKUP_FILE_TO_RESTORE=""
if [ -z "$2" ]; then
  # No backup file provided, find the latest backup
  log_message "No specific backup file provided. Finding the latest backup..."
  # Use find for safer handling of filenames and ensure we get the latest file
  LATEST_BACKUP=$(find "$BACKUP_DIR" -maxdepth 1 -name "${VOLUME_NAME}_*.tar.gz" -printf '%T@ %p\n' | sort -nr | head -n 1 | cut -d' ' -f2-)

  if [ -z "$LATEST_BACKUP" ]; then
    log_error "No backup files found in $BACKUP_DIR matching the pattern '${VOLUME_NAME}_*.tar.gz'."
    exit 1
  fi
  BACKUP_FILE_TO_RESTORE="$LATEST_BACKUP"
  log_message "Latest backup found: $BACKUP_FILE_TO_RESTORE"
else
  # Use the provided argument as the backup file path
  if [ ! -f "$2" ]; then
    log_error "Specified backup file does not exist or is not a regular file: $2"
    exit 1
  fi
  BACKUP_FILE_TO_RESTORE="$2"
  log_message "Using specified backup file: $BACKUP_FILE_TO_RESTORE"
fi

BACKUP_DIR_HOST=$(dirname "$BACKUP_FILE_TO_RESTORE")
BACKUP_FILENAME=$(basename "$BACKUP_FILE_TO_RESTORE")

# --- Check Backup File Integrity ---
log_message "Verifying integrity of backup file '$BACKUP_FILENAME'..."
if ! gunzip -t "$BACKUP_FILE_TO_RESTORE"; then
    log_error "Backup file integrity check failed (gunzip -t). The file may be corrupted."
    exit 1
fi
log_message "Backup file integrity check successful."

# --- Check Docker Resources ---
# Check if volume exists
if ! docker volume inspect "$VOLUME_NAME" > /dev/null 2>&1; then
    log_message "Volume '$VOLUME_NAME' does not exist. Creating it..."
    if ! docker volume create "$VOLUME_NAME"; then
        log_error "Failed to create volume '$VOLUME_NAME'."
        exit 1
    fi
    log_message "Volume '$VOLUME_NAME' created."
else
    log_message "Target volume '$VOLUME_NAME' exists."
fi

# Check if container exists
CONTAINER_EXISTS=$(docker ps -a --filter "name=^/${CONTAINER_NAME}$" --format '{{.Names}}')

# --- Restore Process ---
log_message "Starting restore for volume '$VOLUME_NAME' from '$BACKUP_FILENAME'"

# 1. Stop the container if it exists
if [ -n "$CONTAINER_EXISTS" ]; then
    log_message "Attempting to stop container '$CONTAINER_NAME'..."
    # Check if it's running before trying to stop
    if docker ps --filter "name=^/${CONTAINER_NAME}$" --filter "status=running" --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        if ! docker stop "$CONTAINER_NAME"; then
            log_error "Failed to stop container '$CONTAINER_NAME'. Please check manually."
            # Decide if you want to exit here or continue with caution
            # exit 1
        else
            log_message "Container '$CONTAINER_NAME' stopped."
        fi
    else
        log_message "Container '$CONTAINER_NAME' exists but is not running."
    fi
else
    log_message "Container '$CONTAINER_NAME' does not exist. Skipping stop step."
fi

# 2. Confirmation before clearing volume
echo ""
log_message "WARNING: The next step will clear all current data in volume '$VOLUME_NAME'."
read -p "Are you sure you want to proceed with clearing the volume and restoring? (y/N) " -n 1 -r
echo "" # move to a new line
if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    log_message "Restore cancelled by user."
    # Attempt to restart the container only if it existed and was stopped by this script
    if [ -n "$CONTAINER_EXISTS" ]; then
       log_message "Attempting to restart container '$CONTAINER_NAME'..."
       docker start "$CONTAINER_NAME" || log_message "Container '$CONTAINER_NAME' could not be restarted. It might have been stopped before the script ran."
    fi
    exit 1
fi

# 3. Clear the current volume contents
log_message "Clearing current data in volume '$VOLUME_NAME'..."
if ! docker run --rm -v "$VOLUME_NAME":/data_to_clear alpine sh -c "find /data_to_clear -mindepth 1 -delete"; then
    log_error "Failed to clear volume '$VOLUME_NAME'. Check Docker permissions and volume status."
    exit 1
fi
log_message "Volume cleared."

# 4. Perform the restore
log_message "Restoring data from '$BACKUP_FILENAME' into '$VOLUME_NAME'..."
RESTORE_START_TIME=$(date +%s)
if ! docker run --rm \
  -v "$VOLUME_NAME":/restore_target:rw \
  -v "$BACKUP_DIR_HOST":/backup_source:ro \
  alpine sh -c "tar -xzf /backup_source/\"$BACKUP_FILENAME\" -C /restore_target"; then
    log_error "Failed to extract backup file '$BACKUP_FILENAME' into volume '$VOLUME_NAME'."
    # Note: Volume might be in an inconsistent state here.
    exit 1
fi
RESTORE_END_TIME=$(date +%s)
RESTORE_DURATION=$((RESTORE_END_TIME - RESTORE_START_TIME))
log_message "Restore completed in $RESTORE_DURATION seconds."

log_message "===== Restore Finished Successfully ====="
exit 0