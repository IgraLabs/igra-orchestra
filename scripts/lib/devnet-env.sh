#!/bin/bash
# devnet-env.sh - shared .env reader for the host miner scripts
# (run-devnet-miner.sh, run-devnet-cpuminer.sh). Both need the same precedence
# rule (shell/CLI > .env > default) and the same tolerant parser, so it lives
# here once instead of being copied per script. Covered by
# scripts/dev/test-devnet-env.sh.
#
# Contract: the caller sets $ENV_FILE to the file to read before calling
# resolve/read_env (typically .env, falling back to .env.devnet.example).

# read_env KEY -> prints the trimmed, unquoted value from $ENV_FILE; returns 1 if absent.
# Tolerates CRLF line endings, surrounding whitespace, and single/double quotes;
# last matching assignment wins.
read_env() {
    local key="$1" line val found=1
    [ -f "$ENV_FILE" ] || return 1
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
            "$key"=*)
                val="${line#*=}"
                val="${val#"${val%%[![:space:]]*}"}"
                val="${val%"${val##*[![:space:]]}"}"
                case "$val" in
                    \"*\"|\'*\') val="${val:1:${#val}-2}" ;;
                esac
                found=0
                ;;
        esac
    done < "$ENV_FILE"
    [ "$found" -eq 0 ] && printf '%s' "$val"
    return "$found"
}

# resolve NAME DEFAULT -> sets NAME from shell (if already set) else $ENV_FILE else default.
resolve() {
    local name="$1" default="$2" val
    [ -n "${!name+set}" ] && return 0
    if val="$(read_env "$name")"; then
        printf -v "$name" '%s' "$val"
    else
        printf -v "$name" '%s' "$default"
    fi
}
