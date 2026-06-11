#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ENV_FILE:-${DEPLOY_DIR}/.env.safe}"
COMPOSE_FILE="${DEPLOY_DIR}/docker-compose.safe.yml"

usage() {
    cat <<'USAGE'
Usage: ./scripts/safe.sh <command>

Commands:
  prepare      Create local env/config templates and clone/update source repos
  check-env    Validate .env.safe has no placeholders
  config       Validate docker compose config
  build        Build Safe API image with kaspa-pst inside it
  migrate      Run Django migrations once
  up           Start Postgres, Redis, run migrations, then start Safe API
  down         Stop Safe API, Redis, and Postgres
  restart-api  Recreate only Safe API
  logs         Follow Safe API logs
  status       Show containers and local /check/ response

USAGE
}

compose() {
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

check_env() {
    "${DEPLOY_DIR}/scripts/check-env.sh" safe "$ENV_FILE"
}

case "${1:-}" in
    prepare)
        "${DEPLOY_DIR}/scripts/prepare.sh"
        ;;
    check-env)
        check_env
        ;;
    config)
        check_env
        compose config --quiet
        ;;
    build)
        check_env
        compose build safe-api
        ;;
    migrate)
        check_env
        compose --profile migrate run --rm safe-migrate
        ;;
    up)
        check_env
        compose up -d postgres redis
        compose --profile migrate run --rm safe-migrate
        compose up -d safe-api
        ;;
    down)
        compose down
        ;;
    restart-api)
        check_env
        compose up -d --force-recreate safe-api
        ;;
    logs)
        compose logs -f safe-api
        ;;
    status)
        check_env
        compose ps
        set -a
        # shellcheck source=/dev/null
        source "$ENV_FILE"
        set +a
        curl -fsS "http://127.0.0.1:${SAFE_API_PORT:-8888}/check/" || true
        echo
        ;;
    ""|-h|--help|help)
        usage
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac
