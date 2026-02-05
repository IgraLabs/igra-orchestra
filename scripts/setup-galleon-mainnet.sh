#!/bin/bash
# setup-galleon-mainnet.sh - Interactive setup script for IGRA Galleon Mainnet
#
# This script guides users through the Galleon mainnet deployment.
# For implementation details, see scripts/lib/setup-common.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Environment-specific configuration (used by sourced setup-common.sh)
# shellcheck disable=SC2034
ENV_NAME="Galleon Mainnet"
# shellcheck disable=SC2034
ENV_FILE=".env.galleon-mainnet.example"
# shellcheck disable=SC2034
NODE_ID_PREFIX="GMN-"
# shellcheck disable=SC2034
KASWALLET_FLAG="--enable-mainnet-pre-launch"

# Source common library and run setup
source "$SCRIPT_DIR/lib/setup-common.sh"
run_setup "$@"
