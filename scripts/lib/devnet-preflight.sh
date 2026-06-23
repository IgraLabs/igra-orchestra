#!/bin/bash
# devnet-preflight.sh - Validation, mining preflight, and source-revision
# recording for the IGRA devnet setup flow. Sourced by scripts/setup-devnet.sh.
# Functions are pure (inputs via args/env, output via message + return code) so
# they can be unit-tested without Docker (see scripts/dev/test-devnet-preflight.sh).

# --- predicate helpers (return 0 = true, 1 = false; no output) ---

# Reject leading zeros so bash never reads a value as octal in (( ... )).
is_uint()          { [[ "${1:-}" =~ ^(0|[1-9][0-9]*)$ ]]; }
is_positive_int()  { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]; }
is_hex()           { [[ "${1:-}" =~ ^[0-9a-fA-F]+$ ]]; }
is_hex_even()      { [[ "${1:-}" =~ ^([0-9a-fA-F]{2})+$ ]]; }
is_port()          { [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] && (( ${1} >= 1 && ${1} <= 65535 )); }
# Devnet kaspa address: kaspadev: prefix + bech32 charset payload (>= 59 chars).
is_valid_mining_address() {
    [[ "${1:-}" =~ ^kaspadev:[qpzry9x8gf2tvdw0s3jn54khce6mua7l]{59,}$ ]]
}

# validate_devnet_env - check the resolved devnet configuration in the
# environment. Aggregates ALL problems, prints them to stderr, returns 1 if any.
validate_devnet_env() {
    local errors=()
    local toccata="${TOCCATA_ACTIVATION_DAA_SCORE:-}"
    local launch="${IGRA_LAUNCH_DAA_SCORE:-}"
    local l1daa="${L1_REFERENCE_DAA_SCORE:-}"
    local l1ts="${L1_REFERENCE_TIMESTAMP:-}"
    local name p

    # NETWORK
    [ "${NETWORK:-}" = "devnet" ] || \
        errors+=("NETWORK must be 'devnet' (got: '${NETWORK:-<unset>}')")

    # TX_ID_PREFIX
    is_hex_even "${TX_ID_PREFIX:-}" || \
        errors+=("TX_ID_PREFIX must be hex with an even number of chars (got: '${TX_ID_PREFIX:-<unset>}')")

    # IGRA_LANE_ID: 8 or 40 lowercase hex (kaspad validates the exact lane shape at
    # startup); not all-zero (reserved SUBNETWORK_ID_NATIVE); mandatory when Toccata
    # is scheduled.
    if [ -n "${IGRA_LANE_ID:-}" ]; then
        if ! [[ "${IGRA_LANE_ID}" =~ ^([0-9a-f]{8}|[0-9a-f]{40})$ ]]; then
            errors+=("IGRA_LANE_ID must be 8 or 40 lowercase hex chars (got: '${IGRA_LANE_ID}')")
        elif [[ "${IGRA_LANE_ID}" =~ ^0+$ ]]; then
            errors+=("IGRA_LANE_ID must not be all-zero (reserved SUBNETWORK_ID_NATIVE shape)")
        fi
    elif [ -n "$toccata" ]; then
        errors+=("IGRA_LANE_ID is required when TOCCATA_ACTIVATION_DAA_SCORE is set")
    fi

    # FINALITY_PERIOD_SECONDS
    local fin="${FINALITY_PERIOD_SECONDS:-}"
    if ! is_uint "$fin"; then
        errors+=("FINALITY_PERIOD_SECONDS must be an integer (got: '${fin:-<unset>}')")
    elif (( fin < 60 || fin > 92000 )); then
        errors+=("FINALITY_PERIOD_SECONDS must be in [60, 92000] (got: $fin)")
    fi

    # Ports: range, then collision among the valid ones
    local ports=()
    for name in KASPAD_GRPC_PORT KASPAD_P2P_PORT KASPAD_BORSH_PORT KASPAD_JSON_PORT \
                RPC_PORT EL_RPC_HOST_PORT EL_WS_HOST_PORT KASWALLET_HOST_PORT; do
        p="${!name:-}"
        if is_port "$p"; then
            ports+=("$p:$name")
        else
            errors+=("$name must be an integer in 1-65535 (got: '${p:-<unset>}')")
        fi
    done
    if (( ${#ports[@]} > 0 )); then
        local dup
        dup="$(printf '%s\n' "${ports[@]}" | cut -d: -f1 | sort | uniq -d)"
        if [ -n "$dup" ]; then
            local val who
            while IFS= read -r val; do
                [ -n "$val" ] || continue
                who="$(printf '%s\n' "${ports[@]}" | awk -F: -v v="$val" '$1==v{printf "%s ",$2}')"
                errors+=("port collision on $val: ${who% }")
            done <<< "$dup"
        fi
    fi

    # Mining
    is_valid_mining_address "${MINING_ADDRESS:-}" || \
        errors+=("MINING_ADDRESS must be a devnet address (kaspadev:...) (got: '${MINING_ADDRESS:-<unset>}')")
    is_positive_int "${MINING_THREADS:-}" || \
        errors+=("MINING_THREADS must be a positive integer (got: '${MINING_THREADS:-<unset>}')")

    # Lock script pubkey (entry) hex when present
    if [ -n "${IGRA_LOCK_SCRIPT_PUBKEY:-}" ]; then
        is_hex "${IGRA_LOCK_SCRIPT_PUBKEY}" || \
            errors+=("IGRA_LOCK_SCRIPT_PUBKEY must be hex (got: '${IGRA_LOCK_SCRIPT_PUBKEY}')")
    fi

    # Lock-script fork pair: both set or both empty
    local pf="${POST_FORK_LOCK_SCRIPT_PUBKEY:-}" fd="${LOCK_SCRIPT_FORK_DAA_SCORE:-}"
    if [ -n "$pf" ] && [ -z "$fd" ]; then
        errors+=("LOCK_SCRIPT_FORK_DAA_SCORE must be set when POST_FORK_LOCK_SCRIPT_PUBKEY is set")
    fi
    if [ -z "$pf" ] && [ -n "$fd" ]; then
        errors+=("POST_FORK_LOCK_SCRIPT_PUBKEY must be set when LOCK_SCRIPT_FORK_DAA_SCORE is set")
    fi
    [ -z "$pf" ] || is_hex "$pf" || errors+=("POST_FORK_LOCK_SCRIPT_PUBKEY must be hex")
    if [ -n "$fd" ] && ! is_uint "$fd"; then
        errors+=("LOCK_SCRIPT_FORK_DAA_SCORE must be a non-negative integer (got: '$fd')")
    fi

    # RPC bind address: valid host/IP when set; warn on unsafe exposure
    if [ -n "${RPC_BIND_ADDR:-}" ]; then
        [[ "${RPC_BIND_ADDR}" =~ ^[0-9A-Za-z.:_-]+$ ]] || \
            errors+=("RPC_BIND_ADDR must be a valid host/IP (got: '${RPC_BIND_ADDR}')")
        if [ "${RPC_BIND_ADDR}" = "0.0.0.0" ] && [ "${RPC_READ_ONLY:-true}" = "false" ]; then
            echo "WARNING: RPC_BIND_ADDR=0.0.0.0 with RPC_READ_ONLY=false exposes the" >&2
            echo "         wallet-backed RPC off-box with no TLS/auth." >&2
        fi
    fi

    # DAA ordering
    for name in IGRA_LAUNCH_DAA_SCORE L1_REFERENCE_DAA_SCORE L1_REFERENCE_TIMESTAMP; do
        is_uint "${!name:-}" || \
            errors+=("$name must be a non-negative integer (got: '${!name:-<unset>}')")
    done
    if is_uint "$launch" && is_uint "$l1daa" && is_uint "$l1ts"; then
        # Per-term division mirrors run-igra-el.sh's calculate_genesis_timestamp.
        local genesis_ts=$(( 10#$launch / 10 - 10#$l1daa / 10 + 10#$l1ts - 1 ))
        (( genesis_ts > 0 )) || \
            errors+=("derived EL genesis timestamp must be positive: (IGRA_LAUNCH_DAA_SCORE/10 - L1_REFERENCE_DAA_SCORE/10 + L1_REFERENCE_TIMESTAMP - 1) = $genesis_ts")
    fi
    if [ -n "$toccata" ]; then
        if is_uint "$toccata"; then
            if is_uint "$launch" && ! (( toccata > launch )); then
                errors+=("TOCCATA_ACTIVATION_DAA_SCORE ($toccata) must be > IGRA_LAUNCH_DAA_SCORE ($launch)")
            fi
            (( toccata > 200 )) || \
                errors+=("TOCCATA_ACTIVATION_DAA_SCORE ($toccata) must be > coinbase_maturity (200) to leave a pre-fork window")
        else
            errors+=("TOCCATA_ACTIVATION_DAA_SCORE must be a non-negative integer (got: '$toccata')")
        fi
    fi
    if [ -n "$fd" ] && is_uint "$fd" && is_uint "$launch" && ! (( fd >= launch )); then
        errors+=("LOCK_SCRIPT_FORK_DAA_SCORE ($fd) must be >= IGRA_LAUNCH_DAA_SCORE ($launch)")
    fi

    if (( ${#errors[@]} > 0 )); then
        echo "Devnet configuration is invalid:" >&2
        printf '  ERROR: %s\n' "${errors[@]}" >&2
        return 1
    fi
    return 0
}

# resolve_devnet_env - load the single effective env source (.env if present,
# else the committed template) plus the versions file, exporting everything so
# validation AND the build read identical inputs. Shell/CLI values for the
# documented tunables take precedence over the file (README runs the script with
# e.g. FINALITY_PERIOD_SECONDS=600 ./scripts/setup-devnet.sh).
resolve_devnet_env() {
    local project_dir="$1" env_file="$2" versions_file="$3"
    local source_path

    if [ -f "$project_dir/.env" ]; then
        source_path="$project_dir/.env"
    else
        source_path="$project_dir/$env_file"
        echo "[setup-devnet] No .env yet; using template $env_file for build-time inputs" >&2
        echo "               (run_setup will create .env from the same template)." >&2
    fi
    if [ ! -f "$source_path" ]; then
        echo "ERROR: env source not found: $source_path" >&2
        return 1
    fi
    export DEVNET_ENV_SOURCE="$source_path"

    # Capture shell-provided tunables (set, even if empty) so the file cannot
    # clobber a command-line override.
    local k saved=()
    for k in FINALITY_PERIOD_SECONDS TOCCATA_ACTIVATION_DAA_SCORE IGRA_LANE_ID; do
        [ -n "${!k+x}" ] && saved+=("$k=${!k}")
    done

    set -a
    # shellcheck source=/dev/null
    source "$source_path"
    if [ -f "$project_dir/$versions_file" ]; then
        # shellcheck source=/dev/null
        source "$project_dir/$versions_file"
    fi
    set +a

    # Re-apply captured shell overrides (precedence: shell > file).
    if (( ${#saved[@]} > 0 )); then
        local kv
        for kv in "${saved[@]}"; do export "${kv?}"; done
    fi
}

# mining_preflight - validate MINING_ADDRESS/MINING_THREADS and remind the operator
# to start an external miner. Called when Toccata is scheduled, because the KIP-21
# rehearsal cannot reach the activation DAA score without mined blocks.
mining_preflight() {
    local errors=()

    is_valid_mining_address "${MINING_ADDRESS:-}" || \
        errors+=("MINING_ADDRESS must be a devnet address (kaspadev:...) (got: '${MINING_ADDRESS:-<unset>}')")
    is_positive_int "${MINING_THREADS:-}" || \
        errors+=("MINING_THREADS must be a positive integer (got: '${MINING_THREADS:-<unset>}')")

    if (( ${#errors[@]} > 0 )); then
        echo "Mining preflight failed (required for the Toccata/KIP-21 rehearsal):" >&2
        printf '  ERROR: %s\n' "${errors[@]}" >&2
        return 1
    fi

    echo "[setup-devnet] Toccata is scheduled at DAA ${TOCCATA_ACTIVATION_DAA_SCORE:-}." >&2
    echo "               kaspad mines nothing on its own; point a miner at the devnet" >&2
    echo "               kaspad gRPC port (127.0.0.1:\${KASPAD_GRPC_PORT}) with" >&2
    echo "               --mining-address ${MINING_ADDRESS:-} to reach the activation score." >&2
    return 0
}

# record_source_revisions - write a timestamped manifest of the exact source
# revisions (branch/SHA/dirty) of every built repo, so each rehearsal is
# reproducible. Files accumulate (one per run) under <out_dir>.
record_source_revisions() {
    local repos_dir="$1" out_dir="$2"
    local ts manifest repo path branch sha dirty n
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    mkdir -p "$out_dir"
    # Suffix on collision so same-second runs don't clobber each other.
    manifest="$out_dir/$ts.txt"
    n=1
    while [ -e "$manifest" ]; do
        manifest="$out_dir/$ts-$n.txt"
        n=$((n + 1))
    done

    {
        echo "# Devnet rehearsal manifest"
        echo "timestamp_utc: $ts"
        echo "NETWORK: ${NETWORK:-}"
        echo "FINALITY_PERIOD_SECONDS: ${FINALITY_PERIOD_SECONDS:-}"
        echo "TOCCATA_ACTIVATION_DAA_SCORE: ${TOCCATA_ACTIVATION_DAA_SCORE:-}"
        echo "IGRA_LANE_ID: ${IGRA_LANE_ID:-}"
        echo "env_source: ${DEVNET_ENV_SOURCE:-unknown}"
        echo
        printf '%-22s %-22s %-42s %s\n' "repo" "branch" "sha" "state"
        for repo in rusty-kaspa-private reth-private kaswallet igra-rpc-provider; do
            path="$repos_dir/$repo"
            if git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
                branch="$(git -C "$path" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
                sha="$(git -C "$path" rev-parse HEAD 2>/dev/null || echo '?')"
                if [ -n "$(git -C "$path" status --porcelain 2>/dev/null)" ]; then
                    dirty="dirty"
                else
                    dirty="clean"
                fi
            else
                branch="-"; sha="-"; dirty="missing"
            fi
            printf '%-22s %-22s %-42s %s\n' "$repo" "$branch" "$sha" "$dirty"
        done
    } > "$manifest"

    # Keep the newest REHEARSAL_KEEP (default 20) manifests.
    local keep="${REHEARSAL_KEEP:-20}"
    if is_positive_int "$keep"; then
        local old
        # Manifest names are controlled timestamps, so ls -t is safe here.
        # shellcheck disable=SC2012
        while IFS= read -r old; do
            [ -n "$old" ] && rm -f "$old"
        done < <(ls -1t "$out_dir"/*.txt 2>/dev/null | tail -n "+$((keep + 1))")
    fi

    echo "[setup-devnet] Recorded source revisions -> $manifest"
    cat "$manifest"
    return 0
}
