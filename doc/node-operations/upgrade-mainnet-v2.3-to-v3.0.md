# Toccata Upgrade — Part One: Mainnet v2.3 → v3.0

!!! note "A two-part upgrade"
    The mainnet move to v3.0 is split by the **Toccata (KIP-21) hardfork**.
    **Part One (this guide)** brings the backend (kaspad/reth) to the current pins now, while the
    fork is still inactive — the workers stay on 2.3 and keep emitting native (v0) transactions.
    **Part Two** brings the `rpc-provider`/`kaswallet` workers to v3.0 once Toccata activates;
    see [Part Two: after the Toccata switch](#part-two-after-the-toccata-switch).

!!! danger "Moving reth to the 2.5 line requires an execution-layer resync"
    This guide reconciles `.env` only — it never touches Docker volumes. But once
    `RETH_VERSION` points at the `2.5.1-igra.1` line, reth cannot open a database written
    by the old 1.9.3 (`3.0`) image: the backend comes up with
    `container execution-layer is unhealthy` and kaspad never starts.

    You must additionally drop the reth volume and resync — budget 12+ hours. See
    [Reth Upgrade: 1.9.3 → 2.5.1](upgrade-reth-1.9-to-2.5.md). Your kaspad data is
    unaffected.

## TL;DR

Existing **mainnet** v2.3 node → v3.0, keeping your synced **kaspad** data. This guide
itself is an `.env` reconcile — **no volume rename**, and the script never touches volumes
— but if the reth pin moves to the `2.5.1-igra.1` line you must also
[drop the reth volume and resync](upgrade-reth-1.9-to-2.5.md) (12+ hours). Backend
(kaspad/reth) moves to the pins in `versions.mainnet.env` now; the frontend
workers (`rpc-provider`/`kaswallet`) **stay on 2.3 until the Toccata/KIP-21 fork
activates** on mainnet.

```bash
# 1. Pull v3.0 code (ships on main)
cd /path/to/your/igra-orchestra
git fetch origin && git checkout main && git pull --ff-only
#    If config/traefik/dynamic.yml shows as `deleted` or the pull hits "Permission denied":
#    sudo chown -R "$USER:$USER" config/traefik/ && git restore config/traefik/dynamic.yml

# 2. Reconcile .env (backs up, upserts IGRA_LANE_ID + version pins, validates)
./scripts/upgrade-mainnet-v2.3-to-v3.0.sh        # add -y to skip the confirmation prompt

# 3. Validate
docker compose config -q                          # must exit cleanly

# 4. First backend start needs the noninteractive flag (one-time kaspad DB-upgrade prompt)
KASPAD_NONINTERACTIVE=true docker compose --profile backend up -d --no-build
docker compose logs -f kaspad                     # wait until it's past the upgrade and syncing
docker compose --profile backend up -d --no-build --force-recreate kaspad  # drop the override
```

**Do not recreate the frontend workers in this phase** — they keep emitting native
(v0) transactions, which is what pre-Toccata mainnet expects. After the fork, set
`RPC_PROVIDER_VERSION`/`KASWALLET_VERSION` to `3.0` and recreate the worker profile;
see [Part Two: after the Toccata switch](#part-two-after-the-toccata-switch).

Full rationale, prerequisites, verification, rollback, and troubleshooting follow below.

## Who this is for

If you run an existing IGRA Orchestra **mainnet** deployment (`NETWORK=mainnet`)
on the v2.3 line and want to move it to v3.0 **without re-syncing kaspad**, run this once.
(The reth database is a separate matter — see the resync note above.)

If you're starting fresh and don't have a synced node, skip this guide and use
`./scripts/setup-mainnet.sh` directly — it already applies the current
`versions.mainnet.env` pins.

## What the upgrade does

The "version" here is the orchestra **release line** (v3.0, which lands on
`main`). Pulling `main` brings the new `docker-compose.yml`, the new
`config/traefik/dynamic.yml` file-provider middleware, and updated entrypoints —
but it does **not** touch your `.env`, which is gitignored and carries your
image-version pins. The real upgrade work is reconciling `.env`:

- **Adds `IGRA_LANE_ID=97b10000`** — the post-KIP21 dedicated IGRA lane
  namespace (4 bytes / 8 lowercase hex chars, no `0x`), shared across all
  networks. The v3.0 compose **refuses to render** without it
  (`${IGRA_LANE_ID:?...}`), and kaspad receives it as `--igra-lane-id`.
  (kaswallet also receives it as `--subnetwork-id`, but only once you bring the
  workers up after the Toccata switch — see below.)
- **Ensures `TX_ID_PREFIX=97b1`** — now also required (`${TX_ID_PREFIX:?...}`).
  A mainnet v2.3 `.env` normally already has it; it is added only if missing.
- **Ensures `SERVICE_RESTART_POLICY=unless-stopped`** — added if missing so
  Traefik and friends self-heal after a boot-time race.
- **Bumps kaspad and reth to the current backend pins** — `KASPAD_VERSION` goes
  `2.3 → 2.0.1-igra.1` and `RETH_VERSION` goes `2.3 → 2.5.1-igra.1`. These
  numbers look like a downgrade but are not: kaspad/reth moved to the
  `v<upstream>-igra.<n>` scheme (ENG-1243), where the version tracks the
  upstream rusty-kaspa/reth base and `.<n>` is the IGRA revision on it. They
  supersede the 3.0 line this guide originally shipped.
  **`RPC_PROVIDER_VERSION` and `KASWALLET_VERSION` stay at `2.3`**
  for now. `NODE_HEALTH_CHECK_VERSION` and `ATAN_UPLOADER_VERSION` are not part
  of this cutover at all — they track whatever `versions.mainnet.env` pins.
  kaspad is Toccata-aware but the fork is **not yet active** on mainnet, so
  the network still uses native (v0) transactions. The rpc-provider/kaswallet
  bump is deferred to [Part Two: after the Toccata switch](#part-two-after-the-toccata-switch) — the
  v3.0 frontend emits lane/subnetwork (v1) transactions that mainnet rejects
  before the fork.

The upgrade keeps `NETWORK=mainnet` and the `igra-orchestra-mainnet` compose
project, so your existing volumes are reused as-is — **no volume rename, no
re-sync**.

The ATAN import URL now auto-constructs as
`{CDN_BASE_URL}/mainnet/97b1/index.pb`. If your `.env` pins `ATAN_IMPORT_URL`
explicitly, the script leaves it untouched but flags it so you can verify or
remove it.

## Prerequisites

- The deployment directory is on the latest `main` checkout (after v3.0 is merged
  into `main`) so it has the new `docker-compose.yml`,
  `config/traefik/dynamic.yml`, and `scripts/upgrade-mainnet-v2.3-to-v3.0.sh`.
- `docker compose` v2 plugin available (`docker compose version`).
- Your `.env` is a real mainnet config (`NETWORK=mainnet`,
  `IGRA_CHAIN_ID=38833`). The script refuses to run otherwise — that's a safety
  feature.
- The reconcile is `.env`-only and reversible (a timestamped backup is written),
  so it needs no extra disk and finishes in seconds.

## Run the upgrade

### 1. Pull the latest code

The v3.0 changes ship on `main`. From your deployment directory:

```bash
cd /path/to/your/igra-orchestra
git fetch origin
git checkout main        # or whatever ref your deployment tracks
git pull --ff-only
```

**If the pull leaves `config/traefik/dynamic.yml` showing as `deleted`** in
`git status` (or aborts with `unable to create file config/traefik/dynamic.yml:
Permission denied`), the Traefik container — which runs as root and bind-mounts
`./config/traefik` — has left that directory root-owned, so Git (running as your
login user) can't write the newly tracked file into it. Restore ownership to your
user and check the file back out, then re-run the pull if it had aborted:

```bash
sudo chown -R "$USER:$USER" config/traefik/
git restore config/traefik/dynamic.yml
```

### 2. Reconcile `.env`

```bash
./scripts/upgrade-mainnet-v2.3-to-v3.0.sh
```

The script prints a pre-flight summary of every change (old → new) and asks for
confirmation before writing. It backs up `.env` to
`.env.backup.pre-v3.0.YYYYMMDD_HHMMSS` (mode 600), upserts the variables above,
syncs the image pins from `versions.mainnet.env`, and finally runs
`docker compose config -q` to prove the required variables are present. Pass
`-y` to skip the prompt for unattended runs.

<details>
<summary>Prefer to edit <code>.env</code> by hand?</summary>

Set these in `.env` (the values are mainnet canonical):

| Variable | Set to |
|---|---|
| `IGRA_LANE_ID` | `97b10000` |
| `TX_ID_PREFIX` | `97b1` (if not already set) |
| `SERVICE_RESTART_POLICY` | `unless-stopped` (if not already set) |
| `KASPAD_VERSION` | `2.0.1-igra.1` |
| `RETH_VERSION` | `2.5.1-igra.1` |
| `KASWALLET_VERSION` | `2.3` (unchanged until after Toccata) |
| `RPC_PROVIDER_VERSION` | `2.3` (unchanged until after Toccata) |
| `NODE_HEALTH_CHECK_VERSION` | `2.4` |
| `ATAN_UPLOADER_VERSION` | `2.1` |

</details>

### 3. Validate and bring the stack up

```bash
docker compose config -q     # must exit cleanly (no "IGRA_LANE_ID must be set" error)
```

**The first backend start needs `KASPAD_NONINTERACTIVE=true`.** The kaspad image
bump always triggers a one-time DB metadata upgrade that prompts `Do you confirm?
(y/n)`; inside Docker there is no TTY to answer it, so kaspad rejects it and
crash-loops (`Operation was rejected (), exiting..`). Approve it noninteractively
on the first start:

```bash
KASPAD_NONINTERACTIVE=true docker compose --profile backend up -d --no-build
docker compose logs -f kaspad        # wait until it logs past the upgrade and starts syncing
```

Once kaspad is past the upgrade, recreate it without the override so the flag is
not left set:

```bash
docker compose --profile backend up -d --no-build --force-recreate kaspad
```

**Do not recreate the frontend workers in this phase.** `rpc-provider` and
`kaswallet` stay on 2.3 and keep emitting native (v0) transactions, which is what
pre-Toccata mainnet expects. Leave your existing worker containers running — only
the `backend` profile is recreated now. You'll upgrade the workers in
[Part Two: after the Toccata switch](#part-two-after-the-toccata-switch).

### About `KASPAD_NONINTERACTIVE`

`KASPAD_NONINTERACTIVE=true` maps to kaspad `--yes`, which answers the
`Do you confirm? (y/n)` DB-upgrade prompt shown on the first start. It is safe for
this known older-version metadata upgrade; pass it only on that first start (as in
step 3) and **do not** leave it in `.env`. Without it, kaspad logs
`Operation was rejected (), exiting..` and crash-loops until you re-run the first
start with the flag. See
[troubleshooting/kaspad-db-upgrade.md](../troubleshooting/kaspad-db-upgrade.md)
for detail.

## Verify

```bash
grep '^IGRA_LANE_ID=' .env                        # IGRA_LANE_ID=97b10000
grep -E '^(KASPAD|RETH)_VERSION=' .env            # must match versions.mainnet.env
grep -E '^(RPC_PROVIDER|KASWALLET)_VERSION=' .env  # both 2.3 (until Toccata)
docker compose config -q && echo "compose OK"     # required vars present
docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.State}}' \
  kaspad execution-layer                          # image AND state, not just the pin
```

In the running stack, confirm:

- **kaspad** logs its startup banner and **IBD resumes from your previous
  height** (not a fresh sync from 0).
- `docker compose ps` shows `kaspad` and `execution-layer` **running / healthy**
  on the new images; your existing `rpc-provider-*` / `kaswallet-*` /
  `traefik` workers keep running on 2.3 (they are not recreated in this phase).
- The **health-check client** reports the pinned `KASPAD_VERSION` to the
  monitoring server.

## Part Two: after the Toccata switch

Once Toccata (KIP-21) has activated on mainnet, upgrade the workers so they emit
lane/subnetwork (v1) transactions:

1. Set the worker pins to `3.0` in `.env` (a follow-up repo change will also bump
   them in `versions.mainnet.env`):

   | Variable | Set to |
   |---|---|
   | `RPC_PROVIDER_VERSION` | `3.0` |
   | `KASWALLET_VERSION` | `3.0` |

2. Recreate the worker profile (same `N` as before):

   ```bash
   docker compose config -q
   docker compose --profile frontend-w<N> up -d --no-build
   ```

The v3.0 kaswallet then runs with `--subnetwork-id=$IGRA_LANE_ID` and emits
post-Toccata (v1) transactions on the IGRA lane.

## Rollback

The reconcile is `.env`-only and your volumes are never touched, so rollback is
clean:

- **`.env`**: restore from `.env.backup.pre-v3.0.*` written before the rewrite.
- **Compose / entrypoints**: `git checkout <your-previous-ref>` to put back the
  old `docker-compose.yml`.
- **Images**: with the old `.env` restored, the 2.3 pins come back and
  `docker compose up -d --no-build` runs the old images against your unchanged
  volumes.

## Troubleshooting

| Error | Meaning | Fix |
|---|---|---|
| `config/traefik/dynamic.yml` shows as `deleted` after the pull (or `unable to create file ... Permission denied`) | The root-running Traefik container bind-mounts `config/traefik/`, leaving the directory root-owned, so Git can't write the new tracked `dynamic.yml` into it | `sudo chown -R "$USER:$USER" config/traefik/ && git restore config/traefik/dynamic.yml` |
| `IGRA_LANE_ID must be set ...` at `docker compose` | `.env` is still on the v2.3 schema (missing the lane) | Run `./scripts/upgrade-mainnet-v2.3-to-v3.0.sh` (or set `IGRA_LANE_ID=97b10000` by hand) |
| `TX_ID_PREFIX must be set ...` at `docker compose` | `TX_ID_PREFIX` missing/empty | Set `TX_ID_PREFIX=97b1` in `.env` |
| `.env NETWORK is '...', not 'mainnet'` | Wrong network for this script | This guide is mainnet-only; for Galleon use [migrate-galleon-to-testnet-10.md](migrate-galleon-to-testnet-10.md) |
| `.env IGRA_CHAIN_ID is '...', not the mainnet value '38833'` | Custom or stale chain identity | Restore the mainnet `IGRA_CHAIN_ID=38833` (keep your node-specific overrides) |
| `Node database is from an older version` then `Operation was rejected (), exiting..` | kaspad needs the one-time DB metadata upgrade but can't prompt inside Docker | Run the `KASPAD_NONINTERACTIVE=true` bring-up above |
| `docker compose not found; skipped compose validation` | `docker compose` v2 plugin missing on the host | Install the Docker Compose v2 plugin, then run `docker compose config -q` |
