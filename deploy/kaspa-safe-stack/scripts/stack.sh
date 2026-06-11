#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/.env}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.yml"

usage() {
    cat <<'USAGE'
Usage: ./scripts/stack.sh <command>

Commands:
  prepare        Clone/update source repos and create local config files
  config         Validate/render docker compose config
  build          Build safe-api and proposal-builder images
  up             Start Postgres, Redis, run migrations, then start Safe API
  migrate        Run Django migrations once
  down           Stop Safe API, Redis, and Postgres
  restart-api    Restart only Safe API
  logs           Follow Safe API logs
  status         Show containers and Safe API /check/ result
  builder-up     Start the optional Rust proposal-builder daemon
  builder-logs   Follow proposal-builder logs
  builder-down   Stop proposal-builder

USAGE
}

compose() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

require_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "Missing ${ENV_FILE}. Run ./scripts/stack.sh prepare first." >&2
        exit 64
    fi
}

cmd="${1:-}"
case "$cmd" in
    prepare)
        "${DEPLOY_DIR}/scripts/prepare.sh"
        ;;
    config)
        require_env
        compose config --quiet
        ;;
    build)
        require_env
        compose build safe-api proposal-builder
        ;;
    migrate)
        require_env
        compose --profile migrate run --rm safe-migrate
        ;;
    up)
        require_env
        compose up -d postgres redis
        compose --profile migrate run --rm safe-migrate
        compose up -d safe-api
        ;;
    down)
        require_env
        compose down
        ;;
    restart-api)
        require_env
        compose up -d --force-recreate safe-api
        ;;
    logs)
        require_env
        compose logs -f safe-api
        ;;
    status)
        require_env
        compose ps
        if command -v curl >/dev/null 2>&1; then
            set -a
            # shellcheck source=/dev/null
            source "$ENV_FILE"
            set +a
            curl -fsS "http://127.0.0.1:${SAFE_API_PORT:-8888}/check/" || true
            echo
        fi
        ;;
    builder-up)
        require_env
        if [[ ! -f "${DEPLOY_DIR}/config/proposal-builder.json" ]]; then
            echo "Missing config/proposal-builder.json. Run prepare and edit the config first." >&2
            exit 64
        fi
        compose --profile proposal-builder up -d proposal-builder
        ;;
    builder-logs)
        require_env
        compose --profile proposal-builder logs -f proposal-builder
        ;;
    builder-down)
        require_env
        compose --profile proposal-builder stop proposal-builder
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
