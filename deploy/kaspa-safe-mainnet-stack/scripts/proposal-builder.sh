#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/.env.proposal-builder}"
CONFIG_FILE="${CONFIG_FILE:-${DEPLOY_DIR}/config/proposal-builder.json}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.proposal-builder.yml"

usage() {
    cat <<'USAGE'
Usage: ./scripts/proposal-builder.sh <command>

Commands:
  prepare          Create local env/config templates and clone/update source repos
  check-config     Validate mainnet proposal-builder env/config locally
  config           Validate docker compose config
  build            Build proposal-builder image
  validate-config  Run igra-proposal-builder validate-config inside Docker
  up               Start the proposal-builder daemon container
  down             Stop proposal-builder
  logs             Follow proposal-builder logs
  status           Show proposal-builder container

USAGE
}

compose() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

check_config() {
    "${DEPLOY_DIR}/scripts/check-env.sh" builder "$ENV_FILE" "$CONFIG_FILE"
}

case "${1:-}" in
    prepare)
        "${DEPLOY_DIR}/scripts/prepare.sh"
        ;;
    check-config)
        check_config
        ;;
    config)
        check_config
        compose config --quiet
        ;;
    build)
        check_config
        compose build proposal-builder
        ;;
    validate-config)
        check_config
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
        compose run --rm \
            --entrypoint /usr/local/bin/igra-proposal-builder \
            proposal-builder \
            --config "${IGRA_PROPOSAL_BUILDER_CONFIG:-/config/proposal-builder.json}" \
            validate-config
        ;;
    up)
        check_config
        compose up -d proposal-builder
        ;;
    down)
        compose down
        ;;
    logs)
        compose logs -f proposal-builder
        ;;
    status)
        compose ps
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
