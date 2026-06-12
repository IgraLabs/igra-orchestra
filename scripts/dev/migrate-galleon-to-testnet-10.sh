#!/bin/bash
# Migrate Galleon from NETWORK=testnet to NETWORK=testnet-10 without losing IBD state.
# Stops old/new projects, renames volumes into the new namespace via rename(2) on
# the docker host's filesystem, and rewrites .env (with a timestamped backup).
set -euo pipefail

# Prevent concurrent renames and .env rewrites for this UID.
LOCKFILE="${TMPDIR:-/tmp}/migrate-galleon-to-testnet-10.$(id -u).lock"
exec 9>"$LOCKFILE"
if ! flock -n 9; then
    echo "ERROR: Another migration is already running (lockfile: $LOCKFILE)" >&2
    exit 1
fi

SRC_PROJECT="igra-orchestra-testnet"
DST_PROJECT="igra-orchestra-testnet-10"
VOLUMES=(kaspad_data reth_data traefik_certs)
LEGACY_ATAN_IMPORT_URL="https://dyehoijgeqfp8.cloudfront.net/testnet-10/97b4/index.pb"
EXPECTED_IGRA_CHAIN_ID="38836"
EXPECTED_TX_ID_PREFIX="97b4"
EXPECTED_GENESIS_BLOCK_HASH="0x9816ede09a09a8e89c3c0158db66c3ea9ee16a81dfc7f2b80f7f38be5b1c28f2"
# Post-KIP21 dedicated IGRA lane namespace (4 bytes / 8 lowercase hex
# chars, no 0x prefix — see atan/core/src/kip21.rs in rusty-kaspa).
EXPECTED_IGRA_LANE_ID="97b10000"
# Repo-tracked source of truth for image tags; the operator's .env was merged
# from this at first setup and can drift across version bumps, so the migration
# resyncs each pin into .env so `docker compose up` pulls the right tags.
VERSIONS_FILE="versions.galleon-testnet.env"
IMAGE_VERSION_VARS=(
    KASPAD_VERSION
    RETH_VERSION
    RPC_PROVIDER_VERSION
    KASWALLET_VERSION
    NODE_HEALTH_CHECK_VERSION
    ATAN_UPLOADER_VERSION
)
BUSYBOX_IMAGE="busybox:1.36.1"

die() { echo "ERROR: $*" >&2; exit 1; }

# Read a single KEY=value pin from a versions.*.env file. Outputs the value
# (everything after the first '='). Returns the first match only.
read_version_pin() {
    local file="$1"
    local key="$2"
    sed -n "s/^${key}=\\(.*\\)\$/\\1/p" "$file" | head -n1
}

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
[[ -f "$VERSIONS_FILE" ]] || die "$VERSIONS_FILE not found in $PROJECT_DIR; cannot sync image-version pins into .env"
grep -q '^IGRA_CHAIN_ID=' .env || die ".env in $PROJECT_DIR lacks IGRA_CHAIN_ID; this does not look like an orchestra .env"
grep -qE '^NETWORK=testnet[[:space:]]*$' .env || die ".env NETWORK is not 'testnet' (already migrated or different network)"
require_env_value "IGRA_CHAIN_ID" "$EXPECTED_IGRA_CHAIN_ID"
require_env_value "TX_ID_PREFIX" "$EXPECTED_TX_ID_PREFIX"
require_env_value "GENESIS_BLOCK_HASH" "$EXPECTED_GENESIS_BLOCK_HASH"
# Each image-version pin must already be present in .env (setup-galleon-testnet
# merged versions.galleon-testnet.env into .env at first setup). The migration
# resyncs to whatever the git-tracked versions file currently holds; we don't
# validate that file because git is the source of truth for those pins.
for version_var in "${IMAGE_VERSION_VARS[@]}"; do
    grep -q "^${version_var}=" .env \
        || die ".env in $PROJECT_DIR lacks ${version_var}; re-run scripts/setup-galleon-testnet.sh first so the version pins exist before migrating."
done

# Pre-flight summary. Renaming is metadata-only (rename(2) on the docker
# host's fs), so no extra disk is needed; we still list sizes so the operator
# sees which volumes are about to be moved.
echo "Source volumes to rename:"
for v in "${VOLUMES[@]}"; do
    src="${SRC_PROJECT}_$v"
    if docker volume inspect "$src" >/dev/null 2>&1; then
        size_h=$(docker run --rm -v "$src:/from:ro" "$BUSYBOX_IMAGE" \
            du -sh /from 2>/dev/null | awk '{print $1}')
        printf "  %-48s %s\n" "$src" "${size_h:-?}"
    else
        printf "  %-48s (missing)\n" "$src"
    fi
done

echo "About to:"
echo "  1. Stop projects $SRC_PROJECT and $DST_PROJECT (across all profiles)"
echo "  2. Rename volumes ${VOLUMES[*]} from $SRC_PROJECT to $DST_PROJECT (old volumes are removed)"
echo "  3. Rewrite .env: NETWORK=testnet -> NETWORK=testnet-10"
echo "  4. Pin ATAN_IMPORT_URL to the canonical Galleon CDN path"
echo "  5. Set IGRA_LANE_ID=$EXPECTED_IGRA_LANE_ID (post-KIP21 dedicated lane)"
echo "  6. Sync image-version pins from $VERSIONS_FILE into .env:"
for version_var in "${IMAGE_VERSION_VARS[@]}"; do
    printf "       %-28s -> %s\n" "$version_var" "$(read_version_pin "$VERSIONS_FILE" "$version_var")"
done
echo "This is one-way: once the rename completes, the old volumes no longer exist."
read -r -p "Proceed? [y/N]: " yn
[[ "$yn" =~ ^[Yy] ]] || exit 1

# Stop all profile-gated services before renaming RocksDB volumes — a live
# fcntl LOCK on the source would survive the metadata rename and corrupt the
# database when kaspad reopens it. --remove-orphans catches containers that
# have the right project label but a config-hash that no longer matches the
# loaded docker-compose.yml (e.g. started from an older compose checkout).
docker compose -p "$SRC_PROJECT" --profile '*' down --remove-orphans
docker compose -p "$DST_PROJECT" --profile '*' down --remove-orphans

# Defense-in-depth: if anything still has the project label, force-remove it
# directly. Volume rename only cares that no fcntl LOCK remains; compose-level
# network/cleanup is irrelevant for the migration.
for proj in "$SRC_PROJECT" "$DST_PROJECT"; do
    survivor_ids=$(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null)
    if [[ -n "$survivor_ids" ]]; then
        echo "Force-removing $proj containers that survived 'compose down':"
        # shellcheck disable=SC2086  # survivor_ids is a space-separated id list
        docker ps -a --filter "label=com.docker.compose.project=$proj" --format '  {{.Names}}'
        # shellcheck disable=SC2086
        docker rm -f $survivor_ids >/dev/null
    fi
done

# Final guard: anything still running here is a real anomaly.
for proj in "$SRC_PROJECT" "$DST_PROJECT"; do
    if [[ -n "$(docker ps -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null)" ]]; then
        die "$proj still has running containers after force-remove; aborting before volume rename"
    fi
done

# Rename volumes into the new namespace by moving each volume's _data dir on
# the docker host's filesystem. Both src and dst _data dirs are siblings under
# /var/lib/docker/volumes so `mv` is a rename(2) syscall — metadata-only,
# instant, regardless of how large the volume is.
rename_phase_start=$(date +%s)
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
    if docker volume inspect "$dst" >/dev/null 2>&1; then
        # Detect partial-success resume: the rename completed but the
        # `docker volume rm $src` cleanup that follows it failed last time,
        # leaving src as an empty placeholder and dst holding the data.
        dst_empty=$(docker run --rm -v "$dst:/check:ro" "$BUSYBOX_IMAGE" \
            sh -c '[ -z "$(ls -A /check 2>/dev/null)" ] && echo yes || echo no')
        src_empty=$(docker run --rm -v "$src:/check:ro" "$BUSYBOX_IMAGE" \
            sh -c '[ -z "$(ls -A /check 2>/dev/null)" ] && echo yes || echo no')
        if [[ "$dst_empty" == "yes" ]]; then
            echo "resume: $dst exists but is empty; will reuse"
        elif [[ "$src_empty" == "yes" && "$dst_empty" == "no" ]]; then
            # Rename already completed for this volume; finalize source removal and move on.
            echo "resume: $v already renamed (source empty, destination populated); removing $src"
            assert_volume_unused "$src"
            docker volume rm "$src" >/dev/null
            continue
        else
            die "$dst already exists and contains data, and $src also has data. Both volumes hold something — inspect with 'docker volume inspect $src $dst' before removing anything; do NOT blindly 'docker volume rm $dst' or you will lose chain data."
        fi
    else
        docker volume create "$dst" >/dev/null
    fi
    assert_volume_unused "$src"
    assert_volume_unused "$dst"

    src_size=$(docker run --rm -v "$src:/from:ro" "$BUSYBOX_IMAGE" \
        du -sh /from 2>/dev/null | awk '{print $1}')
    volume_start=$(date +%s)
    printf "[%s] renaming %s (%s) -> %s ...\n" \
        "$(date +%H:%M:%S)" "$src" "${src_size:-?}" "$dst"

    # rename(2) the _data dir across siblings on the same fs, then put back an
    # empty placeholder _data on the source so `docker volume rm` succeeds
    # cleanly. Bind-mount the docker volumes root so the container can see
    # both _data dirs as a single tree (mounting each volume separately would
    # cross filesystem boundaries and force mv into a copy fallback).
    docker run --rm -v /var/lib/docker/volumes:/dvols "$BUSYBOX_IMAGE" sh -c '
        set -e
        src_data=/dvols/'"$src"'/_data
        dst_data=/dvols/'"$dst"'/_data
        [ -d "$src_data" ] || { echo "ERROR: $src_data missing" >&2; exit 1; }
        [ -d "$dst_data" ] || { echo "ERROR: $dst_data missing (docker volume create did not run)" >&2; exit 1; }
        if [ -n "$(ls -A "$dst_data" 2>/dev/null)" ]; then
            echo "ERROR: $dst_data is unexpectedly non-empty" >&2
            exit 1
        fi
        mode="$(stat -c %a "$src_data")"
        owner="$(stat -c %u:%g "$src_data")"
        rmdir "$dst_data"
        mv "$src_data" "$dst_data"
        mkdir -m "$mode" "$src_data"
        chown "$owner" "$src_data"
    '

    # Post-rename sanity check: dst must be non-empty (rename(2) silently
    # leaving the destination empty would let kaspad sync from height 0).
    if docker run --rm -v "$dst:/check:ro" "$BUSYBOX_IMAGE" \
            sh -c '[ -z "$(ls -A /check 2>/dev/null)" ]'; then
        die "post-rename: $dst is empty; aborting before .env rewrite"
    fi

    # The source's _data is now an empty placeholder; remove the source volume
    # so the migration ends with only the renamed namespace on disk.
    docker volume rm "$src" >/dev/null

    volume_end=$(date +%s)
    elapsed=$((volume_end - volume_start))
    printf "[%s] renamed %s -> %s in %dm%02ds\n" \
        "$(date +%H:%M:%S)" "$src" "$dst" "$((elapsed / 60))" "$((elapsed % 60))"
done
rename_phase_end=$(date +%s)
total_elapsed=$((rename_phase_end - rename_phase_start))
printf "[%s] all volumes renamed in %dm%02ds; rewriting .env ...\n" \
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
        printf '\n# Prefix-based Galleon ATAN path (the canonical ATAN namespace; matches the auto-constructed URL).\n'
        printf 'ATAN_IMPORT_URL=%s\n' "$LEGACY_ATAN_IMPORT_URL"
    } >> "$tmp_env"
fi
if grep -q '^IGRA_LANE_ID=' "$tmp_env"; then
    tmp_env_with_lane="$(umask 077 && mktemp .env.XXXXXX)"
    cleanup_files+=("$tmp_env_with_lane")
    sed "s|^IGRA_LANE_ID=.*$|IGRA_LANE_ID=$EXPECTED_IGRA_LANE_ID|" "$tmp_env" > "$tmp_env_with_lane"
    mv -f "$tmp_env_with_lane" "$tmp_env"
else
    {
        printf '\n# Post-KIP21 dedicated IGRA lane namespace (4 bytes / 8 lowercase hex chars, no 0x).\n'
        printf 'IGRA_LANE_ID=%s\n' "$EXPECTED_IGRA_LANE_ID"
    } >> "$tmp_env"
fi
# Sync each image-version pin from VERSIONS_FILE into .env (replace-if-present,
# append-if-absent). Pre-flight already rejected TODO/missing pins, so each
# pinned_value here is a real value.
for version_var in "${IMAGE_VERSION_VARS[@]}"; do
    pinned_value="$(read_version_pin "$VERSIONS_FILE" "$version_var")"
    tmp_env_with_ver="$(umask 077 && mktemp .env.XXXXXX)"
    cleanup_files+=("$tmp_env_with_ver")
    if grep -q "^${version_var}=" "$tmp_env"; then
        sed "s|^${version_var}=.*\$|${version_var}=${pinned_value}|" "$tmp_env" > "$tmp_env_with_ver"
    else
        cat "$tmp_env" > "$tmp_env_with_ver"
        printf '%s=%s\n' "$version_var" "$pinned_value" >> "$tmp_env_with_ver"
    fi
    mv -f "$tmp_env_with_ver" "$tmp_env"
done
mv -f "$tmp_env" .env
# Assert the credential-bearing .env stayed mode 600.
env_mode=$(stat -c %a .env 2>/dev/null || stat -f %A .env)
[[ "$env_mode" == "600" ]] || die ".env mode drifted to $env_mode after rewrite; expected 600"
trap - EXIT INT TERM
grep -qE '^NETWORK=testnet-10[[:space:]]*$' .env \
    || die "sed did not rewrite NETWORK in .env (check for trailing comment, CRLF endings, or leading whitespace)"
grep -qF "ATAN_IMPORT_URL=$LEGACY_ATAN_IMPORT_URL" .env \
    || die "failed to pin ATAN_IMPORT_URL to the legacy Galleon CDN path"
grep -qxF "IGRA_LANE_ID=$EXPECTED_IGRA_LANE_ID" .env \
    || die "failed to set IGRA_LANE_ID to $EXPECTED_IGRA_LANE_ID in .env"
for version_var in "${IMAGE_VERSION_VARS[@]}"; do
    pinned_value="$(read_version_pin "$VERSIONS_FILE" "$version_var")"
    grep -qxF "${version_var}=${pinned_value}" .env \
        || die "failed to sync ${version_var}=${pinned_value} into .env"
done
printf "[%s] .env migrated and backup written to %s\n" "$(date +%H:%M:%S)" "$backup_file"

cat <<EOF

Done. Old $SRC_PROJECT volumes have already been removed (rename is one-way).

Next steps:
  1. Bring up the renamed stack:
       docker compose --profile backend up -d --no-build
  2. Watch kaspad come up:
       docker compose logs -f kaspad

If kaspad exits with "Node database is from an older version" followed by
"Operation was rejected (), exiting..", this is a one-time post-migration
metadata upgrade. Approve it once with kaspad's noninteractive flag, then
recreate without the override:

  KASPAD_NONINTERACTIVE=true docker compose --profile backend up -d --no-build --force-recreate kaspad
  docker compose logs -f kaspad        # wait until it logs past the upgrade prompt
  docker compose --profile backend up -d --no-build --force-recreate kaspad

Full troubleshooting:
  doc/node-operations/migrate-galleon-to-testnet-10.md (sections "One-time
  kaspad DB upgrade prompt" and "Troubleshooting").
EOF
