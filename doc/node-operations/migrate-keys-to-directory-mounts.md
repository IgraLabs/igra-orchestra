# Migrate kaswallet keys to per-worker directory mounts

!!! note "Why this is needed"
    kaswallet **3.0.3** (and later) writes `keys.json` **atomically** (write a temp file, then
    `rename` it over the target) so an interrupted save can never truncate your
    key file. A `rename` **cannot** replace a **single-file bind mount** — it
    fails with `EBUSY`, the daemon's sync loop panics, and the container
    **crash-loops**. Older deployments mount the key file directly
    (`./keys/keys.kaswallet-N.json:/app/keys.json`). This one-time migration
    switches each worker to a **directory** mount (`./keys/kaswallet-N:/app/keys`)
    so the atomic save works. **No keys are lost** by the old behavior — the
    atomic save fails safely — but the affected workers do not run until you
    migrate.

## TL;DR

Run this once per node, **on the node**, from your orchestra checkout:

```bash
cd /path/to/your/igra-orchestra

# 1. Get the new compose + migration script (ships on main)
git fetch origin && git checkout main && git pull --ff-only

# 2. Stop the workers so nothing writes keys during the move
docker ps --format '{{.Names}}' | grep -E '^(kaswallet|rpc-provider)-[0-9]+$' | xargs -r docker stop

# 3. Migrate existing keys into per-worker directories (idempotent; preview first)
./scripts/dev/migrate-keys-to-subdirs.sh --dry-run
./scripts/dev/migrate-keys-to-subdirs.sh

# 4. Confirm NO flat key files remain, THEN recreate the workers
ls keys/keys.kaswallet-*.json 2>/dev/null && echo "STOP: still flat — re-run step 3" || echo "all migrated ✓"
docker compose --profile backend --profile frontend-wN up -d   # your normal profiles

# 5. Verify
docker compose ps                                              # kaswallet-* Up (healthy), not restarting
docker compose logs --since 3m $(docker compose ps --services | grep '^kaswallet-') \
  | grep -iE "EBUSY|persist keys|panic" && echo "still failing" || echo "no EBUSY ✓"
```

> **Order matters — stop the frontend, migrate, _then_ `up -d`.** Don't migrate
> while a kaswallet worker is running (it may be writing keys — the migration
> script will refuse), and don't `up -d` while any key is still flat, or Docker
> auto-creates an **empty, root-owned** `keys/kaswallet-N/` directory that leaves
> the worker keyless and **blocks the migration** (a non-root operator can't
> `mv` into it). See [Troubleshooting](#troubleshooting).

## Who this is for

Any existing operator whose `keys/` directory contains flat
`keys.kaswallet-0.json … keys.kaswallet-19.json` files and who is moving to the
kaswallet **3.0.3 atomic-save** image (i.e. `KASWALLET_VERSION=3.0.3` or later, the default on `main`). Fresh installs via
`./scripts/setup-mainnet.sh` / `setup-galleon-testnet.sh` already generate the
new layout — skip this guide.

## What changes

| | Before | After |
|---|---|---|
| Host layout | `keys/keys.kaswallet-N.json` | `keys/kaswallet-N/keys.json` |
| Compose mount | `./keys/keys.kaswallet-N.json:/app/keys.json` | `./keys/kaswallet-N:/app/keys` |
| Daemon arg | `--keys /app/keys.json` | `--keys /app/keys/keys.json` |

Each worker still sees **only its own key** (its own subdirectory). Nothing else
changes; kaspad, reth, traefik, `.env`, and volumes are untouched.

## Prerequisites

- The node's checkout is on `main` with this change (step 1 above).
- You run the migration as the **owner of the `keys/` directory** (typically
  `devnet`). You do **not** need root; the script does not require it.
- The frontend workers are stopped during the migration and recreated at the end
  (a brief kaswallet/rpc-provider downtime).

## Step-by-step

1. **Pull the update** (step 1 above). This brings the new `docker-compose.yml`,
   `scripts/dev/migrate-keys-to-subdirs.sh`, and generator changes.

2. **Stop the frontend workers** so nothing writes keys during the move — the
   migration script **refuses to run** while any `kaswallet-N` container is up:
   ```bash
   docker ps --format '{{.Names}}' | grep -E '^(kaswallet|rpc-provider)-[0-9]+$' | xargs -r docker stop
   ```

3. **Preview, then migrate.** `--dry-run` prints the moves without changing
   anything; the real run moves each `keys/keys.kaswallet-N.json` →
   `keys/kaswallet-N/keys.json`. It is **idempotent** and **re-runnable** — an
   already-migrated worker is skipped, so it is safe to run again after any
   interruption. `jwt.hex`, `keys.core.json`, and `keys/backup.*/` are never
   touched.

   You may see lines like:
   ```
   ! note: could not chmod 600 keys/kaswallet-1/keys.json (not owner, e.g. root-owned) — left as-is
   ```
   This is **expected and harmless**: a key that the containerized daemon (which
   runs as root) previously rewrote is root-owned on the host, so the operator
   can't tighten its permissions. The file was still moved into place, and the
   root daemon reads it fine.

4. **Confirm no flat files remain**, then recreate the workers with your normal
   profiles (`docker compose --profile … up -d`). Compose only recreates the
   services whose mount changed (the kaswallets and their paired rpc-providers).

5. **Verify** (see below).

## Verification

```bash
# per-worker directories exist, no flat files left:
ls -d keys/kaswallet-*/ && (ls keys/keys.kaswallet-*.json 2>/dev/null && echo "STILL FLAT" || echo "ok ✓")

# containers healthy, not restarting:
docker compose ps

# no EBUSY / persist errors in the last few minutes:
docker compose logs --since 5m $(docker compose ps --services | grep '^kaswallet-') \
  | grep -iE "EBUSY|persist keys|panic" || echo "clean ✓"
```
A healthy worker shows `Up (healthy)` and its paired `rpc-provider-N` stops
logging `[watch-dependencies] kaswallet is unavailable`.

## Troubleshooting

- **`! note: could not chmod …` warnings** — expected for root-owned keys (see
  step 2). Not an error; the migration continues and the key is usable.

- **The migration stopped partway** (older script, or an unrelated error) — just
  run it again. It skips already-migrated workers and finishes the rest.

- **A worker fails to load a key after `up -d`** (`KeyFileNotFound`, or the dir
  is empty) — you almost certainly recreated **before** finishing the migration,
  so Docker created an empty `keys/kaswallet-N/` owned by root. Recover:
  ```bash
  docker compose stop kaswallet-N rpc-provider-N
  sudo rmdir keys/kaswallet-N            # only if empty
  ./scripts/dev/migrate-keys-to-subdirs.sh   # moves the flat key in now
  docker compose --profile <your profiles> up -d
  ```

- **`setup-*.sh` refuses to run** with "Found legacy flat key files …" — that is
  the intended guard: it prevents generating a *new* wallet identity over your
  existing key. Run this migration first, then re-run setup.

- **Still crash-looping with `EBUSY`** — a worker is still on a single-file
  mount. Confirm `git pull` landed the new `docker-compose.yml` (`grep -n
  '/app/keys' docker-compose.yml` should show `./keys/kaswallet-N:/app/keys` and
  `--keys /app/keys/keys.json`), then recreate that worker.

## Rollback

The directory mount is required by the atomic-save image, so rolling back the
mount means also rolling back the kaswallet image. To revert: `git checkout` the
previous `docker-compose.yml`, move each `keys/kaswallet-N/keys.json` back to
`keys/keys.kaswallet-N.json`, pin `KASWALLET_VERSION` to the pre-atomic image in
`.env`, and `docker compose … up -d`. Reverting the mount **without** reverting
the image reintroduces the `EBUSY` crash-loop.

!!! warning "The pre-atomic (2.x) image is no longer usable"
    This rollback path is historical. The compose entrypoint now passes
    `--subnetwork-id` unconditionally, which a 2.x kaswallet rejects
    (`unexpected argument`) — it will crash-loop rather than start. A 2.x wallet
    would also emit v0 transactions that post-Toccata kaspad rejects, so the
    rollback only works together with the older `docker-compose.yml` you check
    out in the same step.
