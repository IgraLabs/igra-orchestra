#!/bin/bash
# test-devnet-preflight.sh - plain-bash unit tests for scripts/lib/devnet-preflight.sh
# Run: ./scripts/dev/test-devnet-preflight.sh   (exit 0 = all pass)
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC2034
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../lib/devnet-preflight.sh"

TESTS_RUN=0
TESTS_FAILED=0

# ok DESC CMD...   -> expects CMD to succeed (exit 0)
ok() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then echo "PASS: $desc"; else
        echo "FAIL: $desc (expected success)"; TESTS_FAILED=$((TESTS_FAILED + 1)); fi
}

# no DESC CMD...   -> expects CMD to fail (non-zero)
no() {
    local desc="$1"; shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if "$@"; then
        echo "FAIL: $desc (expected failure)"; TESTS_FAILED=$((TESTS_FAILED + 1));
    else echo "PASS: $desc"; fi
}

# --- predicate tests ---
ok  "is_uint 0"            is_uint 0
ok  "is_uint 123"          is_uint 123
no  "is_uint empty"        is_uint ""
no  "is_uint -5"           is_uint -5
no  "is_uint abc"          is_uint abc
no  "is_uint 08 (octal)"   is_uint 08
no  "is_uint 011 (octal)"  is_uint 011
no  "is_uint 00"           is_uint 00

ok  "is_positive_int 1"    is_positive_int 1
no  "is_positive_int 0"    is_positive_int 0
no  "is_positive_int x"    is_positive_int x
no  "is_positive_int 007"  is_positive_int 007

ok  "is_hex 9ab1"          is_hex 9ab1
no  "is_hex 0xff"          is_hex 0xff
no  "is_hex empty"         is_hex ""

ok  "is_hex_even 97b1"     is_hex_even 97b1
no  "is_hex_even 97b"      is_hex_even 97b
no  "is_hex_even zz"       is_hex_even zz

ok  "is_port 8555"         is_port 8555
ok  "is_port 1"            is_port 1
ok  "is_port 65535"        is_port 65535
no  "is_port 0"            is_port 0
no  "is_port 70000"        is_port 70000
no  "is_port empty"        is_port ""
no  "is_port 08 (octal)"   is_port 08

ok  "mining addr valid"    is_valid_mining_address "kaspadev:qqdk7fjp3dk6yln3d8epz6exafv65jecxkz9ujkhlvgkqwefwtdwsw3q78u7s"
no  "mining addr mainnet"  is_valid_mining_address "kaspa:qqdk7fjp3dk6yln3d8epz6exafv65jecxkz9ujkhlvgkqwefwtdwsw3q78u7s"
no  "mining addr empty"    is_valid_mining_address ""

# --- validate_devnet_env: a known-good baseline, then mutate one field per case ---
# shellcheck disable=SC2034
good_env() {
    NETWORK=devnet
    TX_ID_PREFIX=97b1
    IGRA_LANE_ID=97b10000
    FINALITY_PERIOD_SECONDS=600
    TOCCATA_ACTIVATION_DAA_SCORE=1000
    KASPAD_GRPC_PORT=16610 KASPAD_P2P_PORT=16611
    KASPAD_BORSH_PORT=17610 KASPAD_JSON_PORT=18610
    RPC_PORT=8555 EL_RPC_HOST_PORT=9545 EL_WS_HOST_PORT=9546 KASWALLET_HOST_PORT=8082
    MINING_ADDRESS="kaspadev:qqdk7fjp3dk6yln3d8epz6exafv65jecxkz9ujkhlvgkqwefwtdwsw3q78u7s"
    MINING_THREADS=1
    IGRA_LOCK_SCRIPT_PUBKEY=20aeb014c0814f5c549bbea36638e08b1e8d4c1b8251780841fce1fdcbf72ee01dac
    POST_FORK_LOCK_SCRIPT_PUBKEY="" LOCK_SCRIPT_FORK_DAA_SCORE=""
    RPC_BIND_ADDR=127.0.0.1 RPC_READ_ONLY=true
    IGRA_LAUNCH_DAA_SCORE=0 L1_REFERENCE_DAA_SCORE=0 L1_REFERENCE_TIMESTAMP=1735689600
}

ok "validate: good baseline"        bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; validate_devnet_env"
no "validate: NETWORK not devnet"   bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; NETWORK=mainnet; validate_devnet_env"
no "validate: TX_ID_PREFIX odd"     bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; TX_ID_PREFIX=97b; validate_devnet_env"
no "validate: bad lane id"          bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; IGRA_LANE_ID=zz; validate_devnet_env"
no "validate: lane missing+toccata" bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; IGRA_LANE_ID=; validate_devnet_env"
no "validate: port out of range"    bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; RPC_PORT=70000; validate_devnet_env"
no "validate: port collision"       bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; EL_WS_HOST_PORT=9545; validate_devnet_env"
no "validate: mining addr mainnet"  bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; MINING_ADDRESS=kaspa:qqdk7fjp3dk6yln3d8epz6exafv65jecxkz9ujkhlvgkqwefwtdwsw3q78u7s; validate_devnet_env"
no "validate: lock pair half-set"   bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; POST_FORK_LOCK_SCRIPT_PUBKEY=20ab; validate_devnet_env"
ok "validate: lock pair both set"   bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; POST_FORK_LOCK_SCRIPT_PUBKEY=20ab; LOCK_SCRIPT_FORK_DAA_SCORE=5000; validate_devnet_env"
no "validate: toccata <= maturity"  bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; TOCCATA_ACTIVATION_DAA_SCORE=100; validate_devnet_env"
no "validate: negative genesis ts"  bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; L1_REFERENCE_TIMESTAMP=0; L1_REFERENCE_DAA_SCORE=100; IGRA_LAUNCH_DAA_SCORE=0; validate_devnet_env"
no "validate: finality too low"     bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; FINALITY_PERIOD_SECONDS=10; validate_devnet_env"
ok "validate: open RPC bind warns not errors" bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; RPC_BIND_ADDR=0.0.0.0; RPC_READ_ONLY=false; validate_devnet_env"
no "validate: lane uppercase"       bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; IGRA_LANE_ID=97B10000; validate_devnet_env"
no "validate: lane all-zero"        bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; IGRA_LANE_ID=00000000; validate_devnet_env"
no "validate: kaswallet port clash" bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; KASWALLET_HOST_PORT=8555; validate_devnet_env"
no "validate: zero-padded launch"   bash -c "$(declare -f good_env validate_devnet_env is_uint is_positive_int is_hex is_hex_even is_port is_valid_mining_address); good_env; IGRA_LAUNCH_DAA_SCORE=08; validate_devnet_env"

# --- resolve_devnet_env ---
RESOLVE_TMP="$(mktemp -d)"
mkdir -p "$RESOLVE_TMP"
cat > "$RESOLVE_TMP/.env.devnet.example" <<'ENVEOF'
NETWORK=devnet
FINALITY_PERIOD_SECONDS=600
RPC_PORT=8555
IGRA_LANE_ID=97b10000
ENVEOF
cat > "$RESOLVE_TMP/versions.devnet.env" <<'ENVEOF'
KASPAD_VERSION=devnet
ENVEOF

ok "resolve: loads template when no .env" bash -c "$(declare -f resolve_devnet_env); resolve_devnet_env '$RESOLVE_TMP' .env.devnet.example versions.devnet.env; [ \"\$RPC_PORT\" = 8555 ] && [ \"\$KASPAD_VERSION\" = devnet ] && [ \"\$DEVNET_ENV_SOURCE\" = '$RESOLVE_TMP/.env.devnet.example' ]"
ok "resolve: shell override wins"         bash -c "$(declare -f resolve_devnet_env); FINALITY_PERIOD_SECONDS=999 resolve_devnet_env '$RESOLVE_TMP' .env.devnet.example versions.devnet.env; [ \"\$FINALITY_PERIOD_SECONDS\" = 999 ]"
# A set-but-empty shell override must win over the file value (opt-out contract).
ok "resolve: empty shell override wins"   bash -c "$(declare -f resolve_devnet_env); IGRA_LANE_ID= resolve_devnet_env '$RESOLVE_TMP' .env.devnet.example versions.devnet.env; [ -z \"\$IGRA_LANE_ID\" ]"
ok "resolve: unset falls to file value"   bash -c "$(declare -f resolve_devnet_env); resolve_devnet_env '$RESOLVE_TMP' .env.devnet.example versions.devnet.env; [ \"\$IGRA_LANE_ID\" = 97b10000 ]"
no "resolve: missing source fails"        bash -c "$(declare -f resolve_devnet_env); resolve_devnet_env '$RESOLVE_TMP' .nope.example versions.devnet.env"
rm -rf "$RESOLVE_TMP"

# --- mining_preflight (validates mining config only; the miner is external) ---
MINE_FUNCS="$(declare -f mining_preflight is_valid_mining_address is_positive_int)"

ok "mining: valid addr + threads" bash -c "$MINE_FUNCS; MINING_ADDRESS=kaspadev:qqdk7fjp3dk6yln3d8epz6exafv65jecxkz9ujkhlvgkqwefwtdwsw3q78u7s MINING_THREADS=1 mining_preflight 2>/dev/null"
no "mining: bad address"          bash -c "$MINE_FUNCS; MINING_ADDRESS=kaspa:bad MINING_THREADS=1 mining_preflight 2>/dev/null"
no "mining: bad threads"          bash -c "$MINE_FUNCS; MINING_ADDRESS=kaspadev:qqdk7fjp3dk6yln3d8epz6exafv65jecxkz9ujkhlvgkqwefwtdwsw3q78u7s MINING_THREADS=0 mining_preflight 2>/dev/null"

# --- record_source_revisions ---
REV_TMP="$(mktemp -d)"
mkdir -p "$REV_TMP/repos/rusty-kaspa-private" "$REV_TMP/out"
( cd "$REV_TMP/repos/rusty-kaspa-private" && git init -q && git config user.email t@t && git config user.name t && git commit -q --allow-empty -m init )
REV_FUNCS="$(declare -f record_source_revisions is_positive_int)"
ok "revisions: writes a manifest file" bash -c "$REV_FUNCS; NETWORK=devnet record_source_revisions '$REV_TMP/repos' '$REV_TMP/out' >/dev/null; ls '$REV_TMP/out'/*.txt >/dev/null 2>&1"
ok "revisions: records clean repo"     bash -c "$REV_FUNCS; NETWORK=devnet record_source_revisions '$REV_TMP/repos' '$REV_TMP/out' >/dev/null; grep -q 'rusty-kaspa-private.*clean' \$(ls '$REV_TMP/out'/*.txt | head -1)"
ok "revisions: marks missing repo"     bash -c "$REV_FUNCS; NETWORK=devnet record_source_revisions '$REV_TMP/repos' '$REV_TMP/out' >/dev/null; grep -q '^reth-private.*missing' \$(ls '$REV_TMP/out'/*.txt | tail -1)"
# Retention cap: with REHEARSAL_KEEP=2, three runs leave only the 2 newest manifests.
ok "revisions: caps retention to REHEARSAL_KEEP" bash -c "$REV_FUNCS; export NETWORK=devnet REHEARSAL_KEEP=2; for i in 1 2 3; do record_source_revisions '$REV_TMP/repos' '$REV_TMP/keep' >/dev/null; done; [ \"\$(ls '$REV_TMP/keep'/*.txt | wc -l)\" -eq 2 ]"
rm -rf "$REV_TMP"

echo "----"
echo "$((TESTS_RUN - TESTS_FAILED))/$TESTS_RUN passed"
[ "$TESTS_FAILED" -eq 0 ]
