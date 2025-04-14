#!/bin/bash
set -e

print_help() {
  echo "Usage: $0 [--dry-run] <compose-command> --all|<services>"
  echo
  echo "--dry-run           Print only (don't run) docker command"
  echo "--all               Same as 'traefik core workers kaspa-explorer'"
  echo
  echo "Compose Commands:"
  echo "  up -d            Start services in background"
  echo "  down             Stop and remove containers"
  echo "  down -v          Stop and remove containers and volumes"
  echo "  logs             Show logs"
  echo "  logs -f          Follow logs"
  echo "  ps               List running containers"
  echo "  stats            Report statistics"
  echo "  build            Build containers"
  echo
  echo "Service:           (combination of the following words)"
  echo "  core             Same as 'execution-layer block-builder viaduct'"
  echo "  execution-layer  Selects this service only"
  echo "  block-builder    -''-"
  echo "  viaduct          -''-"
  echo "  workers <ids>    Adds one or more dynamic workers (e.g. 0 1 2);"
  echo "                   defaults to all (0 1 2 3 4 5) if no ids given"
  echo "  traefik          Adds traefik proxy"
  echo "  kaspa-explorer   Selects all KASPA Explorer stack"
  echo
  echo "Example:"
  echo "  $0 up -d traefik core workers 1 2 kaspa-explorer"
}

panic() {
  echo "❌ ERROR: $@" >&2
  echo >&2
  print_help >&2
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

# ---------- Parse Compose Command ----------

COMPOSE_CMD=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --all|core|traefik|workers|kaspa-explorer|execution-layer|block-builder|viaduct)
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
if [[ ! "$joined_cmd" =~ ^(up\ -d|down|down\ -v|logs|logs\ -f|ps|build|stats)$ ]]; then
  panic "Invalid docker compose command: '$joined_cmd'"
fi

# ---------- Parse Service Groups ----------

IS_CORE=
IS_TRAEF=
IS_WORKERS=
IS_KEXPL=
SERVICES=

# Check if --all is given
if [ "$1" == "--all" ]; then
  shift
  if [[ $# -gt 0 ]]; then
    panic "no params expected after --all"
  fi

  # all services selected
  IS_CORE=Y
  IS_TRAEF=Y
  IS_WORKERS=Y
  IS_KEXPL=Y
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    core)
      IS_CORE=Y
      shift
      ;;

    execution-layer|block-builder|viaduct)
      SERVICES+=" $1"
      IS_CORE=Y
      shift
      ;;

    traefik)
      IS_TRAEF=Y
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

    kaspa-explorer)
      shift
      IS_KEXPL=Y
      ;;

    *)
      panic "Unknown argument: $1"
      ;;
  esac
done

COMPOSE_FILES=
[ -z ${IS_CORE} ]    || COMPOSE_FILES+=" -f docker-compose.core.yml"
[ -z ${IS_TRAEF} ]   || COMPOSE_FILES+=" -f docker-compose.traefik.yml"
[ -z ${IS_WORKERS} ] || COMPOSE_FILES+=" -f docker-compose.rpc-workers.yml"
[ -z ${IS_KEXPL} ]   || COMPOSE_FILES+=" -f docker-compose.kaspa-explorer.yml"
[ -z "${COMPOSE_FILES}" ] && panic "No services selected"

echo "Running:"
echo "docker compose ${COMPOSE_FILES} ${joined_cmd} ${SERVICES}"
echo

if [ -z "${DRY_RUN}" ]; then
  docker compose ${COMPOSE_FILES} ${joined_cmd} ${SERVICES}
fi
