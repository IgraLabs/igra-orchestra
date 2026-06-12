# Galleon → testnet-10 Migration

## Who this is for

If your orchestra `.env` has `NETWORK=testnet` and you have a synced Galleon
kaspad (IBD: 100%), run this migration once to move to the new uniform
`NETWORK=testnet-10` schema **without losing your IBD state**.

If you're starting fresh and don't have a synced node, skip this guide and
use `./scripts/setup-galleon-testnet.sh` directly — the template already ships
`NETWORK=testnet-10`.

## What the migration does

- **Renames the compose project** from `igra-orchestra-testnet` to
  `igra-orchestra-testnet-10` by atomically moving each volume's `_data`
  directory under `/var/lib/docker/volumes/` on the docker host (a `rename(2)`
  syscall — metadata-only, instant, regardless of how large the volume is).
  After the rename, the old `igra-orchestra-testnet_*` volumes are removed;
  the migration is one-way.
- **Rewrites `.env`** atomically: `NETWORK=testnet` → `NETWORK=testnet-10`,
  pins `ATAN_IMPORT_URL` to the canonical prefix-based Galleon path
  `https://dyehoijgeqfp8.cloudfront.net/testnet-10/97b4/index.pb` (the same URL
  the entrypoint now auto-constructs from `NETWORK`/`TX_ID_PREFIX`), sets
  `IGRA_LANE_ID=97b10000` (post-KIP21 dedicated IGRA lane namespace; 4 bytes /
  8 lowercase hex chars, no `0x`), and
  **syncs every image-version pin** from
  `versions.galleon-testnet.env` into `.env` (`KASPAD_VERSION`,
  `RETH_VERSION`, `RPC_PROVIDER_VERSION`, `KASWALLET_VERSION`,
  `NODE_HEALTH_CHECK_VERSION`, `ATAN_UPLOADER_VERSION`) so the next
  `docker compose up` pulls the right tags without a separate version-sync
  step.
- **Writes a timestamped backup of `.env`**:
  `.env.backup.pre-testnet-10.YYYYMMDD_HHMMSS` (mode 600) is created before
  the rewrite so the `.env` change is reversible (the volume rename is not).

The underlying reason for the rename: kaspad now uses a uniform slug schema
`<family>[-<suffix>]` so that multiple Kaspa networks can coexist on one host
with isolated project names, volume namespaces, ATAN paths, and logging tags.

### Peer-discovery change (heads-up)

The new compose drops `--nodnsseed` from the kaspad entrypoint. Galleon now
discovers peers via the built-in DNS seed list **in addition** to any
`KASPAD_ADD_PEER` you have configured. For most operators this is a benign
improvement. If you need the old isolation profile (Galleon-only peers via a
fixed `KASPAD_ADD_PEER`), keep `KASPAD_ADD_PEER=65.109.78.124` set; do not
depend on `--nodnsseed` being added by default.

## Supported hosts

The migration script runs cleanly on **Linux** (Ubuntu/Debian/Fedora/etc.) and
**macOS**. macOS operators need one external dependency:

```bash
brew install flock
```

Without it, the script aborts at the first lock step with
`flock: command not found`.

## Prerequisites

- The PR branch (or post-merge `main`) is checked out in your Galleon
  deployment directory so it has the current
  `scripts/dev/migrate-galleon-to-testnet-10.sh`, `scripts/lib/parse-network-slug.sh`,
  `docker-compose.yml`, and `docker-compose.atan.yml`.
- `docker compose` v2 plugin available (`docker compose version`).
- Your `.env` contains the canonical Galleon values. The script refuses to
  run if any of these diverges — that's a safety feature.
  ```
  NETWORK=testnet
  IGRA_CHAIN_ID=38836
  TX_ID_PREFIX=97b4
  GENESIS_BLOCK_HASH=0x9816ede09a09a8e89c3c0158db66c3ea9ee16a81dfc7f2b80f7f38be5b1c28f2
  ```
- The Docker volume `igra-orchestra-testnet_kaspad_data` exists with real
  chain data. Check with:
  ```bash
  docker volume ls --filter 'name=igra-orchestra-testnet_'
  ```
- The migration is **one-way and renames in place**, so it needs no extra
  disk space and finishes in seconds. There is no copy phase to wait on.

## Run the migration

```bash
cd /path/to/your/igra-orchestra
git pull            # ensure you have the PR-branch tree
./scripts/dev/migrate-galleon-to-testnet-10.sh
```

Before the confirmation prompt the script prints a pre-flight summary so you
can confirm which volumes are about to be moved:

```
Source volumes to rename:
  igra-orchestra-testnet_kaspad_data              48.2G
  igra-orchestra-testnet_reth_data                12.7G
  igra-orchestra-testnet_traefik_certs            120K
About to:
  1. Stop projects igra-orchestra-testnet and igra-orchestra-testnet-10 (across all profiles)
  2. Rename volumes ... (old volumes are removed)
  3. Rewrite .env: NETWORK=testnet -> NETWORK=testnet-10
  4. Pin ATAN_IMPORT_URL to the legacy published Galleon CDN path
  5. Set IGRA_LANE_ID=97b10000 (post-KIP21 dedicated lane)
This is one-way: once the rename completes, the old volumes no longer exist.
Proceed? [y/N]:
```

After you confirm with `y`, expected output (paraphrased):

```
[+] Running N/N (compose down for igra-orchestra-testnet)
WARN[0000] Warning: No resource found to remove for project "igra-orchestra-testnet-10".
[14:02:11] renaming igra-orchestra-testnet_kaspad_data (48.2G) -> igra-orchestra-testnet-10_kaspad_data ...
[14:02:11] renamed igra-orchestra-testnet_kaspad_data -> igra-orchestra-testnet-10_kaspad_data in 0m00s
[14:02:11] renaming igra-orchestra-testnet_reth_data (12.7G) -> igra-orchestra-testnet-10_reth_data ...
[14:02:11] renamed igra-orchestra-testnet_reth_data -> igra-orchestra-testnet-10_reth_data in 0m00s
[14:02:11] renaming igra-orchestra-testnet_traefik_certs (120K) -> igra-orchestra-testnet-10_traefik_certs ...
[14:02:11] renamed igra-orchestra-testnet_traefik_certs -> igra-orchestra-testnet-10_traefik_certs in 0m00s
[14:02:11] all volumes renamed in 0m00s; rewriting .env ...
[14:02:11] .env migrated and backup written to .env.backup.pre-testnet-10.20260512_140211
Done. Bring the new project up: docker compose --profile backend up -d --no-build
Old igra-orchestra-testnet volumes have already been removed (rename is one-way).
```

The `WARN` about `igra-orchestra-testnet-10` is benign — the destination
project doesn't exist yet. The whole rename phase completes in seconds
because no data is moved; only the volume directory metadata changes.

## Verify

After the script completes:

```bash
grep '^NETWORK=' .env                                       # NETWORK=testnet-10
grep '^ATAN_IMPORT_URL=' .env                               # legacy CloudFront URL
grep '^IGRA_LANE_ID=' .env                                  # IGRA_LANE_ID=97b10000
grep -E '^(KASPAD|RETH|RPC_PROVIDER|KASWALLET|NODE_HEALTH_CHECK|ATAN_UPLOADER)_VERSION=' .env \
    | sort                                                  # matches versions.galleon-testnet.env
diff <(grep -E '^[A-Z_]+_VERSION=' versions.galleon-testnet.env | sort) \
     <(grep -E '^[A-Z_]+_VERSION=' .env | sort)             # should print nothing
docker volume ls --filter 'name=igra-orchestra-testnet'     # only -10 namespace present
```

Bring the new stack up:

```bash
docker compose --profile backend up -d --no-build
docker compose logs -f kaspad
```

In the kaspad log, look for:

- Startup banner reporting `testnet-10` (i.e. `--testnet --netsuffix=10`
  applied by the slug parser) — **not** an `Unknown KASPA_FAMILY=...` or
  `unknown argument --testnet-10` error.
- IBD resuming from your previous height (the `IBD: 100%` line should appear
  quickly) — **not** a fresh sync from height 0.

### One-time kaspad DB upgrade prompt

If kaspad exits with `Node database is from an older version` followed by
`Operation was rejected (), exiting..`, start it once with kaspad's
noninteractive approval enabled:

```bash
KASPAD_NONINTERACTIVE=true docker compose --profile backend up -d --no-build --force-recreate kaspad
docker compose logs -f kaspad
```

After kaspad starts past the DB upgrade prompt, recreate it without the
temporary approval:

```bash
docker compose --profile backend up -d --no-build --force-recreate kaspad
docker compose logs -f kaspad
```

`KASPAD_NONINTERACTIVE=true` maps to kaspad `--yes`; use it only for this known
safe older-version metadata upgrade and do not leave it in `.env`.
`docker compose --yes` is unrelated because it answers Docker Compose prompts,
not kaspad prompts.

## Rollback

The volume rename is one-way: by the time the script reaches the `.env`
rewrite, the old `igra-orchestra-testnet_*` volumes are already gone. There
is no byte-for-byte rollback. What's still recoverable:

- **`.env`**: restore from the `.env.backup.pre-testnet-10.*` file the script
  wrote before the rewrite. Keep this file indefinitely; it's the only
  recovery path for `NETWORK`, `ATAN_IMPORT_URL`, and `IGRA_LANE_ID`.
- **Compose files**: `git checkout <your-previous-branch>` to put back the
  old `docker-compose.yml`. The new volumes are named
  `igra-orchestra-testnet-10_*` and won't be picked up by the old compose
  project, so a pre-migration compose would start from a fresh sync rather
  than from the renamed data.

If the migration aborted partway (for example before the rename step ran on
all volumes) the original volume namespace is intact and you can re-run the
script after fixing whatever caused the abort.

## Troubleshooting

| Error | Meaning | Fix |
|---|---|---|
| `flock: command not found` | macOS host without `flock` | `brew install flock` |
| `Docker Compose v2 plugin not available` | Operator still on legacy `docker-compose` v1 | Install the Docker Compose v2 plugin |
| `.env NETWORK is not 'testnet'` | Already migrated or different network | If `NETWORK=testnet-10` already, the migration is done — proceed to bring-up |
| `.env IGRA_CHAIN_ID is not the expected Galleon value '38836'` | Custom or stale chain identity | Restore Galleon defaults in `.env` (keep your node-specific overrides) |
| `igra-orchestra-testnet_kaspad_data does not exist` | No chain volume to migrate (never ran Galleon backend, or volume already removed) | Use `./scripts/setup-galleon-testnet.sh` for a fresh start instead |
| `<dst> already exists and contains data` | A previous partial run left data in the destination | Inspect with `docker volume inspect …`; if not needed, `docker volume rm <dst>` and re-run |
| `post-rename: <dst> is empty; aborting before .env rewrite` | The rename `mv` reported success but the destination is empty (filesystem bug or non-local volume driver) | Restore the volume manually from any backup you have; do not bring the new stack up until `<dst>/_data` actually contains the chain data. Open an issue with your docker driver/storage details |
| `sh: /app/parse-network-slug.sh: not found` at kaspad startup | The Galleon checkout doesn't have the new `docker-compose.yml` / `parse-network-slug.sh` | `git pull` (or copy the files) in the deployment directory and re-run `docker compose up` |
| `Node database is from an older version` then `Operation was rejected (), exiting..` | Kaspad needs a one-time DB metadata upgrade but cannot prompt interactively inside Docker | Pull a compose version that passes `KASPAD_NONINTERACTIVE`, then run the one-time kaspad DB upgrade commands above |
