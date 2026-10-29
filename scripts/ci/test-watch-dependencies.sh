#!/usr/bin/env bash
#
# Lifecycle tests for scripts/lib/watch-dependencies.sh: startup gating, the
# consecutive-failure policy, failure reasons, signal handling and cleanup of
# every process the watcher starts.
#
# Usage: scripts/ci/test-watch-dependencies.sh [path/to/watch-dependencies.sh]
#   WATCH_SHELL  shell that runs the watcher: "sh" (default) or "busybox sh".
#                With busybox, wget also resolves to the busybox applet, as in
#                the traefik image.
# Needs bash, python3, setsid (util-linux), wget and a Linux /proc.
set -euo pipefail

watch_arg="${1:-scripts/lib/watch-dependencies.sh}"
watch="$(cd "$(dirname "$watch_arg")" && pwd)/$(basename "$watch_arg")"
read -r -a watch_shell <<< "${WATCH_SHELL:-sh}"
real_bash="$(command -v bash)"

work="$(mktemp -d)"
bin="$work/bin"
mkdir -p "$bin" "$work/www"
: > "$work/www/health"

case_dir=""
watcher_pid=""
watcher_rc=""
probe_target=0
background_pids=()
child_cmd=(-- python3 "$work/child.py")

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    if [ -n "$case_dir" ] && [ -f "$case_dir/log" ]; then
        printf -- '--- watcher log (%s) ---\n' "$case_dir" >&2
        cat "$case_dir/log" >&2
    fi
    exit 1
}

pass() {
    printf 'ok: %s\n' "$1"
}

# List "pid args" for every live process in session $1.
session_processes() {
    python3 "$work/session.py" "$1"
}

cleanup() {
    local pid
    if [ -n "$watcher_pid" ]; then
        session_processes "$watcher_pid" | while read -r pid _; do kill -9 "$pid" 2>/dev/null || true; done
    fi
    for pid in "${background_pids[@]}"; do
        kill "$pid" 2>/dev/null || true
    done
    rm -rf "$work"
}
trap cleanup EXIT

# Run "$@" every 0.1 s until it succeeds, for at most $1 seconds.
eventually() {
    local deadline=$((SECONDS + $1))
    shift
    until "$@"; do
        if [ "$SECONDS" -ge "$deadline" ]; then
            return 1
        fi
        sleep 0.1
    done
}

free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'
}

port_open() {
    python3 -c 'import socket, sys; socket.create_connection(("127.0.0.1", int(sys.argv[1])), 1)' "$1" 2>/dev/null
}

# Accept connections on port $1; the pid is stored under name $2.
start_listener() {
    python3 "$work/listen.py" "$1" &
    echo "$!" > "$work/listener.$2"
    background_pids+=("$!")
    eventually 5 port_open "$1" || fail "listener on port $1 did not start"
}

# Accept connections on port $1 and never answer; the pid is stored under name $2.
start_hold_listener() {
    python3 "$work/hold.py" "$1" &
    echo "$!" > "$work/listener.$2"
    background_pids+=("$!")
    eventually 5 port_open "$1" || fail "hold listener on port $1 did not start"
}

start_http_server() {
    python3 -m http.server --bind 127.0.0.1 --directory "$work/www" "$1" > /dev/null 2>&1 &
    echo "$!" > "$work/listener.$2"
    background_pids+=("$!")
    eventually 5 port_open "$1" || fail "http server on port $1 did not start"
}

stop_listener() {
    local pid
    pid="$(cat "$work/listener.$1")"
    kill "$pid"
    wait "$pid" 2>/dev/null || true
}

# Start the watcher in its own session, in case directory $1. Arguments up to
# "--" are extra environment assignments; the rest are watcher arguments.
# Refused ports and the local servers answer at once, so the 5 s default probe
# timeouts only matter on a loaded runner, where they keep reasons stable.
run_watch() {
    case_dir="$work/$1"
    shift
    mkdir -p "$case_dir"
    : > "$case_dir/probes"
    local env_args=()
    while [ "$1" != "--" ]; do
        env_args+=("$1")
        shift
    done
    shift
    (
        cd "$case_dir"
        exec env PATH="$bin:$PATH" REAL_BASH="$real_bash" TMPDIR="$case_dir" \
            PROBE_MODE_FILE="$case_dir/mode" PROBE_LOG="$case_dir/probes" CHILD_DIR="$case_dir" \
            DEPENDENCY_CHECK_INTERVAL_SECONDS=1 DEPENDENCY_TCP_TIMEOUT_SECONDS=5 \
            DEPENDENCY_HTTP_TIMEOUT_SECONDS=5 "${env_args[@]}" \
            setsid "${watch_shell[@]}" "$watch" "$@"
    ) 2> "$case_dir/log" &
    watcher_pid="$!"
}

child_started() {
    [ -s "$case_dir/started" ]
}

watcher_exited() {
    ! kill -0 "$watcher_pid" 2>/dev/null
}

# Wait up to $1 seconds for the watcher to exit; sets watcher_rc.
wait_watcher_exit() {
    eventually "$1" watcher_exited || fail "watcher still running after $1s"
    watcher_rc=0
    wait "$watcher_pid" || watcher_rc=$?
}

# Completed probes that failed (nonzero status) or passed (zero).
failed_probes() {
    grep -cv '^0$' "$case_dir/probes" || true
}

passed_probes() {
    grep -cx '0' "$case_dir/probes" || true
}

failed_probes_reached() {
    [ "$(failed_probes)" -ge "$probe_target" ] || watcher_exited
}

passed_probes_reached() {
    [ "$(passed_probes)" -ge "$probe_target" ]
}

# Wait until $1 more probes failed, or the watcher exited.
wait_failed_probes() {
    probe_target=$(($(failed_probes) + $1))
    eventually 15 failed_probes_reached || fail "expected $1 more failed checks"
}

wait_passed_probe() {
    probe_target=$(($(passed_probes) + 1))
    eventually 15 passed_probes_reached || fail "expected a successful check"
}

session_empty() {
    [ -z "$(session_processes "$watcher_pid")" ]
}

probe_hanging() {
    session_processes "$watcher_pid" | grep -q ' sleep 30$'
}

http_probe_hanging() {
    session_processes "$watcher_pid" | grep -q ' wget '
}

log_has() {
    grep -qF -- "$1" "$case_dir/log"
}

assert_log() {
    grep -qF -- "$1" "$case_dir/log" || fail "log lacks: $1"
}

assert_log_count() {
    local count
    count="$(grep -cF -- "$2" "$case_dir/log" || true)"
    [ "$count" -eq "$1" ] || fail "expected $1 log line(s) with '$2', found $count: $3"
}

# Child $1 must still run, unsignalled; it should have survived $2.
# Some log line contains both $1 and $2.
assert_log_line() {
    grep -F -- "$1" "$case_dir/log" | grep -qF -- "$2" || fail "no log line with both '$1' and '$2'"
}

# Within a failure streak, a "retrying" line after the first must carry a new reason.
# Reasons can legitimately differ: on a loaded host a refused port can miss its deadline.
assert_no_repeated_reason() {
    awk '
        /dependencies ready again/ { prev = "" }
        /failed, retrying/ {
            reason = $0
            sub(/; check [0-9]+\/[0-9]+ failed.*/, "", reason)
            if ($0 !~ /check 1\//) {
                if (reason == prev) { print "repeated: " $0; bad = 1 }
            }
            prev = reason
        }
        END { exit bad }
    ' "$case_dir/log" || fail "a repeated failure with the same reason was logged"
}

assert_child_alive() {
    kill -0 "$1" 2>/dev/null || fail "child was stopped; it should survive $2"
    [ ! -e "$case_dir/term" ] || fail "child was sent SIGTERM; it should survive $2"
}

# Once the watcher has exited, nothing it started may survive it.
assert_no_leftovers() {
    eventually 3 session_empty ||
        fail "processes left in the watcher session: $(session_processes "$watcher_pid" | tr '\n' ';')"
    if compgen -G "$case_dir/tmp.*" > /dev/null; then
        fail "scratch file left behind"
    fi
}

write_fixtures() {
    cat > "$work/session.py" <<'EOF'
import os, sys
sid = int(sys.argv[1])
for entry in os.listdir("/proc"):
    if not entry.isdigit():
        continue
    try:
        with open(f"/proc/{entry}/stat") as f:
            stat = f.read()
        with open(f"/proc/{entry}/cmdline", "rb") as f:
            args = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
    except OSError:
        continue
    fields = stat[stat.rindex(")") + 2:].split()
    if int(fields[3]) == sid and fields[0] != "Z":
        print(entry, args)
EOF

    cat > "$work/hold.py" <<'EOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(64)
held = []
while True:
    held.append(s.accept()[0])
EOF

    cat > "$work/listen.py" <<'EOF'
import socket, sys
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1])))
s.listen(64)
while True:
    s.accept()[0].close()
EOF

    # The child records its pid and any SIGTERM, and starts no processes of its own.
    cat > "$work/child.py" <<'EOF'
import os, signal, sys, time
d = os.environ["CHILD_DIR"]
def on_term(*_):
    open(os.path.join(d, "term"), "w").close()
    sys.exit(0)
signal.signal(signal.SIGTERM, on_term)
with open(os.path.join(d, "started"), "w") as f:
    f.write(str(os.getpid()))
exit_after = float(os.environ.get("CHILD_EXIT_AFTER", "0"))
if exit_after:
    time.sleep(exit_after)
    sys.exit(int(os.environ.get("CHILD_EXIT_CODE", "0")))
while True:
    time.sleep(60)
EOF

    # Stands in for bash as the TCP probe: "hang" never connects, "slow" connects
    # late, otherwise the real bash probe runs. Completed probes are recorded.
    cat > "$bin/bash" <<'EOF'
#!/bin/sh
case "$(cat "$PROBE_MODE_FILE" 2>/dev/null)" in
    hang) exec sleep 30 ;;
    slow) sleep 0.5 ;;
esac
"$REAL_BASH" "$@"
rc=$?
echo "$rc" >> "$PROBE_LOG"
exit "$rc"
EOF
    chmod +x "$bin/bash"

    if [ "${watch_shell[0]}" = busybox ]; then
        ln -s "$(command -v busybox)" "$bin/wget"
    fi
}

# The ENG-1283 regression: failed checks that recover keep the child running,
# the count restarts after a success, and only a sustained outage stops it.
test_transient_failures_keep_child_running() {
    local port child_pid
    port="$(free_port)"
    run_watch transient -- --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"

    wait_failed_probes 4
    if child_started; then
        fail "child started before its dependency was ready"
    fi

    start_listener "$port" dep
    eventually 10 child_started || fail "child did not start once the dependency was ready"
    child_pid="$(cat "$case_dir/started")"

    stop_listener dep
    wait_failed_probes 2
    assert_child_alive "$child_pid" "2 failed checks"
    start_listener "$port" dep
    wait_passed_probe
    # The probe records its success before the watcher logs the recovery.
    eventually 5 log_has "dependencies ready again after 2 failed check(s)" ||
        fail "log lacks: dependencies ready again after 2 failed check(s)"
    assert_child_alive "$child_pid" "2 failed checks and a success"

    stop_listener dep
    wait_failed_probes 2
    assert_child_alive "$child_pid" "2 more failed checks after a success reset the count"
    start_listener "$port" dep
    wait_passed_probe

    stop_listener dep
    wait_watcher_exit 15
    [ "$watcher_rc" -eq 1 ] || fail "sustained outage: expected exit 1, got $watcher_rc"
    [ -e "$case_dir/term" ] || fail "sustained outage: child was not sent SIGTERM"
    assert_log_line "dep is unavailable at 127.0.0.1:$port (" "check 3/3 failed, stopping python3"
    assert_log_count 3 "check 1/3 failed, retrying" "each failure streak logs its first failure once"
    assert_no_repeated_reason
    [ "$(grep -c 'waiting before starting' "$case_dir/log")" -le 2 ] ||
        fail "the startup wait must log its reason once, not on every failed check"
    assert_no_leftovers
    pass "transient failures keep the child running; a sustained outage stops it"
}

test_settings() {
    local port started
    port="$(free_port)"
    start_listener "$port" settings

    run_watch threshold-one DEPENDENCY_FAILURE_THRESHOLD=1 -- --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"
    eventually 10 child_started || fail "child did not start"
    stop_listener settings
    wait_watcher_exit 10
    [ "$watcher_rc" -eq 1 ] || fail "threshold 1: expected exit 1, got $watcher_rc"
    assert_log "check 1/1 failed, stopping"
    assert_no_leftovers

    start_listener "$port" settings
    run_watch invalid-settings DEPENDENCY_FAILURE_THRESHOLD=bogus DEPENDENCY_CHECK_INTERVAL_SECONDS=abc -- \
        --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"
    eventually 10 child_started || fail "child did not start with invalid settings"
    assert_log "ignoring invalid DEPENDENCY_FAILURE_THRESHOLD=bogus; using 3"
    assert_log "ignoring invalid check interval=abc; using 5"
    assert_log "check every 5s"
    assert_log "stop after 3 consecutive failed checks"

    # SIGTERM between checks must not wait out the 5 s poll interval.
    sleep 0.5
    started=$SECONDS
    kill -TERM "$watcher_pid"
    wait_watcher_exit 3
    [ "$watcher_rc" -eq 143 ] || fail "SIGTERM: expected exit 143, got $watcher_rc"
    [ $((SECONDS - started)) -le 2 ] || fail "SIGTERM took $((SECONDS - started))s to stop the watcher"
    [ -e "$case_dir/term" ] || fail "SIGTERM was not passed to the child"
    assert_no_leftovers
    stop_listener settings
    pass "threshold 1, invalid settings, SIGTERM between checks"
}

# Failures of different dependencies in consecutive checks add up: the count
# covers the whole set, so per-dependency counters would never reach 3 here.
test_dependency_set_shares_one_count() {
    local port_a port_b
    port_a="$(free_port)"
    port_b="$(free_port)"
    start_listener "$port_a" a
    start_listener "$port_b" b
    run_watch two-deps -- --tcp depa 127.0.0.1 "$port_a" --tcp depb 127.0.0.1 "$port_b" "${child_cmd[@]}"
    eventually 10 child_started || fail "child did not start"

    stop_listener b
    wait_failed_probes 1
    # Take depa down before bringing depb back, so no check in between can pass.
    stop_listener a
    start_listener "$port_b" b
    wait_failed_probes 1
    stop_listener b
    start_listener "$port_a" a
    wait_watcher_exit 15
    [ "$watcher_rc" -eq 1 ] || fail "expected exit 1, got $watcher_rc"
    assert_log_line "depb is unavailable at 127.0.0.1:$port_b (" "check 1/3 failed, retrying"
    assert_log_line "depa is unavailable at 127.0.0.1:$port_a (" "check 2/3 failed, retrying"
    assert_log "check 3/3 failed, stopping"
    assert_no_leftovers
    stop_listener a
    pass "failures of different dependencies count together; a changed reason is logged"
}

test_http_any_counts_one_round() {
    local closed_port port
    closed_port="$(free_port)"
    port="$(free_port)"
    start_http_server "$port" http
    run_watch http-any DEPENDENCY_FAILURE_THRESHOLD=2 -- \
        --http-any backends "http://127.0.0.1:$closed_port/health,http://127.0.0.1:$port/health" "${child_cmd[@]}"
    eventually 10 child_started || fail "child did not start while one endpoint was healthy"

    stop_listener http
    wait_watcher_exit 15
    [ "$watcher_rc" -eq 1 ] || fail "expected exit 1, got $watcher_rc"
    assert_log "backends has no healthy endpoints (2 checked, first http://127.0.0.1:$closed_port/health: "
    if [ "${watch_shell[0]}" = busybox ]; then
        # BusyBox wget, as in traefik, names the failure; GNU wget --quiet prints nothing.
        assert_log "first http://127.0.0.1:$closed_port/health: http connect refused)"
    fi
    assert_log_count 1 "check 1/2 failed, retrying" "all endpoints failing is one failed check"
    assert_log "check 2/2 failed, stopping"
    assert_no_leftovers
    pass "--http-any: one healthy endpoint is enough; all failing is one failed check"
}

test_slow_and_hung_probes() {
    local port child_pid
    port="$(free_port)"
    start_listener "$port" slow
    run_watch slow-probe DEPENDENCY_TCP_TIMEOUT_SECONDS=2 -- --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"
    echo slow > "$case_dir/mode"
    eventually 10 child_started || fail "child did not start"
    child_pid="$(cat "$case_dir/started")"
    wait_passed_probe
    wait_passed_probe
    assert_log_count 0 "failed, retrying" "a probe that connects within its timeout is not a failure"

    echo hang > "$case_dir/mode"
    eventually 10 grep -qF "dep is unavailable at 127.0.0.1:$port (no tcp connect within 2s)" "$case_dir/log" ||
        fail "a hung probe must be reported as a missed deadline"
    assert_child_alive "$child_pid" "one missed deadline"

    # SIGTERM while a probe hangs: the probe and its timer must go too.
    eventually 5 probe_hanging || fail "expected a hung probe in flight"
    kill -TERM "$watcher_pid"
    wait_watcher_exit 3
    [ "$watcher_rc" -eq 143 ] || fail "SIGTERM during a probe: expected exit 143, got $watcher_rc"
    [ -e "$case_dir/term" ] || fail "SIGTERM during a probe was not passed to the child"
    assert_no_leftovers
    stop_listener slow
    pass "slow probes pass; hung probes miss the deadline and are cleaned up on SIGTERM"
}

test_name_resolution_failure_before_start() {
    run_watch dns -- --tcp dns nonexistent.invalid 80 "${child_cmd[@]}"
    eventually 10 grep -qF "dns is unavailable at nonexistent.invalid:80 (name resolution failed); waiting before starting" \
        "$case_dir/log" || fail "an unknown host must be reported as a name resolution failure"
    kill -TERM "$watcher_pid"
    wait_watcher_exit 5
    [ "$watcher_rc" -eq 143 ] || fail "SIGTERM before start: expected exit 143, got $watcher_rc"
    if child_started; then
        fail "child started without its dependency"
    fi
    assert_no_leftovers
    pass "name resolution failures are reported; SIGTERM before start"
}

test_sigterm_during_http_probe() {
    local port child_pid
    port="$(free_port)"
    start_http_server "$port" hold
    run_watch http-hang DEPENDENCY_HTTP_TIMEOUT_SECONDS=30 -- --http backend "http://127.0.0.1:$port/health" "${child_cmd[@]}"
    eventually 10 child_started || fail "child did not start"
    child_pid="$(cat "$case_dir/started")"

    stop_listener hold
    start_hold_listener "$port" hold
    eventually 10 http_probe_hanging || fail "expected a hung wget in flight"
    kill -TERM "$watcher_pid"
    wait_watcher_exit 3
    [ "$watcher_rc" -eq 143 ] || fail "SIGTERM during an HTTP probe: expected exit 143, got $watcher_rc"
    [ -e "$case_dir/term" ] || fail "SIGTERM during an HTTP probe was not passed to the child"
    if kill -0 "$child_pid" 2>/dev/null; then
        fail "child still running after SIGTERM"
    fi
    assert_no_leftovers
    stop_listener hold
    pass "SIGTERM during a hung HTTP probe stops the probe and the child"
}

# Settings fall back to their defaults: silently when empty (Compose passes ""
# when a knob is unset), with one warning when invalid.
test_settings_normalization() {
    local case_name
    run_watch norm-empty DEPENDENCY_CHECK_INTERVAL_SECONDS= DEPENDENCY_TCP_TIMEOUT_SECONDS= \
        DEPENDENCY_HTTP_TIMEOUT_SECONDS= DEPENDENCY_FAILURE_THRESHOLD= -- -- true
    # The default 5 s interval: a finished child is noticed at the next check.
    wait_watcher_exit 10
    assert_log "check every 5s, tcp timeout 2s, http timeout 2s, stop after 3 consecutive failed checks"
    assert_log_count 0 "ignoring invalid" "empty settings fall back silently"

    for case_name in 0 -1 1.5 1234567; do
        run_watch "norm-$case_name" "DEPENDENCY_FAILURE_THRESHOLD=$case_name" -- -- true
        wait_watcher_exit 5
        assert_log "ignoring invalid DEPENDENCY_FAILURE_THRESHOLD=$case_name; using 3"
        assert_log "stop after 3 consecutive failed checks"
    done

    run_watch norm-leading-zero DEPENDENCY_FAILURE_THRESHOLD=07 -- -- true
    wait_watcher_exit 5
    assert_log "stop after 7 consecutive failed checks"
    assert_log_count 0 "ignoring invalid" "a leading zero is still a valid number"

    run_watch norm-cli-interval DEPENDENCY_CHECK_INTERVAL_SECONDS=3 -- --interval abc -- true
    wait_watcher_exit 10
    assert_log "ignoring invalid check interval=abc; using 5"
    assert_log "check every 5s"
    pass "settings normalization: empty is silent, invalid warns once, --interval is covered"
}

# Without a writable scratch directory the watcher still works, with less detail.
test_unwritable_tmpdir() {
    local port
    port="$(free_port)"
    run_watch no-tmpdir TMPDIR=/nonexistent/watch-dependencies -- --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"
    eventually 10 log_has "dep is unavailable at 127.0.0.1:$port (tcp connect failed (exit 1))" ||
        fail "a refused probe must still be reported without a scratch file"
    assert_log "cannot create a scratch file; failure reasons will be less specific"
    kill -TERM "$watcher_pid"
    wait_watcher_exit 5
    [ "$watcher_rc" -eq 143 ] || fail "expected exit 143, got $watcher_rc"
    [ -c /dev/null ] || fail "/dev/null was damaged"
    assert_no_leftovers
    pass "unwritable TMPDIR: one log line, less specific reasons, nothing removed"
}

test_child_exit_status_is_kept() {
    local port
    port="$(free_port)"
    start_listener "$port" exit

    run_watch exit-zero CHILD_EXIT_AFTER=0.5 CHILD_EXIT_CODE=0 -- --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"
    wait_watcher_exit 10
    [ "$watcher_rc" -eq 0 ] || fail "child exit 0: watcher exited $watcher_rc"
    assert_no_leftovers

    run_watch exit-mid-streak CHILD_EXIT_AFTER=1.5 CHILD_EXIT_CODE=7 -- --tcp dep 127.0.0.1 "$port" "${child_cmd[@]}"
    eventually 10 child_started || fail "child did not start"
    stop_listener exit
    wait_watcher_exit 10
    [ "$watcher_rc" -eq 7 ] || fail "child exit 7 during failed checks: watcher exited $watcher_rc"
    [ ! -e "$case_dir/term" ] || fail "a child that exits on its own must not be sent SIGTERM"
    assert_no_leftovers
    pass "the child's own exit status is returned"
}

write_fixtures
printf 'watcher %s under %s (bash probe via %s, wget: %s)\n' "$watch" "${watch_shell[*]}" \
    "$(PATH="$bin:$PATH" command -v bash)" "$(PATH="$bin:$PATH" command -v wget || echo missing)"

test_transient_failures_keep_child_running
test_settings
test_dependency_set_shares_one_count
test_http_any_counts_one_round
test_slow_and_hung_probes
test_sigterm_during_http_probe
test_name_resolution_failure_before_start
test_settings_normalization
test_unwritable_tmpdir
test_child_exit_status_is_kept
