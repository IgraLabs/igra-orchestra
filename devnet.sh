#!/bin/bash
set -e

# Function to print help message
print_help() {
  echo "Usage: $0 [--dry-run] [--env (local|stage|prod)] <compose-command> --all|--all-kaspa|<services>"
  echo
  echo "This script is a utility wrapper for Docker Compose that simplifies running, building,"
  echo "and managing IGRA Devnet services in different environments (e.g., local, stage, prod)."
  echo "It supports dynamic service selection and dry-run mode for testing commands."
  echo
  echo "--dry-run           Print only (don't run) docker command"
  echo "--env               Define the environment to run services in:"
  echo "                    (defaults to local if omitted)"
  echo "   local            - devnet with KASPA node and miner on localhost"
  echo "   stage            - devnet on stage server"
  echo "   prod             - devnet on prod server"
  echo
  echo "Compose Commands:"
  echo "  build            Build containers"
  echo "  up -d            Start services in background"
  echo "  down             Stop and remove containers"
  echo "  down -v          Stop and remove containers and volumes"
  echo "  logs             Show logs"
  echo "  logs -f          Follow logs"
  echo "  ps               List running containers"
  echo "  config           Merge and print configs"
  echo "  stats            Report statistics"
  echo
  echo "--all               Same as 'traefik core workers'"
  echo "--all-kaspa         Same as 'kaspa traefik core workers'"
  echo
  echo "Services:           (combination of the following words)"
  echo "  core             Same as 'execution-layer block-builder viaduct'"
  echo "  execution-layer  Select this service only"
  echo "  block-builder    -''-"
  echo "  viaduct          -''-"
  echo "  workers <ids>    Add one or more dynamic workers (e.g. 0 1 2);"
  echo "                   defaults to all (0 1 2 3 4 5) if no ids given"
  echo "  traefik          Add traefik proxy"
  echo "  kaspa            KASPAD and kaspa-miner (e.g. or local env)"
  echo "  kaspa-explorer   Select all KASPA Explorer stack"
  echo "  utils            Yacht (container managing tool)"
  echo
  echo "Example:"
  echo "  $0 --env local up -d traefik core workers 1 2 kaspa-explorer"
}

if [[ "$1" == "--help" || "$1" == "-h" ]]; then
    print_help
    exit 0
fi

panic() {
  echo "❌ ERROR: $@" >&2
  echo >&2
  echo "Try \"$0 --help\"" >&2
  exit 1
}

check_keys() {
  for w in "$@"; do
    k="./keys/keys.kaswallet-${w}.json"
    if [ ! -f "$k" ]; then
      panic "Missing key file: $k"
    fi
  done
}

# ---------- DRY RUN option        ----------

DRY_RUN=
if [ "$1" == "--dry-run" ]; then
  DRY_RUN=Y
  shift
fi

# ---------- Environment           ----------
ENV=local
if [[ -n "$1" && "$1" == "--env" ]]; then
  if [[ -n "$2" && "$2" =~ ^(local|stage|prod)$ ]]; then
     ENV="$2"
     shift 2
  else
     echo panic "Invalid or missing value for --env"
  fi
fi

# ---------- Parse Compose Command ----------
COMPOSE_CMD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all|--all-kaspa|block-builder|core|execution-layer|kaspa|kaspa-explorer|utils|traefik|workers|viaduct)
      break
      ;;
    *)
      COMPOSE_CMD+=("$1")
      shift
      ;;
  esac
done

if [[ "${#COMPOSE_CMD[@]}" -eq 0 ]]; then
  panic "Missing docker compose command"
fi

# Validate supported COMPOSE_CMD
joined_cmd="${COMPOSE_CMD[*]}"
if [[ ! "$joined_cmd" =~ ^(build|up\ -d|down|down\ -v|logs|logs\ -f|ps|config|stats)$ ]]; then
  panic "Invalid docker compose command: '$joined_cmd'"
fi

# ---------- Parse Service Groups ----------

IS_CORE=
IS_TRAEF=
IS_WORKERS=
IS_KASPA=
IS_KEXPL=
IS_UTILS=
SERVICES=

# Check if --all or --all-kaspa is given
if [[ "$1" == "--all" || "$1" == "--all-kaspa" ]]; then
  [ "$1" == "--all-kaspa" ] && IS_KASPA=Y
  shift

  # all services selected
  IS_CORE=Y
  IS_WORKERS=Y
  IS_TRAEF=Y
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    core)
      IS_CORE=Y
      SERVICES+=" execution-layer block-builder viaduct"
      shift
      ;;

    execution-layer|block-builder|viaduct)
      SERVICES+=" $1"
      IS_CORE=Y
      shift
      ;;

    traefik)
      IS_TRAEF=Y
      SERVICES+=" traefik"
      shift
      ;;

    workers)
      shift
      IS_WORKERS=Y
      worker_ids=()
      while [[ $# -gt 0 && "$1" =~ ^(0|1|2|3|4|5)$ ]]; do
        worker_ids+=("$1")
        shift
      done

      # Default to all 6 workers if none were specified
      if [[ ${#worker_ids[@]} -eq 0 ]]; then
        worker_ids=(0 1 2 3 4 5)
      fi

      check_keys "${worker_ids[@]}"

      for w in "${worker_ids[@]}"; do
        SERVICES+=" rpc-provider-${w} kaswallet-${w}"
      done
      ;;

    kaspa)
      shift
      IS_KASPA=Y
      SERVICES+=" kaspad kaspa-miner"
      ;;

    kaspa-explorer)
      shift
      IS_KEXPL=Y
      SERVICES+=" kaspa_explorer simply_kaspa_socket_server kaspa_rest_server simply_kaspa_indexer kaspa_db"
      ;;

    utils)
      shift
      IS_UTILS=Y
      SERVICES+=" yacht"
      ;;

    *)
      panic "Unknown argument: $1"
      ;;
  esac
done

COMPOSE_FILES=
[ -z ${IS_UTILS} ]   || COMPOSE_FILES+=" -f docker-compose.utils.yml"
[ -z ${IS_KASPA} ]   || COMPOSE_FILES+=" -f docker-compose.kaspad.local.yml"
[ -z ${IS_CORE} ]    || COMPOSE_FILES+=" -f docker-compose.core.yml"
[ -z ${IS_TRAEF} ]   || COMPOSE_FILES+=" -f docker-compose.traefik.yml"
[ -z ${IS_WORKERS} ] || COMPOSE_FILES+=" -f docker-compose.rpc-workers.yml"
[ -z ${IS_KEXPL} ]   || COMPOSE_FILES+=" -f docker-compose.kaspa-explorer.yml"
[ -z "${COMPOSE_FILES}" ] && panic "No services selected"


case "${ENV}" in
  local)
    env_file=".env.local"
    ;;
  stage)
    env_file=".env.stage"
    ;;
  prod)
    panic "PROD environment is not yet coded"
    ;;
esac

[ -z "${env_file}" ] && panic "Unknown --env: ${ENV}"

if [[ ! "${DRY_RUN}" == "Y" ]]; then
  echo "Running:"
else
  echo "NOT Running (DRY RUN):"
fi

echo "docker compose --env-file "${env_file}" ${COMPOSE_FILES} ${joined_cmd} ${SERVICES}"
echo

if [[ ! "${DRY_RUN}" == "Y" ]]; then
  docker compose --env-file "${env_file}" ${COMPOSE_FILES} ${joined_cmd} ${SERVICES}
fi
