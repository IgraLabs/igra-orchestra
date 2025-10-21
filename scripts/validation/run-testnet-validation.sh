#!/bin/bash
set -euo pipefail

# Unified testnet validation orchestrator
# - Loads .env
# - Accepts L1 reference parameters as arguments
# - Phase 1: clean backend and reset viaduct volume
# - Phase 2: ensure/download backup and restore to viaduct volume
# - Phase 3: start backend services
# - Phase 4: start frontend worker and verify health

# Run the script 
#  ./scripts/validation/run-testnet-validation.sh \
#    --l1-daa-score 286049397 \
#    --l1-timestamp 1761034187 \
#    --igra-launch-score 286049397

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

START_TIME=$(date +%s)
SUMMARY_ERRORS=()

# Exit codes
EXIT_SUCCESS=0
EXIT_CONFIG_ERROR=2
EXIT_RUNTIME_ERROR=3

# Logging utilities
log() { echo "[INFO] $*"; }
success() { echo -e "\033[32m[SUCCESS]\033[0m $*"; }
warn() { echo -e "\033[33m[WARNING]\033[0m $*"; }
err() { echo -e "\033[31m[ERROR]\033[0m $*" >&2; }

# Cleanup and summary on EXIT
summary() {
  local end_time=$(date +%s)
  local total=$((end_time - START_TIME))
  echo
  log "===== Validation Summary ====="
  log "Project root: $PROJECT_ROOT"
  if [ ${#SUMMARY_ERRORS[@]} -eq 0 ]; then
    success "All phases completed successfully"
  else
    err "Encountered ${#SUMMARY_ERRORS[@]} error(s):"
    for e in "${SUMMARY_ERRORS[@]}"; do err "- $e"; done
  fi
  log "Total time: ${total}s"
  log "=============================="
}
trap summary EXIT

# Show usage information
show_usage() {
  cat <<EOF
Usage: $0 --l1-daa-score <value> --l1-timestamp <value> --igra-launch-score <value> [OPTIONS]

Unified testnet validation orchestrator that sets up and validates the IGRA testnet environment.

Required Arguments:
  --l1-daa-score <value>        Kaspa's virtual DAA score at reference point
  --l1-timestamp <value>        Unix timestamp corresponding to reference DAA
  --igra-launch-score <value>   DAA score when IGRA launched (L2 genesis point on L1)

Optional Arguments:
  --download-backup             Download and restore viaduct backup from S3 (downloads if not present locally)
  --backup-file <file>          Specific backup file to restore (requires --download-backup)
  -h, --help                    Show this help message

Examples:
  # Without backup download (use existing volume)
  $0 --l1-daa-score 200184247 --l1-timestamp 1752450516 --igra-launch-score 206700000

  # Download latest backup
  $0 --l1-daa-score 200184247 --l1-timestamp 1752450516 --igra-launch-score 206700000 --download-backup

  # Download specific backup file
  $0 --l1-daa-score 200184247 \\
     --l1-timestamp 1752450516 \\
     --igra-launch-score 206700000 \\
     --download-backup \\
     --backup-file igra-orchestra-testnet_viaduct_data_20250115_120000.tar.gz

Environment:
  Loads configuration from .env

Phases:
  1. Clean backend and reset viaduct volume (if RESET_VIADUCT=true)
  2. Download/restore backup to viaduct volume (if --download-backup flag provided)
  3. Start backend services (execution-layer, block-builder, viaduct)
  4. Start frontend worker and verify health
EOF
}

# Env loading
load_env() {
  local env_file=".env"
  if [[ -f "$env_file" ]]; then
    log "Loading $env_file"
    # Use set -a to automatically export all variables, properly handling empty values
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  else
    SUMMARY_ERRORS+=("$env_file not found in $PROJECT_ROOT")
    err "$env_file not found in $PROJECT_ROOT"
    exit $EXIT_CONFIG_ERROR
  fi
  if [[ -z "${NETWORK:-}" ]]; then
    SUMMARY_ERRORS+=("NETWORK not set in $env_file")
    err "NETWORK is not set in $env_file (expected: testnet/mainnet/devnet)"
    exit $EXIT_CONFIG_ERROR
  fi
}

# Basic prerequisites
check_prereqs() {
  if ! command -v docker >/dev/null 2>&1; then
    SUMMARY_ERRORS+=("docker not found in PATH")
    err "docker not found in PATH"
    exit $EXIT_RUNTIME_ERROR
  fi
  if ! docker info >/dev/null 2>&1; then
    SUMMARY_ERRORS+=("Cannot talk to Docker daemon")
    err "Cannot talk to Docker daemon. Is it running?"
    exit $EXIT_RUNTIME_ERROR
  fi
}

# Compose helpers
compose_ps_q() {
  local service="$1"
  if command -v docker compose >/dev/null 2>&1; then
    docker compose -f docker-compose.yml ps -q "$service"
  else
    docker-compose -f docker-compose.yml ps -q "$service"
  fi
}

# Get health status for a compose service (empty until container exists)
get_service_health() {
  local service="$1"
  local cid
  cid=$(compose_ps_q "$service" | head -n1 || true)
  if [[ -z "$cid" ]]; then
    echo ""
    return 0
  fi
  docker inspect --format='{{.State.Health.Status}}' "$cid" 2>/dev/null || echo ""
}

# Compose project name resolution (align with manual usage)
get_compose_project() {
  # Allow override via COMPOSE_PROJECT_NAME, otherwise default to directory name
  if [[ -n "${COMPOSE_PROJECT_NAME:-}" ]]; then
    echo "$COMPOSE_PROJECT_NAME"
  else
    basename "$PROJECT_ROOT"
  fi
}

# Set L1 reference parameters from arguments
set_l1_reference_params() {
  local daa_score="$1"
  local timestamp="$2"
  local launch_score="$3"

  export L1_REFERENCE_DAA_SCORE="$daa_score"
  export L1_REFERENCE_TIMESTAMP="$timestamp"
  export IGRA_LAUNCH_DAA_SCORE="$launch_score"

  log "Set L1_REFERENCE_DAA_SCORE=$L1_REFERENCE_DAA_SCORE"
  log "Set L1_REFERENCE_TIMESTAMP=$L1_REFERENCE_TIMESTAMP"
  log "Set IGRA_LAUNCH_DAA_SCORE=$IGRA_LAUNCH_DAA_SCORE"
}

# Phase 1: Clean stop backend and reset viaduct volume
phase1_clean_backend() {
  log "[Phase 1] Clean stopping backend and resetting viaduct volume"
  local compose_project
  compose_project=$(get_compose_project)
  local viaduct_volume="${compose_project}_viaduct_data"
  log "Compose project: $compose_project"
  log "Viaduct volume: $viaduct_volume"

  if command -v docker compose >/dev/null 2>&1; then
    docker compose -f docker-compose.yml --profile backend down || true
  else
    docker-compose -f docker-compose.yml stop execution-layer block-builder viaduct || true
    docker-compose -f docker-compose.yml rm -f execution-layer block-builder viaduct || true
  fi

  # Only reset viaduct data if explicitly requested
  case "${RESET_VIADUCT:-false}" in
    true|TRUE|yes|YES|1)
      if docker volume inspect "$viaduct_volume" >/dev/null 2>&1; then
        docker volume rm -f "$viaduct_volume"
        success "Removed volume: $viaduct_volume"
      else
        log "Volume not found (already clean): $viaduct_volume"
      fi
      ;;
    *)
      log "Skipping viaduct volume reset (set RESET_VIADUCT=true to enable)"
      ;;
  esac
}

# Phase 2: Ensure/download backup and restore to viaduct volume
phase2_restore_viaduct() {
  log "[Phase 2] Ensuring backup and restoring viaduct volume"
  local compose_project
  compose_project=$(get_compose_project)
  local viaduct_volume="${compose_project}_viaduct_data"

  local downloader="$PROJECT_ROOT/scripts/backup/download-from-s3.sh"
  if [[ ! -f "$downloader" ]]; then
    SUMMARY_ERRORS+=("Downloader not found: $downloader")
    err "Downloader not found: $downloader"
    exit $EXIT_RUNTIME_ERROR
  fi

  export S3_BACKUP_BUCKET="igralabs-viaduct-archival-data"
  export S3_BACKUP_REGION="${S3_BACKUP_REGION:-eu-north-1}"

  # Fixed: download-from-s3.sh downloads to $HOME/.backups/viaduct-backups/ (not /viaduct/ subdirectory)
  local out_dir="$HOME/.backups/viaduct-backups"
  local backup_basename=""

  local requested_backup="${BACKUP_FILE:-${1:-}}"
  if [[ -n "$requested_backup" ]]; then
    log "Requested backup: $requested_backup (will download if missing)"
    backup_basename="$(basename "$requested_backup")"
    local local_path="$out_dir/$backup_basename"

    if [[ -f "$local_path" ]]; then
      log "Requested backup already exists locally: $local_path"
    else
      log "Downloading requested backup: $requested_backup"
      if ! "$downloader" viaduct "$requested_backup"; then
        SUMMARY_ERRORS+=("Failed to download requested backup from S3")
        err "Failed to download backup: $requested_backup"
        exit $EXIT_RUNTIME_ERROR
      fi
    fi
  else
    log "Checking for latest backup..."
    # Get list of backups from S3 to determine the latest
    local list_out
    list_out=$("$downloader" --list viaduct | sed 's/\r$//')
    local latest_key
    latest_key=$(echo "$list_out" | grep -E '\.tar\.gz$' | sed 's/^[[:space:]]*-[[:space:]]*//' | head -n1 || true)

    if [[ -z "$latest_key" ]]; then
      SUMMARY_ERRORS+=("Could not determine latest backup from S3")
      err "Could not determine latest backup from S3"
      echo "$list_out" | head -n50 >&2 || true
      exit $EXIT_RUNTIME_ERROR
    fi

    backup_basename=$(basename "$latest_key")
    local local_latest="$out_dir/$backup_basename"

    if [[ -f "$local_latest" ]]; then
      log "Latest backup already exists locally: $backup_basename"
    else
      log "Downloading latest backup: $backup_basename"
      if ! "$downloader" viaduct; then
        SUMMARY_ERRORS+=("Failed to download latest backup from S3")
        err "Failed to download latest backup from S3"
        exit $EXIT_RUNTIME_ERROR
      fi
    fi
  fi

  if [[ -z "$backup_basename" ]]; then
    SUMMARY_ERRORS+=("Backup basename could not be resolved")
    err "Could not locate downloaded backup in $out_dir"
    exit $EXIT_RUNTIME_ERROR
  fi

  local local_backup_path="$out_dir/$backup_basename"

  # Verify backup file exists
  if [[ ! -f "$local_backup_path" ]]; then
    SUMMARY_ERRORS+=("Downloaded backup file not found: $local_backup_path")
    err "Downloaded backup file not found: $local_backup_path"
    exit $EXIT_RUNTIME_ERROR
  fi

  # Verify backup integrity before restore
  log "Verifying backup integrity: $local_backup_path"
  if ! gunzip -t "$local_backup_path" 2>/dev/null; then
    SUMMARY_ERRORS+=("Backup file integrity check failed - file is corrupted")
    err "Backup file integrity check failed (gunzip -t). The file may be corrupted."
    exit $EXIT_RUNTIME_ERROR
  fi
  log "Backup integrity verified successfully"

  # Clean up old backups, keeping only the latest one
  log "Cleaning up old backups (keeping only latest: $backup_basename)..."
  local old_backups_count=0
  while IFS= read -r old_backup; do
    if [[ -n "$old_backup" && -f "$old_backup" && "$old_backup" != "$local_backup_path" ]]; then
      log "Removing old backup: $(basename "$old_backup")"
      rm -f "$old_backup"
      ((old_backups_count++))
    fi
  done < <(find "$out_dir" -maxdepth 1 -name "igra-orchestra-${NETWORK}_viaduct_data_*.tar.gz" -type f 2>/dev/null || true)

  if [[ $old_backups_count -gt 0 ]]; then
    log "Cleaned up $old_backups_count old backup(s)"
  else
    log "No old backups to clean up"
  fi

  log "Restoring backup: $local_backup_path -> volume $viaduct_volume"

  if ! docker run --rm \
    -v "$viaduct_volume":/app/storage \
    -v "$local_backup_path":/backup.tar.gz:ro \
    alpine:3.20 sh -c "rm -rf /app/storage/* && mkdir -p /app/storage && tar -xzf /backup.tar.gz -C /app/storage"; then
    SUMMARY_ERRORS+=("Failed to restore backup to volume")
    err "Failed to extract backup into volume $viaduct_volume"
    exit $EXIT_RUNTIME_ERROR
  fi

  success "Restore complete"
}

# Phase 3: Start backend services
phase3_start_backend() {
  log "[Phase 3] Starting backend services"

  # Step 1: Start execution-layer first to generate genesis
  log "Starting execution-layer to generate genesis block..."
  if command -v docker compose >/dev/null 2>&1; then
    docker compose -f docker-compose.yml up -d execution-layer
  else
    docker-compose -f docker-compose.yml up -d execution-layer
  fi

  # Step 2: Wait for execution-layer to be healthy
  log "Waiting for execution-layer to be healthy..."
  local attempts=0
  until [[ "$(get_service_health execution-layer)" == "healthy" ]]; do
    attempts=$((attempts+1))
    if [[ $attempts -gt 60 ]]; then
      SUMMARY_ERRORS+=("execution-layer not healthy after 2 minutes")
      err "execution-layer not healthy after 2 minutes"
      docker logs --tail=50 execution-layer 2>&1 || true
      exit $EXIT_RUNTIME_ERROR
    fi
    sleep 2
  done
  success "execution-layer is healthy"

  # Step 3: Extract genesis hash from execution-layer using RPC
  log "Extracting genesis hash from execution-layer..."
  local genesis_hash
  local rpc_response
  local max_attempts=10
  local attempt=0

  while [[ $attempt -lt $max_attempts ]]; do
    attempt=$((attempt+1))
    # Try to get block 0 via JSON-RPC from host (port 9545 is mapped to container's 8545)
    rpc_response=$(curl -s -X POST http://localhost:9545 \
      -H "Content-Type: application/json" \
      -d '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0",false],"id":1}' 2>/dev/null || true)

    if [[ -n "$rpc_response" ]] && [[ "$rpc_response" != *"error"* ]] && [[ "$rpc_response" != *"null"* ]]; then
      # Extract hash from JSON response using sed/grep
      genesis_hash=$(echo "$rpc_response" | sed -n 's/.*"hash":"\(0x[a-fA-F0-9]*\)".*/\1/p' | head -n1)

      if [[ -n "$genesis_hash" ]] && [[ "$genesis_hash" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
        break
      fi
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      log "RPC not ready yet, retrying in 2 seconds (attempt $attempt/$max_attempts)..."
      sleep 2
    fi
  done

  if [[ -z "$genesis_hash" ]] || ! [[ "$genesis_hash" =~ ^0x[a-fA-F0-9]{64}$ ]]; then
    SUMMARY_ERRORS+=("Failed to extract valid genesis hash from execution-layer")
    err "Failed to extract valid genesis hash from execution-layer"
    err "Last RPC response: $rpc_response"
    exit $EXIT_RUNTIME_ERROR
  fi

  export GENESIS_BLOCK_HASH="$genesis_hash"
  success "Extracted GENESIS_BLOCK_HASH: $GENESIS_BLOCK_HASH"

  # Step 4: Start block-builder and viaduct with the correct genesis hash
  log "Starting block-builder and viaduct with genesis hash..."
  if command -v docker compose >/dev/null 2>&1; then
    docker compose -f docker-compose.yml up -d block-builder viaduct
  else
    docker-compose -f docker-compose.yml up -d block-builder viaduct
  fi

  # Step 5: Wait for block-builder to be healthy
  log "Waiting for block-builder to be healthy..."
  attempts=0
  until [[ "$(get_service_health block-builder)" == "healthy" ]]; do
    attempts=$((attempts+1))
    if [[ $attempts -gt 30 ]]; then
      warn "block-builder not healthy after 1 minute (continuing anyway)"
      break
    fi
    sleep 2
  done

  # Step 6: Wait for viaduct to be healthy
  log "Waiting for viaduct to be healthy..."
  attempts=0
  until [[ "$(get_service_health viaduct)" == "healthy" ]]; do
    attempts=$((attempts+1))
    if [[ $attempts -gt 30 ]]; then
      warn "viaduct not healthy after 1 minute (continuing anyway)"
      break
    fi
    sleep 2
  done

  success "Backend services started successfully"
}

# Phase 4: Start frontend and verify health
phase4_start_frontend() {
  log "[Phase 4] Starting frontend worker and verifying health"
  if command -v docker compose >/dev/null 2>&1; then
    docker compose -f docker-compose.yml --profile frontend-w1 up -d
  else
    docker-compose -f docker-compose.yml up -d kaswallet-0 rpc-provider-0 traefik
  fi

  local attempts=0
  until [[ "$(get_service_health kaswallet-0)" == "healthy" ]]; do
    attempts=$((attempts+1))
    if [[ $attempts -gt 60 ]]; then
      SUMMARY_ERRORS+=("kaswallet-0 not healthy")
      err "kaswallet-0 not healthy"
      if command -v docker compose >/dev/null 2>&1; then
        docker compose -f docker-compose.yml ps || true
        cid=$(compose_ps_q kaswallet-0 | head -n1 || true)
        [[ -n "$cid" ]] && docker logs --tail=200 "$cid" || true
      else
        docker-compose -f docker-compose.yml ps || true
      fi
      exit $EXIT_RUNTIME_ERROR
    fi
    sleep 2
  done

  log "Starting rpc-provider-0"
  if command -v docker compose >/dev/null 2>&1; then
    docker compose -f docker-compose.yml up -d rpc-provider-0
  else
    docker-compose -f docker-compose.yml up -d rpc-provider-0
  fi

  attempts=0
  until [[ "$(get_service_health rpc-provider-0)" == "healthy" ]]; do
    attempts=$((attempts+1))
    if [[ $attempts -gt 60 ]]; then
      SUMMARY_ERRORS+=("rpc-provider-0 not healthy")
      err "rpc-provider-0 not healthy"
      if command -v docker compose >/dev/null 2>&1; then
        docker compose -f docker-compose.yml ps || true
        cid=$(compose_ps_q rpc-provider-0 | head -n1 || true)
        [[ -n "$cid" ]] && docker logs --tail=200 "$cid" || true
      else
        docker-compose -f docker-compose.yml ps || true
      fi
      exit $EXIT_RUNTIME_ERROR
    fi
    sleep 2
  done

  success "Frontend worker started and healthy"
}

main() {
  # Initialize variables
  local l1_daa_score=""
  local l1_timestamp=""
  local igra_launch_score=""
  local backup_file=""
  local download_backup=false

  # Parse named arguments
  while [[ $# -gt 0 ]]; do
    case $1 in
      -h|--help)
        show_usage
        exit $EXIT_SUCCESS
        ;;
      --l1-daa-score)
        l1_daa_score="$2"
        shift 2
        ;;
      --l1-timestamp)
        l1_timestamp="$2"
        shift 2
        ;;
      --igra-launch-score)
        igra_launch_score="$2"
        shift 2
        ;;
      --download-backup)
        download_backup=true
        shift
        ;;
      --backup-file)
        backup_file="$2"
        shift 2
        ;;
      *)
        err "Error: Unknown argument '$1'"
        echo
        show_usage
        exit $EXIT_CONFIG_ERROR
        ;;
    esac
  done

  # Validate required arguments
  if [[ -z "$l1_daa_score" ]]; then
    err "Error: Missing required argument --l1-daa-score"
    echo
    show_usage
    exit $EXIT_CONFIG_ERROR
  fi
  if [[ -z "$l1_timestamp" ]]; then
    err "Error: Missing required argument --l1-timestamp"
    echo
    show_usage
    exit $EXIT_CONFIG_ERROR
  fi
  if [[ -z "$igra_launch_score" ]]; then
    err "Error: Missing required argument --igra-launch-score"
    echo
    show_usage
    exit $EXIT_CONFIG_ERROR
  fi

  # Validate numeric arguments
  if ! [[ "$l1_daa_score" =~ ^[0-9]+$ ]]; then
    err "Error: --l1-daa-score must be a number, got: $l1_daa_score"
    exit $EXIT_CONFIG_ERROR
  fi
  if ! [[ "$l1_timestamp" =~ ^[0-9]+$ ]]; then
    err "Error: --l1-timestamp must be a number, got: $l1_timestamp"
    exit $EXIT_CONFIG_ERROR
  fi
  if ! [[ "$igra_launch_score" =~ ^[0-9]+$ ]]; then
    err "Error: --igra-launch-score must be a number, got: $igra_launch_score"
    exit $EXIT_CONFIG_ERROR
  fi

  # Validate backup file requires download flag
  if [[ -n "$backup_file" && "$download_backup" != true ]]; then
    err "Error: --backup-file requires --download-backup flag"
    echo
    show_usage
    exit $EXIT_CONFIG_ERROR
  fi

  log "Project root: $PROJECT_ROOT"
  log "L1 DAA Score: $l1_daa_score"
  log "L1 Timestamp: $l1_timestamp"
  log "IGRA Launch DAA Score: $igra_launch_score"
  log "Download backup: $download_backup"
  if [[ -n "$backup_file" ]]; then
    log "Backup file: $backup_file"
  fi
  echo

  load_env
  check_prereqs
  set_l1_reference_params "$l1_daa_score" "$l1_timestamp" "$igra_launch_score"
  phase1_clean_backend

  # Phase 2: Download and restore backup (optional)
  if [[ "$download_backup" == true ]]; then
    if [[ -n "$backup_file" ]]; then
      export BACKUP_FILE="$backup_file"
      phase2_restore_viaduct "$backup_file"
    else
      phase2_restore_viaduct
    fi
  else
    log "Skipping backup download (use --download-backup to enable)"
  fi

  phase3_start_backend
  phase4_start_frontend
}

main "$@"

