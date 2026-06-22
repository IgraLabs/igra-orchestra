#!/bin/bash
# upgrade-mainnet-v2.3-to-v3.0.sh
#
# Reconcile an existing IGRA Orchestra MAINNET .env from the v2.3 line to v3.0.
#
# The v3.0 docker-compose.yml refuses to render without IGRA_LANE_ID and
# TX_ID_PREFIX (both guarded by ${VAR:?...}), and its kaspad/kaswallet
# entrypoints pass the post-Toccata flags --igra-lane-id / --subnetwork-id
# unconditionally, so mainnet must run 3.0 images. This script edits .env only;
# it does NOT touch Docker volumes — mainnet keeps NETWORK=mainnet and reuses
# its existing kaspad/reth data. It is idempotent: safe to re-run.
#
# What it changes in .env:
#   - adds IGRA_LANE_ID=97b10000                     (new required lane namespace)
#   - ensures TX_ID_PREFIX=97b1                      (now required; set only if unset)
#   - ensures SERVICE_RESTART_POLICY=unless-stopped  (set only if unset)
#   - syncs image-version pins from versions.mainnet.env (kaspad/reth -> 3.0;
#     rpc-provider/kaswallet stay 2.3 until the mainnet Toccata switch)
# A timestamped mode-600 backup (.env.backup.pre-v3.0.*) is written first.
#
# Usage: scripts/upgrade-mainnet-v2.3-to-v3.0.sh [-y|--yes]
set -euo pipefail

# Resolve repo root and reuse the shared setup helpers (update_env_var,
# read_env_value, log, error, die). Sourcing setup-common.sh also loads the
# pins from versions.mainnet.env via VERSIONS_FILE below; it does not run setup.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Consumed by setup-common.sh (it validates/loads image versions at source time).
# shellcheck disable=SC2034
ENV_NAME="IGRA Mainnet"
# shellcheck disable=SC2034
ENV_FILE=".env.mainnet.example"
# shellcheck disable=SC2034
NODE_ID_PREFIX="MN-"
# shellcheck disable=SC2034
KASWALLET_FLAG="--enable-mainnet-pre-launch"
VERSIONS_FILE="versions.mainnet.env"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/setup-common.sh"

cd "$PROJECT_DIR"

# --- canonical mainnet values ---
EXPECTED_NETWORK="mainnet"
EXPECTED_IGRA_CHAIN_ID="38833"
EXPECTED_TX_ID_PREFIX="97b1"
# Post-KIP21 dedicated IGRA lane namespace (4 bytes / 8 lowercase hex chars,
# no 0x prefix). Shared across all networks; required by the v3.0 compose.
IGRA_LANE_ID_VALUE="97b10000"
DEFAULT_RESTART_POLICY="unless-stopped"
IMAGE_VERSION_VARS=(
    KASPAD_VERSION
    RETH_VERSION
    RPC_PROVIDER_VERSION
    KASWALLET_VERSION
    NODE_HEALTH_CHECK_VERSION
    ATAN_UPLOADER_VERSION
)

ASSUME_YES=false
for arg in "$@"; do
    case "$arg" in
        -y|--yes) ASSUME_YES=true ;;
        -h|--help)
            echo "Usage: scripts/upgrade-mainnet-v2.3-to-v3.0.sh [-y|--yes]"
            echo "Reconcile an existing mainnet .env from the v2.3 line to v3.0 (edits .env only)."
            exit 0 ;;
        *) die "Unknown argument: $arg (use -y/--yes to skip the confirmation prompt)" ;;
    esac
done

# Single-instance lock. Best-effort: flock may be absent on macOS, and unlike a
# volume migration the .env edit is atomic (update_env_var) and idempotent, so a
# missing lock is not fatal here.
if command -v flock >/dev/null 2>&1; then
    LOCKFILE="${TMPDIR:-/tmp}/upgrade-mainnet-v2.3-to-v3.0.$(id -u).lock"
    exec 9>"$LOCKFILE"
    flock -n 9 || die "another upgrade run is in progress (lock: $LOCKFILE)"
fi

# --- preflight ---
[[ -f docker-compose.yml ]] || die "docker-compose.yml not found in $PROJECT_DIR; run this from the igra-orchestra repo root."
[[ -f .env ]] || die ".env not found in $PROJECT_DIR. Nothing to upgrade — use scripts/setup-mainnet.sh for a fresh deployment."
[[ -f "$VERSIONS_FILE" ]] || die "$VERSIONS_FILE not found in $PROJECT_DIR; cannot sync image-version pins."

network_value="$(read_env_value .env NETWORK)"
[[ "$network_value" == "$EXPECTED_NETWORK" ]] \
    || die ".env NETWORK is '${network_value:-<unset>}', not '$EXPECTED_NETWORK'. This script is mainnet-only; for Galleon see doc/node-operations/migrate-galleon-to-testnet-10.md."
chain_value="$(read_env_value .env IGRA_CHAIN_ID)"
[[ "$chain_value" == "$EXPECTED_IGRA_CHAIN_ID" ]] \
    || die ".env IGRA_CHAIN_ID is '${chain_value:-<unset>}', not the mainnet value '$EXPECTED_IGRA_CHAIN_ID'. Refusing to edit a non-mainnet or stale .env; correct it or edit .env by hand."

# The pins we are about to sync must be real values (not empty / TODO_*).
for v in "${IMAGE_VERSION_VARS[@]}"; do
    pin="$(read_env_value "$VERSIONS_FILE" "$v")"
    [[ -n "$pin" && "$pin" != TODO_* ]] \
        || die "$VERSIONS_FILE has no usable value for $v ('${pin:-<empty>}'); fix the versions file before upgrading."
done

# --- show planned changes ---
cur_lane="$(read_env_value .env IGRA_LANE_ID)"
cur_prefix="$(read_env_value .env TX_ID_PREFIX)"
cur_restart="$(read_env_value .env SERVICE_RESTART_POLICY)"
cur_atan="$(read_env_value .env ATAN_IMPORT_URL)"

echo "Planned .env changes (mainnet v2.3 -> v3.0):"
printf '  %-28s %s -> %s\n' "IGRA_LANE_ID" "${cur_lane:-<unset>}" "$IGRA_LANE_ID_VALUE"
if [[ -z "$cur_prefix" ]]; then
    printf '  %-28s %s -> %s\n' "TX_ID_PREFIX" "<unset>" "$EXPECTED_TX_ID_PREFIX"
elif [[ "$cur_prefix" != "$EXPECTED_TX_ID_PREFIX" ]]; then
    printf '  %-28s %s (kept; mainnet canonical is %s) !!\n' "TX_ID_PREFIX" "$cur_prefix" "$EXPECTED_TX_ID_PREFIX"
else
    printf '  %-28s %s (unchanged)\n' "TX_ID_PREFIX" "$cur_prefix"
fi
if [[ -z "$cur_restart" ]]; then
    printf '  %-28s %s -> %s\n' "SERVICE_RESTART_POLICY" "<unset>" "$DEFAULT_RESTART_POLICY"
else
    printf '  %-28s %s (unchanged)\n' "SERVICE_RESTART_POLICY" "$cur_restart"
fi
echo "  image-version pins (from $VERSIONS_FILE):"
for v in "${IMAGE_VERSION_VARS[@]}"; do
    cur="$(read_env_value .env "$v")"
    new="$(read_env_value "$VERSIONS_FILE" "$v")"
    printf '       %-26s %s -> %s\n' "$v" "${cur:-<unset>}" "$new"
done
if [[ -n "$cur_atan" ]]; then
    echo "  note: ATAN_IMPORT_URL is set ('$cur_atan'). v3.0 auto-builds it as"
    echo "        {CDN_BASE_URL}/mainnet/97b1/index.pb; left unchanged — verify or unset"
    echo "        it unless you are deliberately overriding the default."
fi
echo "A timestamped backup of .env is written first; Docker volumes are NOT touched."

if [[ "$ASSUME_YES" != true ]]; then
    yn=""
    read -r -p "Proceed? [y/N]: " yn || true
    [[ "$yn" =~ ^[Yy] ]] || { echo "Aborted; .env unchanged."; exit 1; }
fi

# --- backup (.env may hold credentials: keep it mode 600) ---
backup_file=".env.backup.pre-v3.0.$(date +%Y%m%d_%H%M%S)"
(umask 077 && cp .env "$backup_file")
chmod 600 "$backup_file"
log "Backed up .env -> $backup_file"

# --- apply (update_env_var upserts: replace if present, append if absent) ---
update_env_var .env IGRA_LANE_ID "$IGRA_LANE_ID_VALUE"
if [[ -z "$cur_prefix" ]]; then
    update_env_var .env TX_ID_PREFIX "$EXPECTED_TX_ID_PREFIX"
elif [[ "$cur_prefix" != "$EXPECTED_TX_ID_PREFIX" ]]; then
    error "TX_ID_PREFIX kept at '$cur_prefix' (mainnet canonical is '$EXPECTED_TX_ID_PREFIX'); not overwriting a custom value."
fi
[[ -n "$cur_restart" ]] || update_env_var .env SERVICE_RESTART_POLICY "$DEFAULT_RESTART_POLICY"
for v in "${IMAGE_VERSION_VARS[@]}"; do
    update_env_var .env "$v" "$(read_env_value "$VERSIONS_FILE" "$v")"
done

# --- post-write validation ---
[[ "$(read_env_value .env IGRA_LANE_ID)" == "$IGRA_LANE_ID_VALUE" ]] \
    || die "post-write check failed: IGRA_LANE_ID is not $IGRA_LANE_ID_VALUE"
for v in "${IMAGE_VERSION_VARS[@]}"; do
    want="$(read_env_value "$VERSIONS_FILE" "$v")"
    [[ "$(read_env_value .env "$v")" == "$want" ]] \
        || die "post-write check failed: $v is not $want"
done
env_mode="$(stat -c %a .env 2>/dev/null || stat -f %A .env)"
[[ "$env_mode" == "600" ]] || error ".env mode is $env_mode (expected 600); review permissions."
log ".env reconciled to v3.0."

# Prove the compose file renders with the new .env (i.e. the ${VAR:?...} guards
# are satisfied). `docker compose config` needs only the CLI/plugin, not the daemon.
if docker compose version >/dev/null 2>&1; then
    if docker compose config -q; then
        log "docker compose config: OK (required variables present)."
    else
        die "docker compose config failed after the .env update; inspect the error above."
    fi
else
    error "docker compose not found; skipped compose validation. Run 'docker compose config -q' once it is available."
fi

cat <<EOF

Done. .env reconciled to v3.0 (backup: $backup_file). Docker volumes untouched.

Next steps:
  1. First backend start: the kaspad image bump always triggers a one-time DB
     metadata upgrade that prompts for confirmation and crash-loops inside Docker
     without a TTY, so approve it noninteractively on this first start:

       KASPAD_NONINTERACTIVE=true docker compose --profile backend up -d --no-build
       docker compose logs -f kaspad     # wait until it logs past the upgrade

  2. Once kaspad is past the upgrade, recreate it without the override:

       docker compose --profile backend up -d --no-build --force-recreate kaspad

  rpc-provider and kaswallet stay on 2.3 for now: do NOT recreate the frontend
  profile until after the mainnet Toccata switch. Leave the existing worker
  containers running (they keep emitting native v0 transactions). See the
  runbook's "After the Toccata switch" section for the worker bump.

Full procedure & troubleshooting:
  doc/node-operations/upgrade-mainnet-v2.3-to-v3.0.md
EOF
