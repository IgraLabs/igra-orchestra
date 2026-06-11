#!/usr/bin/env bash
set -euo pipefail

fail() {
    echo "ERROR: $*" >&2
    exit 64
}

contains_placeholder() {
    [[ "$1" == *CHANGE_ME* || "$1" == *REPLACE_ME* ]]
}

require_file() {
    [[ -f "$1" ]] || fail "Missing required file: $1"
}

require_env_key() {
    local key="$1"
    local value="${!key:-}"
    [[ -n "$value" ]] || fail "${key} is empty"
    ! contains_placeholder "$value" || fail "${key} still contains placeholder: ${value}"
}

check_safe_env() {
    local env_file="$1"
    require_file "$env_file"
    set -a
    # shellcheck source=/dev/null
    source "$env_file"
    set +a

    require_env_key DJANGO_SECRET_KEY
    require_env_key DJANGO_ALLOWED_HOSTS
    require_env_key DATABASE_URL
    require_env_key POSTGRES_PASSWORD
    require_env_key REDIS_URL
    require_env_key ETHEREUM_NODE_URL
    require_env_key KASPA_PST_HELPER_PATH

    [[ "${ETHEREUM_NODE_URL}" == http://* || "${ETHEREUM_NODE_URL}" == https://* ]] \
        || fail "ETHEREUM_NODE_URL must be http(s), got ${ETHEREUM_NODE_URL}"
}

check_builder_env() {
    local env_file="$1"
    local config_file="$2"
    require_file "$env_file"
    require_file "$config_file"

    if grep -qE 'CHANGE_ME|REPLACE_ME|KPUB_SIGNER|BRIDGE_CUSTODY_ADDRESS' "$config_file"; then
        fail "${config_file} still contains placeholders"
    fi

    python3 - "$config_file" <<'PY'
import json
import sys

path = sys.argv[1]
with open(path, encoding="utf-8") as fh:
    cfg = json.load(fh)

def fail(message):
    raise SystemExit(f"ERROR: {message}")

if cfg.get("network") != "mainnet":
    fail("proposal-builder config network must be mainnet")
if not str(cfg.get("bridge", {}).get("address", "")).startswith("kaspa:"):
    fail("bridge.address must be a Kaspa mainnet address starting with kaspa:")
for key in ("igraRpcUrl", "safeApiUrl"):
    value = str(cfg.get(key, ""))
    if not value.startswith(("http://", "https://")):
        fail(f"{key} must be http(s)")
kaspa_rpc = str(cfg.get("kaspa", {}).get("rpcUrl", ""))
if not kaspa_rpc.startswith(("http://", "https://", "grpc://")):
    fail("kaspa.rpcUrl must be http(s) or grpc")
contracts = cfg.get("contracts", {})
for key in ("kasExitBridge", "mailbox", "merkleTreeHook"):
    value = str(contracts.get(key, ""))
    if not value.startswith("0x") or len(value) != 42:
        fail(f"contracts.{key} must be a 20-byte hex address")
if not cfg.get("bridge", {}).get("kpubs"):
    fail("bridge.kpubs is empty")
if int(cfg.get("bridge", {}).get("threshold", 0)) < 1:
    fail("bridge.threshold must be positive")
print("proposal-builder config shape ok")
PY
}

case "${1:-}" in
    safe)
        check_safe_env "${2:?env file required}"
        ;;
    builder)
        check_builder_env "${2:?env file required}" "${3:?config file required}"
        ;;
    *)
        fail "Usage: $0 safe <env-file> | builder <env-file> <config-file>"
        ;;
esac
