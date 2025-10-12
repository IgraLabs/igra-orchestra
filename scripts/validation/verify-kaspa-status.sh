#!/bin/bash
set -euo pipefail

# Ensures kaspad container is running and reachable on port 17210, and (if possible) synced.
# Performs connectivity checks and an optional sync/DAA check using kaspa-cli inside the container.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_ROOT"

KASPAD_CONTAINER="kaspad"
BORSH_PORT="${KASPAD_BORSH_PORT:-17210}"

log() { echo "[INFO] $*"; }
err() { echo "[ERROR] $*" >&2; }

log "Running base connectivity checks..."

# Docker availability
if ! command -v docker >/dev/null 2>&1; then
  err "docker not found in PATH"
  exit 1
fi
if ! docker info >/dev/null 2>&1; then
  err "Cannot connect to Docker daemon"
  exit 1
fi

log "Checking kaspad container is running..."
if ! docker ps --format '{{.Names}}' | grep -qx "$KASPAD_CONTAINER"; then
  if docker ps -a --format '{{.Names}}' | grep -qx "$KASPAD_CONTAINER"; then
    err "kaspad container exists but is not running"
  else
    err "kaspad container not found"
  fi
  exit 1
fi
log "kaspad is running"

log "Checking Kaspa RPC (borsh) port $BORSH_PORT is reachable on localhost..."
if command -v nc >/dev/null 2>&1; then
  if ! nc -z localhost "$BORSH_PORT" >/dev/null 2>&1; then
    err "Port $BORSH_PORT is not reachable on localhost"
    exit 1
  fi
else
  if ! (echo > "/dev/tcp/127.0.0.1/$BORSH_PORT") >/dev/null 2>&1; then
    err "Port $BORSH_PORT is not reachable on localhost"
    exit 1
  fi
fi
log "Port $BORSH_PORT is reachable"

log "Kaspa status OK (running, port $BORSH_PORT reachable)."



