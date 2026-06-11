#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ROOT_DIR="$(cd "${DEPLOY_DIR}/../.." && pwd)"
ENV_FILE="${DEPLOY_DIR}/.env"

log() {
    printf '[kaspa-safe-stack] %s\n' "$*"
}

replace_env_value() {
    local key="$1"
    local value="$2"
    local tmp
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        case "$line" in
            "${key}="*) printf '%s=%s\n' "$key" "$value" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$ENV_FILE" > "$tmp"
    mv "$tmp" "$ENV_FILE"
}

sync_repo() {
    local dir="$1"
    local url="$2"
    local branch="$3"

    if [[ -z "$url" ]]; then
        log "Skipping empty repo URL for ${dir}"
        return
    fi

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

if [[ ! -f "$ENV_FILE" ]]; then
    cp "${DEPLOY_DIR}/.env.example" "$ENV_FILE"
    if command -v openssl >/dev/null 2>&1; then
        postgres_password="$(openssl rand -hex 24)"
        django_secret="$(openssl rand -hex 48)"
        replace_env_value POSTGRES_PASSWORD "$postgres_password"
        replace_env_value DJANGO_SECRET_KEY "$django_secret"
        replace_env_value DATABASE_URL "psql://safe:${postgres_password}@postgres:5432/safe_transaction_service"
    fi
    log "Created ${ENV_FILE}. Review it before production use."
fi

set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a

sync_repo \
    "${ROOT_DIR}/build/repos/safe-transaction-service" \
    "${SAFE_TRANSACTION_SERVICE_REPO_URL:-git@github.com:IgraLabs/safe-transaction-service.git}" \
    "${SAFE_TRANSACTION_SERVICE_BRANCH:-kaspa-native-wallet-integration}"

sync_repo \
    "${ROOT_DIR}/build/repos/igra-proposal-builder-rs" \
    "${IGRA_PROPOSAL_BUILDER_RS_REPO_URL:-git@github.com:IgraLabs/igra-proposal-builder-rs.git}" \
    "${IGRA_PROPOSAL_BUILDER_RS_BRANCH:-feature/rust-proposal-builder}"

if [[ ! -f "${DEPLOY_DIR}/config/proposal-builder.json" ]]; then
    cp "${DEPLOY_DIR}/config/proposal-builder.example.json" "${DEPLOY_DIR}/config/proposal-builder.json"
    log "Created config/proposal-builder.json from example. Edit it before starting proposal-builder."
fi

log "Ready. Next: ${DEPLOY_DIR}/scripts/stack.sh build"
