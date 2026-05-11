#!/bin/bash
# setup-frigate-testnet.sh - Interactive setup script for IGRA Frigate Testnet (testnet-12)
#
# This script guides users through the Frigate testnet deployment.
# For implementation details, see scripts/lib/setup-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Environment-specific configuration (used by sourced setup-common.sh)
# shellcheck disable=SC2034
ENV_NAME="Frigate Testnet (testnet-12)"
# shellcheck disable=SC2034
ENV_FILE=".env.frigate-testnet.example"
# shellcheck disable=SC2034
NODE_ID_PREFIX="FTN-"
# shellcheck disable=SC2034
KASWALLET_FLAG="--testnet --testnet-suffix=12"

# Upstream RPC load balancer hostname for this network. setup-common.sh
# resolves this and writes ORCHESTRA_TRUSTED_PROXIES into .env so orchestra's
# Traefik trusts the LB's X-Forwarded-For header (ENG-1020).
# Empty until ops decides a Frigate hostname; allow an exported value to
# override the default before setup-common.sh writes ORCHESTRA_TRUSTED_PROXIES.
# shellcheck disable=SC2034
RPC_LB_HOSTNAME="${RPC_LB_HOSTNAME:-}"

# Version file for this network
# shellcheck disable=SC2034
VERSIONS_FILE="versions.frigate-testnet.env"

# Source common library and run setup
source "$SCRIPT_DIR/lib/setup-common.sh"
run_setup "$@"
