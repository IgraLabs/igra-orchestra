#!/bin/sh
# Parse NETWORK (<family>[-<digits>]) into KASPA_FAMILY and KASPA_NETSUFFIX.
# Sourced by compose entrypoints; exits on malformed slugs.

KASPA_FAMILY=""
KASPA_NETSUFFIX=""

# Reject unsafe bytes before structural checks; sanitize error output for logs.
case "$NETWORK" in
  *[![:alnum:]-]*)
    sanitized=$(printf '%s' "$NETWORK" | tr -dc '[:print:]')
    echo "Invalid NETWORK slug (illegal characters): '$sanitized'" >&2
    exit 1
    ;;
esac
case "$NETWORK" in
  ""|*-|-*|*--*)
    echo "Invalid NETWORK slug: '$NETWORK' (must be <family>[-<digits>])" >&2
    exit 1
    ;;
esac
# Transitional alias for Galleon; warn so operators migrate .env.
if [ "$NETWORK" = "testnet" ]; then
  echo "WARN: NETWORK=testnet is a deprecated alias for testnet-10; update .env (or run scripts/dev/migrate-galleon-to-testnet-10.sh)." >&2
  NETWORK="testnet-10"
fi
case "$NETWORK" in
  *-*) KASPA_FAMILY="${NETWORK%%-*}"; KASPA_NETSUFFIX="${NETWORK#*-}" ;;
  *)   KASPA_FAMILY="$NETWORK";       KASPA_NETSUFFIX="" ;;
esac
case "$KASPA_FAMILY" in
  mainnet|testnet|devnet) ;;
  *)
    echo "Unknown KASPA_FAMILY=$KASPA_FAMILY (from NETWORK=$NETWORK)" >&2
    exit 1
    ;;
esac
if [ "$KASPA_FAMILY" = "mainnet" ] && [ -n "$KASPA_NETSUFFIX" ]; then
  echo "mainnet must not have a netsuffix (got NETWORK=$NETWORK)" >&2
  exit 1
fi
if [ -n "$KASPA_NETSUFFIX" ]; then
  case "$KASPA_NETSUFFIX" in
    *[!0-9]*)
      echo "NETSUFFIX must be digits (got '$KASPA_NETSUFFIX' from NETWORK=$NETWORK)" >&2
      exit 1
      ;;
  esac
fi
