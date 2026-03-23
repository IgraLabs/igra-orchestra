#!/bin/sh
#
# Wrap a child command and stop it when a declared dependency disappears.
# Usage: ./watch-dependencies.sh [dependency options] -- command [args...]
#
# Supported dependency types:
#   --tcp, --http, --http-any, --tcp-if, --http-if
#
# Environment knobs:
#   DEPENDENCY_CHECK_INTERVAL_SECONDS
#   DEPENDENCY_TCP_TIMEOUT_SECONDS
#   DEPENDENCY_HTTP_TIMEOUT_SECONDS
#
# Examples:
#   ./watch-dependencies.sh --tcp execution-layer execution-layer 8545 -- /app/kaspad
#   ./watch-dependencies.sh --http-any rpc-backends http://rpc-provider-0:8535/health,http://rpc-provider-1:8535/health -- traefik
#   ./watch-dependencies.sh --help
set -eu

interval="${DEPENDENCY_CHECK_INTERVAL_SECONDS:-5}"
tcp_timeout="${DEPENDENCY_TCP_TIMEOUT_SECONDS:-2}"
http_timeout="${DEPENDENCY_HTTP_TIMEOUT_SECONDS:-2}"
dependencies=""
child_pid=""

log() {
    printf '[watch-dependencies] %s\n' "$*" >&2
}

print_help() {
    script_name="$(basename "$0")"
    cat <<EOF
Usage: ./$script_name [OPTIONS] -- command [args...]

Wrap a child command and stop it when a declared dependency disappears.
The child command only starts after all declared dependencies are ready.

Options:
  --interval <seconds>
      Override the dependency poll interval.

  --tcp <label> <host> <port>
      Require a TCP endpoint.

  --http <label> <url>
      Require a single HTTP endpoint.

  --http-any <label> <url1,url2,...>
      Require at least one healthy HTTP endpoint from a comma-separated list.

  --tcp-if <env_name> <expected_value> <label> <host> <port>
      Add a TCP dependency only when the named environment variable matches.

  --http-if <env_name> <expected_value> <label> <url>
      Add an HTTP dependency only when the named environment variable matches.

  -h, --help
      Show this help and exit.

Environment:
  DEPENDENCY_CHECK_INTERVAL_SECONDS  Poll interval between dependency checks (default: 5)
  DEPENDENCY_TCP_TIMEOUT_SECONDS     TCP probe timeout in seconds (default: 2)
  DEPENDENCY_HTTP_TIMEOUT_SECONDS    HTTP probe timeout in seconds (default: 2)

Examples:
  ./$script_name -- /bin/true

  ./$script_name \\
    --tcp execution-layer execution-layer 8545 \\
    -- /app/kaspad

  ./$script_name \\
    --tcp-if READ_ONLY false kaswallet "\$KASWALLET_HOST" 8082 \\
    -- /app/igra-rpc-provider

  ./$script_name \\
    --http-any rpc-backends \\
    http://rpc-provider-0:8535/health,http://rpc-provider-1:8535/health \\
    -- traefik
EOF
}

usage_error() {
    log "$1"
    printf '[watch-dependencies] run with --help to see usage examples\n' >&2
    exit 2
}

add_dependency() {
    entry="$1|$2|$3|$4"
    if [ -z "$dependencies" ]; then
        dependencies="$entry"
    else
        dependencies="$dependencies
$entry"
    fi
}

normalize_timeout() {
    value="$1"
    fallback="$2"

    case "$value" in
        ''|*[!0-9]*)
            printf '%s' "$fallback"
            ;;
        *)
            if [ "$value" -gt 0 ]; then
                printf '%s' "$value"
            else
                printf '%s' "$fallback"
            fi
            ;;
    esac
}

valid_env_name() {
    case "$1" in
        ''|[0-9]*|*[!A-Za-z0-9_]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

resolve_env() {
    name="$1"
    if ! valid_env_name "$name"; then
        log "invalid environment variable name: $name"
        return 1
    fi
    eval "printf '%s' \"\${$name:-}\""
}

valid_host() {
    case "$1" in
        ''|*[!A-Za-z0-9.-]*)
            return 1
            ;;
        *)
            return 0
            ;;
    esac
}

valid_port() {
    case "$1" in
        ''|*[!0-9]*)
            return 1
            ;;
        *)
            [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
            ;;
    esac
}

check_tcp() {
    host="$1"
    port="$2"

    if ! valid_host "$host" || ! valid_port "$port"; then
        log "invalid tcp target: $host:$port"
        return 1
    fi

    if ! command -v bash > /dev/null 2>&1; then
        log "bash is required for tcp dependency checks"
        return 1
    fi

    bash -lc 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" > /dev/null 2>&1 &
    probe_pid="$!"
    (
        sleep "$tcp_timeout"
        kill -TERM "$probe_pid" 2>/dev/null || true
    ) &
    timeout_pid="$!"

    if wait "$probe_pid"; then
        result=0
    else
        result=$?
    fi

    kill -TERM "$timeout_pid" 2>/dev/null || true
    wait "$timeout_pid" 2>/dev/null || true

    [ "$result" -eq 0 ]
}

check_http() {
    wget --quiet --spider --tries=1 --timeout="$http_timeout" "$1" > /dev/null 2>&1
}

check_http_any() {
    urls="$1"
    old_ifs="$IFS"
    IFS=','
    set -- $urls
    IFS="$old_ifs"

    for url in "$@"; do
        if check_http "$url"; then
            return 0
        fi
    done

    return 1
}

dependencies_ready() {
    if [ -z "$dependencies" ]; then
        return 0
    fi

    old_ifs="$IFS"
    IFS='
'
    for dep in $dependencies; do
        IFS='|'
        set -- $dep
        IFS="$old_ifs"

        type="$1"
        label="$2"
        value1="$3"
        value2="${4:-}"

        case "$type" in
            tcp)
                if ! check_tcp "$value1" "$value2"; then
                    log "$label is unavailable at $value1:$value2"
                    return 1
                fi
                ;;
            http)
                if ! check_http "$value1"; then
                    log "$label is unavailable at $value1"
                    return 1
                fi
                ;;
            http-any)
                if ! check_http_any "$value1"; then
                    log "$label has no healthy endpoints in $value1"
                    return 1
                fi
                ;;
            *)
                log "unknown dependency type: $type"
                return 1
                ;;
        esac
    done
    IFS="$old_ifs"
}

terminate_child() {
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
}

tcp_timeout="$(normalize_timeout "$tcp_timeout" 2)"
http_timeout="$(normalize_timeout "$http_timeout" 2)"

while [ "$#" -gt 0 ]; do
    case "$1" in
        -h|--help)
            print_help
            exit 0
            ;;
        --interval)
            interval="$2"
            shift 2
            ;;
        --tcp)
            add_dependency "tcp" "$2" "$3" "$4"
            shift 4
            ;;
        --http)
            add_dependency "http" "$2" "$3" ""
            shift 3
            ;;
        --http-any)
            add_dependency "http-any" "$2" "$3" ""
            shift 3
            ;;
        --tcp-if)
            resolved_env_value="$(resolve_env "$2")" || exit 2
            if [ "$resolved_env_value" = "$3" ]; then
                add_dependency "tcp" "$4" "$5" "$6"
            fi
            shift 6
            ;;
        --http-if)
            resolved_env_value="$(resolve_env "$2")" || exit 2
            if [ "$resolved_env_value" = "$3" ]; then
                add_dependency "http" "$4" "$5" ""
            fi
            shift 5
            ;;
        --)
            shift
            break
            ;;
        *)
            usage_error "unknown argument: $1"
            ;;
    esac
done

if [ "$#" -eq 0 ]; then
    usage_error "missing command"
fi

command="$1"
shift

trap 'terminate_child; exit 143' INT TERM

until dependencies_ready; do
    sleep "$interval"
done

"$command" "$@" &
child_pid="$!"

while kill -0 "$child_pid" 2>/dev/null; do
    if ! dependencies_ready; then
        terminate_child
        exit 1
    fi
    sleep "$interval"
done

wait "$child_pid"
