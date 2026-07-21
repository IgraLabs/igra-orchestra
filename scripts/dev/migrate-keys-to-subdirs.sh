#!/bin/bash
# Migrate kaswallet key files from the flat single-file layout to the per-worker
# directory layout required by kaswallet's atomic keys.json save (ENG-1186).
#
#   keys/keys.kaswallet-N.json   ->   keys/kaswallet-N/keys.json
#
# The daemon now mounts the containing DIRECTORY (./keys/kaswallet-N:/app/keys)
# instead of the single file, so its atomic temp-file+rename save works (a
# rename cannot target a single-file bind mount -> EBUSY -> crash-loop).
#
# Read-only-safe, idempotent, and re-runnable: files already migrated are left
# alone; jwt.hex / keys.core.json / existing backups are never touched. Run this
# once per node BEFORE `docker compose ... up -d` with the new compose.
#
#   Usage:  scripts/dev/migrate-keys-to-subdirs.sh [--dry-run]
set -euo pipefail

DRY_RUN=0

die() { echo "ERROR: $*" >&2; exit 1; }
usage() { echo "Usage: $(basename "$0") [--dry-run]" >&2; }
run() { if [[ "$DRY_RUN" == 1 ]]; then echo "  [dry-run] $*"; else "$@"; fi; }

# Accept only --dry-run (or no args); reject anything else so a mistyped safety
# flag (e.g. --dryrun, -n, --help) never silently performs a real migration.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        -h | --help) usage; exit 0 ;;
        *) usage; die "unknown argument: $1" ;;
    esac
    shift
done

# Prevent concurrent key moves for this UID (best-effort; flock ships on the
# Linux deployment hosts but not everywhere, and the migration is idempotent).
if command -v flock >/dev/null 2>&1; then
    LOCKFILE="${TMPDIR:-/tmp}/migrate-keys-to-subdirs.$(id -u).lock"
    exec 9>"$LOCKFILE"
    flock -n 9 || die "Another key migration is already running (lockfile: $LOCKFILE)"
fi

# Run from the project root (this script lives in scripts/dev/).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
cd "$PROJECT_DIR"

[[ -d keys ]] || die "no keys/ directory in $PROJECT_DIR — run from an orchestra deployment"
[[ -f docker-compose.yml ]] || die "no docker-compose.yml in $PROJECT_DIR — is this an orchestra checkout?"

# Refuse to run while a kaswallet worker is live (running or crash-looping): the
# daemon may be writing keys, and moving a file out from under a container that
# still bind-mounts it is unsafe. Stop the frontend first. (Skipped for --dry-run.)
if [[ "$DRY_RUN" == 0 ]] && command -v docker >/dev/null 2>&1; then
    live="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -E '^kaswallet-[0-9]+$' || true)"
    if [[ -n "$live" ]]; then
        die "kaswallet worker(s) still running: $(echo "$live" | tr '\n' ' ').
Stop the frontend workers before migrating — nothing must write keys during the move —
then re-run. See doc/node-operations/migrate-keys-to-directory-mounts.md.
(Use --dry-run to preview without this check.)"
    fi
fi

echo "Migrating kaswallet keys to per-worker subdirectories in: $PROJECT_DIR/keys"
[[ "$DRY_RUN" == 1 ]] && echo "(dry run — no changes will be made)"

shopt -s nullglob
moved=0 skipped=0 total=0
for src in keys/keys.kaswallet-*.json; do
    total=$((total + 1))
    # Only migrate a real, non-symlink file. Docker's legacy single-file bind
    # syntax can create a DIRECTORY named keys.kaswallet-N.json when the host
    # file was missing; never relocate that (or a symlink) as if it were a key.
    if [[ -L "$src" || ! -f "$src" ]]; then
        echo "  ! skip (not a regular file): $src"; skipped=$((skipped + 1)); continue
    fi
    base="$(basename "$src")"
    if [[ ! "$base" =~ ^keys\.kaswallet-([0-9]+)\.json$ ]]; then
        echo "  ? skip (unrecognized name): $src"; skipped=$((skipped + 1)); continue
    fi
    idx="${BASH_REMATCH[1]}"
    dst_dir="keys/kaswallet-${idx}"
    dst="${dst_dir}/keys.json"

    if [[ -e "$dst" ]]; then
        echo "  = skip worker $idx: $dst already exists (leaving $src in place for you to reconcile)"
        skipped=$((skipped + 1)); continue
    fi

    echo "  + worker $idx: $src -> $dst"
    run bash -c "umask 077 && mkdir -p '$dst_dir'"
    run mv "$src" "$dst"
    # Best-effort perm hardening. A key written by the containerized daemon (which
    # runs as root) is root-owned on the host, so a non-root operator gets EPERM
    # on chmod. The mv already succeeded and the root daemon reads the file fine,
    # so warn and keep going rather than aborting the migration under `set -e`.
    run chmod 600 "$dst" 2>/dev/null || echo "  ! note: could not chmod 600 $dst (not owner, e.g. root-owned) — left as-is"
    run chmod 700 "$dst_dir" 2>/dev/null || echo "  ! note: could not chmod 700 $dst_dir — left as-is"
    moved=$((moved + 1))
done
shopt -u nullglob

echo
echo "Done: $moved migrated, $skipped skipped, $total flat key file(s) found."
if [[ "$total" == 0 ]]; then
    echo "Nothing to migrate (already on the per-worker layout, or no keys generated yet)."
fi
if [[ "$moved" -gt 0 && "$DRY_RUN" == 0 ]]; then
    echo
    echo "Next: recreate the affected services with the directory-mount compose, e.g."
    echo "  docker compose --profile <frontend-wN> up -d"
fi
