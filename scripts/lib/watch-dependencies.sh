#!/bin/sh
#
# Wrap a child command and stop it when a declared dependency stays unavailable.
# Usage: ./watch-dependencies.sh [dependency options] -- command [args...]
#
# Supported dependency types:
#   --tcp, --http, --http-any, --tcp-if, --http-if
#
# Environment knobs:
#   DEPENDENCY_CHECK_INTERVAL_SECONDS
#   DEPENDENCY_TCP_TIMEOUT_SECONDS
#   DEPENDENCY_HTTP_TIMEOUT_SECONDS
#   DEPENDENCY_FAILURE_THRESHOLD
#
# Examples:
#   ./watch-dependencies.sh --tcp execution-layer execution-layer 8545 -- /app/kaspad
#   ./watch-dependencies.sh --http-any rpc-backends http://rpc-provider-0:8535/health,http://rpc-provider-1:8535/health -- traefik
#   ./watch-dependencies.sh --help
set -eu

interval="${DEPENDENCY_CHECK_INTERVAL_SECONDS:-5}"
tcp_timeout="${DEPENDENCY_TCP_TIMEOUT_SECONDS:-2}"
http_timeout="${DEPENDENCY_HTTP_TIMEOUT_SECONDS:-2}"
failure_threshold="${DEPENDENCY_FAILURE_THRESHOLD:-3}"
dependencies=""
child_pid=""

# Background helpers, tracked so the INT/TERM trap can stop and reap them.
probe_pid=""
timer_pid=""
sleep_pid=""

# Scratch file for a probe's stderr, used to classify failures.
scratch_file=""
probe_err=/dev/null

# Set by dependencies_ready on failure: a stable reason, and timing detail for this check only.
failure_reason=""
failure_note=""

# Exit status the probe timer uses to report that it fired.
timer_fired_status=10
# While waiting to start the child, repeat the failure reason every this many failed checks.
startup_reminder_checks=60
# A TCP probe ending this long after its deadline means the watcher itself was not scheduled on time.
scheduling_slack_ms=500

log() {
    printf '[watch-dependencies] %s\n' "$*" >&2
}

print_help() {
    script_name="$(basename "$0")"
    cat <<EOF
Usage: ./$script_name [OPTIONS] -- command [args...]

Wrap a child command and stop it when a declared dependency stays unavailable.
The child command only starts after all declared dependencies are ready.
Once it runs, a failed check is logged and retried; the child is stopped only
after DEPENDENCY_FAILURE_THRESHOLD consecutive failed checks of the whole
dependency set. TCP checks only open a connection; HTTP checks only request
the URL.

Options:
  --interval <seconds>
      Override the dependency poll interval (whole seconds).

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

Environment (whole seconds or counts; invalid values fall back to the default):
  DEPENDENCY_CHECK_INTERVAL_SECONDS  Poll interval between dependency checks (default: 5)
  DEPENDENCY_TCP_TIMEOUT_SECONDS     TCP probe timeout in seconds (default: 2)
  DEPENDENCY_HTTP_TIMEOUT_SECONDS    HTTP probe timeout in seconds (default: 2)
  DEPENDENCY_FAILURE_THRESHOLD       Consecutive failed checks before the running
                                     child is stopped (default: 3; 1 stops on the
                                     first failed check)

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

# Print $2 as a positive whole number of at most six digits, or the default $3.
# A non-empty invalid value is reported once under the setting name $1.
normalize_positive_int() {
    name="$1"
    value="$2"
    fallback="$3"

    # Strip leading zeros: shell arithmetic would read them as octal.
    value="${value#"${value%%[!0]*}"}"
    case "$value" in
        ''|*[!0-9]*)
            ;;
        *)
            if [ "${#value}" -le 6 ]; then
                printf '%s' "$value"
                return 0
            fi
            ;;
    esac

    if [ -n "$2" ]; then
        log "ignoring invalid $name=$2; using $fallback"
    fi
    printf '%s' "$fallback"
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

# Set uptime_value to milliseconds since boot, read from /proc/uptime without
# forking; empty where /proc/uptime is unavailable.
read_uptime_ms() {
    uptime_value=""
    { read -r uptime_value _ < /proc/uptime; } 2>/dev/null || true
    case "$uptime_value" in
        *.[0-9][0-9])
            uptime_value="${uptime_value%.*}${uptime_value#*.}0"
            uptime_value="${uptime_value#"${uptime_value%%[!0]*}"}"
            ;;
        *)
            uptime_value=""
            ;;
    esac
}

# Set error_line to the first line the last probe wrote to stderr.
read_probe_error() {
    error_line=""
    { IFS= read -r error_line < "$probe_err"; } 2>/dev/null || true
}

# Set failure_note when a check started at $1 (ms) took well over its $2-second
# timeout. TCP probes are killed at their deadline, so overrunning it means the
# watcher was not scheduled on time; an HTTP check can also be slowed by DNS.
note_slow_check() {
    started_ms="$1"
    timeout_s="$2"
    kind="$3"

    read_uptime_ms
    if [ -z "$started_ms" ] || [ -z "$uptime_value" ]; then
        return 0
    fi
    elapsed_ms=$((uptime_value - started_ms))
    if [ "$elapsed_ms" -le $((timeout_s * 1000 + scheduling_slack_ms)) ]; then
        return 0
    fi
    if [ "$kind" = tcp ]; then
        failure_note="; took ${elapsed_ms}ms against a ${timeout_s}s deadline, watcher was delayed"
    else
        failure_note="; took ${elapsed_ms}ms with a ${timeout_s}s timeout"
    fi
}

# SIGTERM process $1 after $2 seconds, in the background. The timer exits with
# timer_fired_status only when it fired; a cancelled timer stops its own sleep.
# Its sleep is stopped with SIGKILL: a forked child that has not exec'd sleep yet
# still runs the shell's handler and would swallow SIGTERM.
start_probe_timer() {
    target_pid="$1"
    seconds="$2"
    (
        cancelled=""
        timer_sleep_pid=""
        trap 'cancelled=1; if [ -n "$timer_sleep_pid" ]; then kill -KILL "$timer_sleep_pid" 2>/dev/null || true; fi' TERM
        # A cancel sent before the trap existed is lost, but the probe is reaped by then.
        if ! kill -0 "$target_pid" 2>/dev/null; then
            exit 0
        fi
        sleep "$seconds" &
        timer_sleep_pid="$!"
        if [ -z "$cancelled" ] && wait "$timer_sleep_pid"; then
            kill -TERM "$target_pid" 2>/dev/null || true
            exit "$timer_fired_status"
        fi
        kill -KILL "$timer_sleep_pid" 2>/dev/null || true
        exit 0
    ) &
    timer_pid="$!"
}

# Wait for the running probe and set probe_status. Redirecting wait's stderr
# hides the shell's "Terminated" notice for a killed probe.
wait_probe() {
    if wait "$probe_pid" 2>/dev/null; then
        probe_status=0
    else
        probe_status=$?
    fi
    probe_pid=""
}

# Cancel the probe timer and set timer_status (timer_fired_status if it fired).
cancel_probe_timer() {
    kill -TERM "$timer_pid" 2>/dev/null || true
    if wait "$timer_pid" 2>/dev/null; then
        timer_status=0
    else
        timer_status=$?
    fi
    timer_pid=""
}

classify_tcp_failure() {
    if [ "$timer_status" -eq "$timer_fired_status" ]; then
        tcp_failure="no tcp connect within ${tcp_timeout}s"
        return 0
    fi

    read_probe_error
    case "$error_line" in
        *"name resolution"*|*"not known"*)
            tcp_failure="name resolution failed"
            ;;
        *"Connection refused"*)
            tcp_failure="tcp connect refused"
            ;;
        '')
            if [ "$probe_status" -gt 128 ]; then
                tcp_failure="tcp probe killed by signal $((probe_status - 128))"
            else
                tcp_failure="tcp connect failed (exit $probe_status)"
            fi
            ;;
        *)
            tcp_failure="tcp connect failed: ${error_line##*: }"
            ;;
    esac
}

check_tcp() {
    host="$1"
    port="$2"
    failure_note=""

    if ! valid_host "$host" || ! valid_port "$port"; then
        tcp_failure="invalid tcp target"
        return 1
    fi

    if ! command -v bash > /dev/null 2>&1; then
        tcp_failure="bash is required for tcp dependency checks"
        return 1
    fi

    read_uptime_ms
    check_started_ms="$uptime_value"
    bash -c 'exec 3<>"/dev/tcp/$1/$2"' _ "$host" "$port" > /dev/null 2> "$probe_err" &
    probe_pid="$!"
    start_probe_timer "$probe_pid" "$tcp_timeout"
    wait_probe
    cancel_probe_timer

    if [ "$probe_status" -eq 0 ]; then
        return 0
    fi

    classify_tcp_failure
    note_slow_check "$check_started_ms" "$tcp_timeout" tcp
    return 1
}

classify_http_failure() {
    read_probe_error
    case "$error_line" in
        *"bad address"*|*"name resolution"*|*"not known"*|*"unable to resolve"*)
            http_failure="name resolution failed"
            ;;
        *"Connection refused"*)
            http_failure="http connect refused"
            ;;
        *"timed out"*)
            http_failure="http request timed out"
            ;;
        *"server returned error"*)
            http_failure="http error ${error_line##*: }"
            ;;
        '')
            # GNU wget --quiet prints nothing; its exit status is all there is.
            http_failure="wget exit $probe_status"
            ;;
        *)
            http_failure="http check failed: ${error_line#wget: }"
            ;;
    esac
}

check_http() {
    url="$1"
    failure_note=""

    read_uptime_ms
    check_started_ms="$uptime_value"
    # In the background so INT/TERM does not wait for wget to finish.
    wget --quiet --spider --tries=1 --timeout="$http_timeout" "$url" > /dev/null 2> "$probe_err" &
    probe_pid="$!"
    wait_probe

    if [ "$probe_status" -eq 0 ]; then
        return 0
    fi

    classify_http_failure
    note_slow_check "$check_started_ms" "$http_timeout" http
    return 1
}

# Succeed when any URL is healthy. On failure, report the first URL's reason:
# the list starts with the configured workers, later entries may not exist.
check_http_any() {
    urls="$1"
    old_ifs="$IFS"
    IFS=','
    set -- $urls
    IFS="$old_ifs"

    first_failure=""
    first_note=""
    for url in "$@"; do
        if check_http "$url"; then
            return 0
        fi
        if [ -z "$first_failure" ]; then
            first_failure="$url: $http_failure"
            first_note="$failure_note"
        fi
    done

    http_failure="$# checked, first $first_failure"
    failure_note="$first_note"
    return 1
}

# Check every declared dependency in order. On the first failure set
# failure_reason and failure_note, and return 1.
dependencies_ready() {
    failure_reason=""
    failure_note=""
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
                    failure_reason="$label is unavailable at $value1:$value2 ($tcp_failure)"
                    return 1
                fi
                ;;
            http)
                if ! check_http "$value1"; then
                    failure_reason="$label is unavailable at $value1 ($http_failure)"
                    return 1
                fi
                ;;
            http-any)
                if ! check_http_any "$value1"; then
                    failure_reason="$label has no healthy endpoints ($http_failure)"
                    return 1
                fi
                ;;
            *)
                failure_reason="unknown dependency type: $type"
                return 1
                ;;
        esac
    done
    IFS="$old_ifs"
}

# Set pressure to the host's PSI "some avg10" values, where the kernel exposes them.
read_pressure() {
    pressure=""
    for resource in cpu memory io; do
        psi_line=""
        { read -r psi_line < "/proc/pressure/$resource"; } 2>/dev/null || continue
        psi_avg10="${psi_line#some avg10=}"
        pressure="$pressure $resource=${psi_avg10%% *}"
    done
    if [ -n "$pressure" ]; then
        pressure="; host pressure avg10:$pressure"
    fi
}

# Log the current failure with $1 appended, plus host pressure for correlation.
log_failure() {
    read_pressure
    log "$failure_reason$failure_note; $1$pressure"
}

# Sleep between checks in the background so INT/TERM interrupts it at once.
poll_sleep() {
    sleep "$interval" &
    sleep_pid="$!"
    wait "$sleep_pid" || true
    sleep_pid=""
}

# Stop the in-flight probe, poll sleep and probe timer. Probes and sleeps need
# no cleanup, and SIGKILL also stops a child that has not exec'd yet; the timer
# gets SIGTERM so it can stop its own sleep.
stop_helpers() {
    for helper_pid in $probe_pid $sleep_pid; do
        kill -KILL "$helper_pid" 2>/dev/null || true
        wait "$helper_pid" 2>/dev/null || true
    done
    if [ -n "$timer_pid" ]; then
        kill -TERM "$timer_pid" 2>/dev/null || true
        wait "$timer_pid" 2>/dev/null || true
    fi
}

terminate_child() {
    if [ -n "$child_pid" ] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
        wait "$child_pid" 2>/dev/null || true
    fi
}

cleanup_scratch() {
    if [ -n "$scratch_file" ]; then
        rm -f "$scratch_file"
    fi
}

# Block until every dependency is ready. Logs the first failure, any change of
# reason, and a reminder every startup_reminder_checks failed checks.
wait_for_dependencies() {
    startup_failures=0
    last_reason=""
    until dependencies_ready; do
        startup_failures=$((startup_failures + 1))
        if [ "$startup_failures" -eq 1 ] || [ "$failure_reason" != "$last_reason" ]; then
            log "$failure_reason$failure_note; waiting before starting $command"
        elif [ $((startup_failures % startup_reminder_checks)) -eq 0 ]; then
            log "still waiting: $failure_reason ($startup_failures failed checks)"
        fi
        last_reason="$failure_reason"
        poll_sleep
    done
}

# Re-check dependencies while the child runs. A single failed check is not an
# outage: under host pressure the probe itself can overrun its timeout. Only
# failure_threshold consecutive failed checks of the whole dependency set stop
# the child; one fully successful check resets the count.
watch_child() {
    failed_checks=0
    last_reason=""
    while kill -0 "$child_pid" 2>/dev/null; do
        if dependencies_ready; then
            if [ "$failed_checks" -gt 0 ]; then
                log "dependencies ready again after $failed_checks failed check(s)"
            fi
            failed_checks=0
            last_reason=""
        else
            failed_checks=$((failed_checks + 1))
            if [ "$failed_checks" -ge "$failure_threshold" ]; then
                log_failure "check $failed_checks/$failure_threshold failed, stopping $command"
                terminate_child
                exit 1
            fi
            if [ "$failed_checks" -eq 1 ] || [ "$failure_reason" != "$last_reason" ]; then
                log_failure "check $failed_checks/$failure_threshold failed, retrying"
            fi
            last_reason="$failure_reason"
        fi
        poll_sleep
    done
}

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

interval="$(normalize_positive_int "check interval" "$interval" 5)"
tcp_timeout="$(normalize_positive_int DEPENDENCY_TCP_TIMEOUT_SECONDS "$tcp_timeout" 2)"
http_timeout="$(normalize_positive_int DEPENDENCY_HTTP_TIMEOUT_SECONDS "$http_timeout" 2)"
failure_threshold="$(normalize_positive_int DEPENDENCY_FAILURE_THRESHOLD "$failure_threshold" 3)"

trap cleanup_scratch EXIT
trap 'stop_helpers; terminate_child; exit 143' INT TERM

if scratch_file="$(mktemp 2>/dev/null)"; then
    probe_err="$scratch_file"
else
    scratch_file=""
    log "cannot create a scratch file; failure reasons will be less specific"
fi

log "watching dependencies for $command: check every ${interval}s, tcp timeout ${tcp_timeout}s," \
    "http timeout ${http_timeout}s, stop after $failure_threshold consecutive failed checks"

wait_for_dependencies

log "dependencies ready; starting $command"
"$command" "$@" &
child_pid="$!"

watch_child

wait "$child_pid"
