#!/bin/bash
# Migrate Galleon from NETWORK=testnet to NETWORK=testnet-10 without losing IBD state.
# Stops old/new projects, copies volumes into the new namespace, and backs up .env.
set -euo pipefail

# Prevent concurrent 50GB+ volume copies and .env rewrites for this UID.
LOCKFILE="${TMPDIR:-/tmp}/migrate-galleon-to-testnet-10.$(id -u).lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "ERROR: Another migration is already running (lockfile: $LOCKFILE)" >&2
    exit 1
fi

SRC_PROJECT="igra-orchestra-testnet"
DST_PROJECT="igra-orchestra-testnet-10"
VOLUMES=(kaspad_data reth_data traefik_certs)
LEGACY_ATAN_IMPORT_URL="https://dyehoijgeqfp8.cloudfront.net/testnet/97b4/index.pb"
EXPECTED_IGRA_CHAIN_ID="38836"
EXPECTED_TX_ID_PREFIX="97b4"
EXPECTED_GENESIS_BLOCK_HASH="0x9816ede09a09a8e89c3c0158db66c3ea9ee16a81dfc7f2b80f7f38be5b1c28f2"
# Pin tool behavior for the volume copy checks.
BUSYBOX_IMAGE="busybox:1.36.1"

die() { echo "ERROR: $*" >&2; exit 1; }

require_env_value() {
    local key="$1"
    local expected="$2"
    if ! grep -qxF "$key=$expected" .env; then
        die ".env $key is not the expected Galleon value '$expected'; aborting automatic migration. Use a manual migration for custom or stale testnet deployments."
    fi
}

assert_volume_unused() {
    local volume="$1"
    local users
    users="$(docker ps --filter "volume=$volume" --format '{{.Names}}' | paste -sd, -)"
    if [[ -n "$users" ]]; then
        die "volume $volume is still mounted by running container(s): $users. Stop them before migrating."
    fi
}

# Anchor destructive operations to the repo root before touching .env or volumes.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

# Pre-flight guards against custom/stale networks and the wrong checkout.
docker info >/dev/null || die "Docker daemon not reachable"
docker compose version >/dev/null 2>&1 \
    || die "Docker Compose v2 plugin not available; this script requires 'docker compose' (not 'docker-compose')."
[[ -f docker-compose.yml ]] || die "docker-compose.yml not found in $PROJECT_DIR (this script must run from the igra-orchestra repo root)"
[[ -f .env ]] || die ".env not found in $PROJECT_DIR"
grep -q '^IGRA_CHAIN_ID=' .env || die ".env in $PROJECT_DIR lacks IGRA_CHAIN_ID; this does not look like an orchestra .env"
grep -qE '^NETWORK=testnet[[:space:]]*$' .env || die ".env NETWORK is not 'testnet' (already migrated or different network)"
require_env_value "IGRA_CHAIN_ID" "$EXPECTED_IGRA_CHAIN_ID"
require_env_value "TX_ID_PREFIX" "$EXPECTED_TX_ID_PREFIX"
require_env_value "GENESIS_BLOCK_HASH" "$EXPECTED_GENESIS_BLOCK_HASH"

# Pre-flight size summary so the operator can sanity-check disk space BEFORE
# committing to the migration. Two `du` invocations per volume in one docker
# run keeps the per-volume overhead to roughly one container start.
echo "Source volumes to copy:"
total_kb=0
for v in "${VOLUMES[@]}"; do
    src="${SRC_PROJECT}_$v"
    if docker volume inspect "$src" >/dev/null 2>&1; then
        size_info=$(docker run --rm -v "$src:/from:ro" "$BUSYBOX_IMAGE" \
            sh -c 'du -sk /from; du -sh /from' 2>/dev/null)
        size_kb=$(printf '%s\n' "$size_info" | head -1 | awk '{print $1}')
        size_h=$(printf '%s\n' "$size_info" | tail -1 | awk '{print $1}')
        printf "  %-48s %s\n" "$src" "${size_h:-?}"
        total_kb=$((total_kb + ${size_kb:-0}))
    else
        printf "  %-48s (missing)\n" "$src"
    fi
done
printf "Total to copy: ~%d MB (host needs >=1.2x free on the docker volume root)\n" \
    "$((total_kb / 1024))"

echo "About to:"
echo "  1. Stop projects $SRC_PROJECT and $DST_PROJECT (across all profiles)"
echo "  2. Copy volumes ${VOLUMES[*]} from $SRC_PROJECT to $DST_PROJECT (old volumes kept as backup)"
echo "  3. Rewrite .env: NETWORK=testnet -> NETWORK=testnet-10"
echo "  4. Pin ATAN_IMPORT_URL to the legacy published Galleon CDN path"
read -r -p "Proceed? [y/N]: " yn
[[ "$yn" =~ ^[Yy] ]] || exit 1

# Stop all profile-gated services before copying RocksDB volumes.
docker compose -p "$SRC_PROJECT" --profile '*' down
docker compose -p "$DST_PROJECT" --profile '*' down
for proj in "$SRC_PROJECT" "$DST_PROJECT"; do
    if [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null)" ]]; then
        die "$proj still has running containers after 'down'; aborting before volume copy"
    fi
done

# Copy volumes into the new namespace; old volumes remain as backup.
# Empty destination volumes are reusable; populated ones require manual cleanup.
copy_phase_start=$(date +%s)
for v in "${VOLUMES[@]}"; do
    src="${SRC_PROJECT}_$v"
    dst="${DST_PROJECT}_$v"
    if ! docker volume inspect "$src" >/dev/null 2>&1; then
        case "$v" in
            kaspad_data|reth_data)
                die "$src does not exist; refusing to migrate without the chain data volume. Verify the legacy compose project name/volume names, or perform a fresh sync intentionally instead of using this migration script."
                ;;
        esac
        echo "skip optional $src (does not exist)"
        continue
    fi
    # Source is mounted read-only after compose shutdown and a running-container check.
    # A RocksDB LOCK-file stat check cannot prove whether fcntl still holds the lock.
    if docker volume inspect "$dst" >/dev/null 2>&1; then
        if docker run --rm -v "$dst:/check:ro" "$BUSYBOX_IMAGE" \
                sh -c '[ -z "$(ls -A /check 2>/dev/null)" ]'; then
            echo "resume: $dst exists but is empty"
        else
            die "$dst already exists and contains data. Remove with 'docker volume rm $dst' before re-running, or migrate manually."
        fi
    else
        docker volume create "$dst" >/dev/null
    fi
    assert_volume_unused "$src"
    assert_volume_unused "$dst"

    # Per-volume timing + heartbeat. Set MIGRATE_QUIET=1 to silence the
    # in-copy heartbeat (start/end markers still print regardless).
    src_size=$(docker run --rm -v "$src:/from:ro" "$BUSYBOX_IMAGE" \
        du -sh /from 2>/dev/null | awk '{print $1}')
    volume_start=$(date +%s)
    printf "[%s] copying %s (%s) -> %s ...\n" \
        "$(date +%H:%M:%S)" "$src" "${src_size:-?}" "$dst"

    # Preserve per-file ownership with cp -a; only align the volume root owner/mode.
    # Do not chown -R, which would overwrite the copied data's original UIDs.
    docker run --rm \
        -e MIGRATE_QUIET="${MIGRATE_QUIET:-}" \
        -v "$src:/from:ro" -v "$dst:/to" "$BUSYBOX_IMAGE" sh -c '
        set -e
        # Background heartbeat: every 30s, print the destination size to stderr
        # so the operator sees progress during the long cp -a. Trap kills the
        # subshell whether cp succeeds or fails so we never leak it.
        if [ -z "$MIGRATE_QUIET" ]; then
            (
                while sleep 30; do
                    current=$(du -sh /to 2>/dev/null | awk "{print \$1}")
                    [ -n "$current" ] && printf "    ... %s copied so far\n" "$current" >&2
                done
            ) &
            progress_pid=$!
            trap "kill $progress_pid 2>/dev/null || true; wait $progress_pid 2>/dev/null || true" EXIT
        fi

        cp -a /from/. /to/
        owner="$(stat -c "%u:%g" /from)"
        mode="$(stat -c "%a" /from)"
        chown "$owner" /to
        chmod "$mode" /to
        # Catch empty, partial, or truncated copies before kaspad opens the data.
        from_files=$(find /from -type f | wc -l)
        to_files=$(find /to   -type f | wc -l)
        if [ "$from_files" != "$to_files" ]; then
            echo "ERROR: file count mismatch after cp -a: /from=$from_files /to=$to_files" >&2
            exit 1
        fi
        from_bytes=$(find /from -type f -exec stat -c %s {} + 2>/dev/null | awk '"'"'{s+=$1} END{print s+0}'"'"')
        to_bytes=$(find /to   -type f -exec stat -c %s {} + 2>/dev/null | awk '"'"'{s+=$1} END{print s+0}'"'"')
        if [ "$from_bytes" != "$to_bytes" ]; then
            echo "ERROR: byte count mismatch after cp -a: /from=$from_bytes /to=$to_bytes" >&2
            exit 1
        fi
    '
    volume_end=$(date +%s)
    elapsed=$((volume_end - volume_start))
    printf "[%s] copied  %s -> %s in %dm%02ds\n" \
        "$(date +%H:%M:%S)" "$src" "$dst" "$((elapsed / 60))" "$((elapsed % 60))"
done
copy_phase_end=$(date +%s)
total_elapsed=$((copy_phase_end - copy_phase_start))
printf "[%s] all volumes copied in %dm%02ds; rewriting .env ...\n" \
    "$(date +%H:%M:%S)" "$((total_elapsed / 60))" "$((total_elapsed % 60))"

# Rewrite .env via temp file and later assert the migration actually applied.
backup_file=".env.backup.pre-testnet-10.$(date +%Y%m%d_%H%M%S)"
(umask 077 && cp .env "$backup_file")
chmod 600 "$backup_file"
cleanup_files=()
trap 'rm -f "${cleanup_files[@]+"${cleanup_files[@]}"}"' EXIT INT TERM
# .env may contain credentials; create temp files with mode 600.
tmp_env="$(umask 077 && mktemp .env.XXXXXX)"
cleanup_files+=("$tmp_env")
sed 's/^NETWORK=testnet[[:space:]]*$/NETWORK=testnet-10/' .env > "$tmp_env"
if grep -q '^ATAN_IMPORT_URL=' "$tmp_env"; then
    tmp_env_with_atan="$(umask 077 && mktemp .env.XXXXXX)"
    cleanup_files+=("$tmp_env_with_atan")
    sed "s|^ATAN_IMPORT_URL=.*$|ATAN_IMPORT_URL=$LEGACY_ATAN_IMPORT_URL|" "$tmp_env" > "$tmp_env_with_atan"
    mv -f "$tmp_env_with_atan" "$tmp_env"
else
    {
        printf '\n# Legacy Galleon ATAN import path; keep until /testnet-10/97b4/index.pb is published.\n'
        printf 'ATAN_IMPORT_URL=%s\n' "$LEGACY_ATAN_IMPORT_URL"
    } >> "$tmp_env"
fi
mv -f "$tmp_env" .env
# Assert the credential-bearing .env stayed mode 600.
env_mode=$(stat -c %a .env 2>/dev/null || stat -f %A .env)
[[ "$env_mode" == "600" ]] || die ".env mode drifted to $env_mode after rewrite; expected 600"
trap - EXIT INT TERM
grep -qE '^NETWORK=testnet-10[[:space:]]*$' .env \
    || die "sed did not rewrite NETWORK in .env (check for trailing comment, CRLF endings, or leading whitespace)"
grep -qF "ATAN_IMPORT_URL=$LEGACY_ATAN_IMPORT_URL" .env \
    || die "failed to pin ATAN_IMPORT_URL to the legacy Galleon CDN path"
printf "[%s] .env migrated and backup written to %s\n" "$(date +%H:%M:%S)" "$backup_file"

echo "Done. Bring the new project up: docker compose --profile backend up -d --no-build"
prefixed_old_volumes=("${VOLUMES[@]/#/${SRC_PROJECT}_}")
echo "After verifying sync, remove old volumes with: docker volume rm ${prefixed_old_volumes[*]}"
