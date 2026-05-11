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
  `igra-orchestra-testnet-10` by copying the Docker volumes
  (`kaspad_data`, `reth_data`, `traefik_certs`) into the new namespace.
  The old volumes are left in place as a backup until you remove them
  manually.
- **Rewrites `.env`** atomically: `NETWORK=testnet` → `NETWORK=testnet-10`,
  and pins `ATAN_IMPORT_URL` to the legacy published
  `https://dyehoijgeqfp8.cloudfront.net/testnet/97b4/index.pb` so ATAN keeps
  importing from the existing CDN path until the `/testnet-10/97b4/index.pb`
  object is published.
- **Writes a timestamped backup**: `.env.backup.pre-testnet-10.YYYYMMDD_HHMMSS`
  (mode 600) is created before the rewrite so the operation is reversible.

The underlying reason for the rename: kaspad now uses a uniform slug schema
`<family>[-<suffix>]` so that Galleon (`testnet-10`) and Frigate (`testnet-12`)
can coexist on one host with isolated project names, volume namespaces, ATAN
paths, and logging tags.

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
- Roughly **1.2× free disk space** on the Docker volume root — the script
  copies ~50 GB of kaspad data and keeps both copies for the rollback window.

## Run the migration

```bash
cd /path/to/your/igra-orchestra
git pull            # ensure you have the PR-branch tree
./scripts/dev/migrate-galleon-to-testnet-10.sh
```

Before the confirmation prompt the script prints a pre-flight summary of the
source volumes and the total bytes it's about to copy, so you can verify free
disk space:

```
Source volumes to copy:
  igra-orchestra-testnet_kaspad_data              48.2G
  igra-orchestra-testnet_reth_data                12.7G
  igra-orchestra-testnet_traefik_certs            120K
Total to copy: ~62300 MB (host needs >=1.2x free on the docker volume root)
About to:
  1. Stop projects igra-orchestra-testnet and igra-orchestra-testnet-10 (across all profiles)
  2. Copy volumes ...
  ...
Proceed? [y/N]:
```

After you confirm with `y`, expected output during the copy (paraphrased):

```
[+] Running N/N (compose down for igra-orchestra-testnet)
WARN[0000] Warning: No resource found to remove for project "igra-orchestra-testnet-10".
[14:02:11] copying igra-orchestra-testnet_kaspad_data (48.2G) -> igra-orchestra-testnet-10_kaspad_data ...
    ... 5.4G copied so far
    ... 11.1G copied so far
    ... 18.0G copied so far
    ... (heartbeat every 30s)
[14:17:54] copied  igra-orchestra-testnet_kaspad_data -> igra-orchestra-testnet-10_kaspad_data in 15m43s
[14:17:54] copying igra-orchestra-testnet_reth_data (12.7G) -> igra-orchestra-testnet-10_reth_data ...
    ... 4.8G copied so far
    ...
[14:22:18] copied  igra-orchestra-testnet_reth_data -> igra-orchestra-testnet-10_reth_data in 4m24s
[14:22:18] copying igra-orchestra-testnet_traefik_certs (120K) -> igra-orchestra-testnet-10_traefik_certs ...
[14:22:18] copied  igra-orchestra-testnet_traefik_certs -> igra-orchestra-testnet-10_traefik_certs in 0m00s
[14:22:18] all volumes copied in 20m07s; rewriting .env ...
[14:22:18] .env migrated and backup written to .env.backup.pre-testnet-10.20260512_142218
Done. Bring the new project up: docker compose --profile backend up -d --no-build
After verifying sync, remove old volumes with: docker volume rm ...
```

The `WARN` about `igra-orchestra-testnet-10` is benign — the destination
project doesn't exist yet. The `... X copied so far` lines appear every 30
seconds while a volume copy is in flight; they confirm the migration is
actively making progress.

Allow roughly **1 minute per 5–10 GB** of kaspad data on local SSD. A fully
synced Galleon node (~60 GB of chain data) typically completes in 15–30
minutes end-to-end.

### Silencing the heartbeat (`MIGRATE_QUIET=1`)

If your shell or log collector doesn't tolerate the `... X copied so far`
output, run the script with `MIGRATE_QUIET=1`:

```bash
MIGRATE_QUIET=1 ./scripts/dev/migrate-galleon-to-testnet-10.sh
```

The per-volume start/end markers and the timing totals still print; only the
30-second heartbeat is suppressed.

## Verify

After the script completes:

```bash
grep '^NETWORK=' .env                                       # NETWORK=testnet-10
grep '^ATAN_IMPORT_URL=' .env                               # legacy CloudFront URL
docker volume ls --filter 'name=igra-orchestra-testnet'     # old + new namespaces present
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

If the new stack doesn't come up cleanly:

```bash
docker compose -p igra-orchestra-testnet-10 --profile '*' down
cp "$(ls -t .env.backup.pre-testnet-10.* | head -1)" .env
git checkout <your-previous-branch>      # restore old compose files
docker compose --profile backend up -d --no-build
```

The original `igra-orchestra-testnet_*` volumes were untouched by the
migration, so the Galleon stack returns byte-for-byte to its pre-migration
state.

## Reclaim disk

After ~1 week of stable `testnet-10` operation, remove the old volumes:

```bash
docker volume rm igra-orchestra-testnet_kaspad_data \
                 igra-orchestra-testnet_reth_data \
                 igra-orchestra-testnet_traefik_certs
```

Keep the `.env.backup.pre-testnet-10.*` file indefinitely — it's small and
the only rollback path for `.env`.

## Troubleshooting

| Error | Meaning | Fix |
|---|---|---|
| `flock: command not found` | macOS host without `flock` | `brew install flock` |
| `Docker Compose v2 plugin not available` | Operator still on legacy `docker-compose` v1 | Install the Docker Compose v2 plugin |
| `.env NETWORK is not 'testnet'` | Already migrated or different network | If `NETWORK=testnet-10` already, the migration is done — proceed to bring-up |
| `.env IGRA_CHAIN_ID is not the expected Galleon value '38836'` | Custom or stale chain identity | Restore Galleon defaults in `.env` (keep your node-specific overrides) |
| `igra-orchestra-testnet_kaspad_data does not exist` | No chain volume to migrate (never ran Galleon backend, or volume already removed) | Use `./scripts/setup-galleon-testnet.sh` for a fresh start instead |
| `<dst> already exists and contains data` | A previous partial run left data in the destination | Inspect with `docker volume inspect …`; if not needed, `docker volume rm <dst>` and re-run |
| `sh: /app/parse-network-slug.sh: not found` at kaspad startup | The Galleon checkout doesn't have the new `docker-compose.yml` / `parse-network-slug.sh` | `git pull` (or copy the files) in the deployment directory and re-run `docker compose up` |
| `Node database is from an older version` then `Operation was rejected (), exiting..` | Kaspad needs a one-time DB metadata upgrade but cannot prompt interactively inside Docker | Pull a compose version that passes `KASPAD_NONINTERACTIVE`, then run the one-time kaspad DB upgrade commands above |
