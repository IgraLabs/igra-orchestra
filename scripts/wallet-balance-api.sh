#!/bin/sh
# shellcheck shell=sh
# Note: runs in BusyBox ash which supports read -t (non-POSIX but available)

# Wallet Balance API — lightweight HTTP server that returns kaswallet balances as JSON.
# Runs inside a docker:cli (Alpine) container with the Docker socket mounted.
# Dependencies: jq, socat (installed at startup via apk).
#
# When invoked without arguments: installs deps and starts socat listener on port 8090.
# When invoked with --handle: acts as the per-connection HTTP handler (called by socat).

set -eu

MAX_WORKERS=20

# ── HTTP helpers ──────────────────────────────────────────────────────────────

send_response() {
  status_code="$1"
  status_text="$2"
  body="$3"
  content_length=$(printf '%s' "$body" | wc -c | tr -d ' ')
  printf "HTTP/1.1 %s %s\r\n" "$status_code" "$status_text"
  printf "Content-Type: application/json\r\n"
  printf "Content-Length: %d\r\n" "$content_length"
  printf "Connection: close\r\n"
  printf "\r\n"
  printf '%s' "$body"
}

# ── Wallet query (reuses jq pattern from scripts/debug/wallet-status.sh) ─────

query_wallets() {
  # Pre-fetch running kaswallet containers in a single Docker API call
  running=$(docker ps --filter "name=^kaswallet-" --filter "status=running" --format '{{.Names}}' 2>&1) || {
    printf '{"error":"docker unavailable: %s"}' "$running"
    return 1
  }

  # Early return if no wallets are running
  if [ -z "$running" ]; then
    printf '{"wallets":[]}'
    return
  fi

  # Collect wallet JSON objects into a temp file, then merge in one jq call
  tmpfile=$(mktemp)
  for i in $(seq 0 $((MAX_WORKERS - 1))); do
    container="kaswallet-$i"

    # Skip containers that are not running
    echo "$running" | grep -qx "$container" || continue

    output=$(docker exec "$container" /app/kaswallet-cli address-balances 2>/dev/null) || continue

    printf '%s' "$output" | jq --argjson index "$i" '{
      index: $index,
      default_address: .default_address,
      total: {
        available_sompi: .total_available,
        available_kas: (.total_available / 100000000),
        pending_sompi: .total_pending,
        pending_kas: (.total_pending / 100000000)
      }
    }' 2>/dev/null >> "$tmpfile" || continue
  done

  jq -s '{wallets: .}' "$tmpfile"
  rm -f "$tmpfile"
}

# ── Per-connection handler mode ───────────────────────────────────────────────

if [ "${1:-}" = "--handle" ]; then
  # Read the HTTP request line (5s timeout to avoid blocking on misbehaving clients)
  if ! read -r -t 5 method path _version; then
    send_response 408 "Request Timeout" '{"error":"request timeout"}'
    exit 0
  fi

  # Trim trailing carriage return
  method=$(printf '%s' "$method" | tr -d '\r')
  path=$(printf '%s' "$path" | tr -d '\r')

  # Reject paths with unsafe characters (defense-in-depth)
  case "$path" in
    *[!a-zA-Z0-9/_-.]*)
      send_response 400 "Bad Request" '{"error":"invalid path"}'
      exit 0
      ;;
  esac

  # Consume remaining headers (read until empty line)
  while read -r -t 5 header; do
    header=$(printf '%s' "$header" | tr -d '\r')
    [ -z "$header" ] && break
  done

  case "$method $path" in
    "GET /health")
      send_response 200 "OK" '{"status":"ok"}'
      ;;
    "GET /internal/wallets")
      if body=$(query_wallets); then
        send_response 200 "OK" "$body"
      else
        send_response 503 "Service Unavailable" "$body"
      fi
      ;;
    *)
      send_response 404 "Not Found" '{"error":"not found"}'
      ;;
  esac

  exit 0
fi

# ── Server startup mode (default) ────────────────────────────────────────────

# Fail-fast: require BasicAuth env var (used by Traefik for endpoint protection)
if [ -z "${WALLET_API_BASICAUTH:-}" ]; then
  echo "ERROR: WALLET_API_BASICAUTH is not set." >&2
  echo "  This variable is required by Traefik for BasicAuth on /internal/wallets." >&2
  echo "  Generate it with: htpasswd -nb admin YOUR_PASSWORD | sed 's/\$/\$\$/g'" >&2
  exit 1
fi

# Install runtime dependencies
apk add --no-cache jq socat >/dev/null || { echo "ERROR: failed to install dependencies (jq, socat)" >&2; exit 1; }

echo "Wallet Balance API listening on port 8090..."
exec socat TCP-LISTEN:8090,reuseaddr,fork,max-children=10 SYSTEM:"sh /app/serve.sh --handle"
