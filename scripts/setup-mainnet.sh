#!/bin/bash
# setup-mainnet.sh - Interactive setup script for IGRA Mainnet
#
# This script guides users through the IGRA mainnet deployment.
# For implementation details, see scripts/lib/setup-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Environment-specific configuration (used by sourced setup-common.sh)
# shellcheck disable=SC2034
ENV_NAME="IGRA Mainnet"
# shellcheck disable=SC2034
ENV_FILE=".env.mainnet.example"
# shellcheck disable=SC2034
NODE_ID_PREFIX="MN-"
# shellcheck disable=SC2034
KASWALLET_FLAG="--enable-mainnet-pre-launch"

# Upstream RPC load balancer hostname for this network. setup-common.sh
# resolves this and writes ORCHESTRA_TRUSTED_PROXIES into .env so orchestra's
# Traefik trusts the LB's X-Forwarded-For header (ENG-1020).
# shellcheck disable=SC2034
RPC_LB_HOSTNAME="${RPC_LB_HOSTNAME:-rpc.igralabs.com}"

# Version file for this network
# shellcheck disable=SC2034
VERSIONS_FILE="versions.mainnet.env"

# Source common library and run setup
source "$SCRIPT_DIR/lib/setup-common.sh"
run_setup "$@"
