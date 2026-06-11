#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${DEPLOY_DIR}/../.." && pwd)"
SAFE_ENV="${DEPLOY_DIR}/.env.safe"
BUILDER_ENV="${DEPLOY_DIR}/.env.proposal-builder"

log() {
    printf '[kaspa-safe-mainnet] %s\n' "$*"
}

sync_repo() {
    local dir="$1"
    local url="$2"
    local branch="$3"

    if [[ ! -d "${dir}/.git" ]]; then
        log "Cloning ${url} -> ${dir}"
        git clone "$url" "$dir"
    else
        log "Updating ${dir}"
        git -C "$dir" fetch origin
    fi

    git -C "$dir" checkout "$branch"
    git -C "$dir" pull --ff-only origin "$branch"
}

mkdir -p \
    "${ROOT_DIR}/build/repos" \
    "${DEPLOY_DIR}/config" \
    "${DEPLOY_DIR}/refs" \
    "${DEPLOY_DIR}/state"

if [[ ! -f "$SAFE_ENV" ]]; then
    cp "${DEPLOY_DIR}/.env.safe.example" "$SAFE_ENV"
    log "Created .env.safe. Fill every CHANGE_ME before starting mainnet."
fi

if [[ ! -f "$BUILDER_ENV" ]]; then
    cp "${DEPLOY_DIR}/.env.proposal-builder.example" "$BUILDER_ENV"
    log "Created .env.proposal-builder."
fi

if [[ ! -f "${DEPLOY_DIR}/config/proposal-builder.json" ]]; then
    cp \
        "${DEPLOY_DIR}/config/proposal-builder.mainnet.example.json" \
        "${DEPLOY_DIR}/config/proposal-builder.json"
    log "Created config/proposal-builder.json. Fill real mainnet values before starting proposal-builder."
fi

set -a
# shellcheck source=/dev/null
source "$SAFE_ENV"
set +a

sync_repo \
    "${ROOT_DIR}/build/repos/safe-transaction-service" \
    "${SAFE_TRANSACTION_SERVICE_REPO_URL:-git@github.com:IgraLabs/safe-transaction-service.git}" \
    "${SAFE_TRANSACTION_SERVICE_BRANCH:-kaspa-native-wallet-integration}"

set -a
# shellcheck source=/dev/null
source "$BUILDER_ENV"
set +a

sync_repo \
    "${ROOT_DIR}/build/repos/igra-proposal-builder-rs" \
    "${IGRA_PROPOSAL_BUILDER_RS_REPO_URL:-git@github.com:IgraLabs/igra-proposal-builder-rs.git}" \
    "${IGRA_PROPOSAL_BUILDER_RS_BRANCH:-feature/rust-proposal-builder}"

cat <<EOF
[kaspa-safe-mainnet] Prepare complete.

Next:
  1. Edit ${SAFE_ENV}
  2. Edit ${DEPLOY_DIR}/config/proposal-builder.json
  3. Put mainnet reference files in ${DEPLOY_DIR}/refs
  4. Run ./scripts/safe.sh config
EOF
