# ATAN Post-KIP-21 Archive Verification

Verify that the **post-KIP-21 (post-Toccata)** ATAN finality-period archives (`<score>.pb`) stored by a
node are valid, by running the offline `kaspa-atan-verify` tool against the kaspad data volume.

For each finality period the tool recomputes the `seq_commit` scalar chain, replays the IGRA lane, and
confirms they match the stored values, reporting `PASS` / `FAIL` / `MISSING` per period.

!!! note "Safe to run against a live node"
    `kaspa-atan-verify` is strictly **read-only** and never opens the `atan_db` RocksDB, so it does not
    contend with the running kaspad's database lock. Always mount the data volume **read-only** (`:ro`).
    Committed `.pb` files are written atomically, so the period kaspad is currently writing is invisible to
    the tool — cap `--to` at the last fully-imported finality score.

## When to use

- After importing historical ATAN data, to confirm the imported post-KIP-21 periods are valid.
- As a periodic integrity check of the archive on an ATAN/uploader node.

Only periods **at or after Toccata activation** exercise the four-group validator; earlier periods are
validated through the legacy path. The per-period log prints `pre-kip21` / `post-kip21` block counts so a
pre-activation (legacy-only) run is obvious.

## Prerequisites

The verifier ships **inside the published kaspad image** (`igranetwork/kaspad`) as `/app/kaspa-atan-verify`
— there is no separate image to build or pull. You only need a `KASPAD_VERSION` whose image bundles the
verifier (a build at or after the one that added `kaspa-atan-verify`; the ZK-hardening handling described
below requires a build at or after that fix).

The image already runs as UID 1000, matching the `kaspa` user that owns the kaspad data volume, so it can
read a `:ro`-mounted volume without a `--user` override.

## 1. Identify the container, volume, and archive path

The kaspad container and the Compose-prefixed volume name vary by deployment, so discover them first:

```bash
# Container name (e.g. `kaspad`, or `kaspad-atan` under docker-compose.atan.yml):
docker ps --format '{{.Names}}\t{{.Image}}' | grep kaspad

# Volume name (Compose prefixes it: <project>_kaspad_data):
docker volume ls | grep kaspad
```

The archive lives under the node's `DATADIR`, in `atan/<TX_ID_PREFIX>/chain_block_lists`. For Galleon
testnet-10 (`NETWORK=testnet-10`, `TX_ID_PREFIX=97b4`) that is:

```
/app/data/kaspa-testnet-10/datadir/atan/97b4/chain_block_lists
```

List the imported periods (read-only `alpine`; the temp var avoids the `head`/`tail`-share-a-pipe pitfall):

```bash
VOL=<volume-from-above>     # e.g. atan-testnet-10_kaspad_data
docker run --rm -v "$VOL":/app/data:ro alpine sh -c '
  d=/app/data/kaspa-testnet-10/datadir/atan/97b4/chain_block_lists
  scores=$(ls "$d" | sed "s/\.pb//" | sort -n)
  echo "first=$(echo "$scores" | head -1) last=$(echo "$scores" | tail -1) count=$(echo "$scores" | wc -l)"
'
```

## 2. Boundary proof (verify one period first)

Verify the activation-boundary period on its own before the full sweep. A `PASS` confirms the recomputed
`seq_commit` matches the stored chain; the variant counts show whether the period is mixed pre/post or pure
post-KIP-21.

```bash
VOL=<volume-from-above>
docker run --rm -v "$VOL":/app/data:ro \
  -e RUST_LOG=warn,kaspa_atan_verify=info \
  --entrypoint /app/kaspa-atan-verify igranetwork/kaspad:${KASPAD_VERSION} \
  --chain-block-lists /app/data/kaspa-testnet-10/datadir/atan/97b4/chain_block_lists \
  --from 1057 --to 1057 --zk-hardening-activation 476232000
```

!!! warning "Quiet the logs"
    `kaspa-atan-verify` honours `RUST_LOG`. The deployed node sets `RUST_LOG` to **trace** for the ATAN
    crates, which makes the validator log **one line per block** (hundreds of thousands per period). Always
    pass `-e RUST_LOG=warn,kaspa_atan_verify=info` so you get just the per-period `PASS`/`FAIL` lines. This
    matters most for `docker exec` (which inherits the live container's `RUST_LOG`).

!!! tip "Quick alternative: exec into the running node"
    Because the verifier is part of the kaspad image, you can also run it inside the live container (the
    archive is already mounted at `/app/data`). Use the container name from step 1 and the same `RUST_LOG`
    override:

    ```bash
    docker exec -e RUST_LOG=warn,kaspa_atan_verify=info kaspad /app/kaspa-atan-verify \
      --chain-block-lists /app/data/kaspa-testnet-10/datadir/atan/97b4/chain_block_lists \
      --from 1057 --to 1057 --zk-hardening-activation 476232000
    ```

    This shares the running container's resources; for the full sweep prefer the isolated `docker run` form.

`--tx-prefix` (default `97b4`) and `--igra-lane-id` (default `97b10000`) default correctly for testnet-10 and
can be omitted, but must match the node's `TX_ID_PREFIX` / `IGRA_LANE_ID` (`.env`; see
[Environment Reference](environment-reference.md)) — a mismatch is the most common false `FAIL`.
`--zk-hardening-activation` has **no default** (the verifier is born-hardened by default); pass it
**explicitly** as `476232000` for the TN10 historical archive (see the next section), or periods 1057–1077
will fail.

## 3. Verify the full range

Once the boundary proof passes, widen to the full post-KIP-21 range (set `--to` to the last imported period
from step 1):

```bash
VOL=<volume-from-above>
docker run --rm -v "$VOL":/app/data:ro \
  -e RUST_LOG=warn,kaspa_atan_verify=info \
  --entrypoint /app/kaspa-atan-verify igranetwork/kaspad:${KASPAD_VERSION} \
  --chain-block-lists /app/data/kaspa-testnet-10/datadir/atan/97b4/chain_block_lists \
  --from 1057 --to 1091 --zk-hardening-activation 476232000
```

## ZK hardening vs Toccata (TN10)

On TN10 the two consensus activations happened at **different** times, before the core team later collapsed
them into one ("born-hardened"):

| Activation | DAA score | ≈ finality period |
|---|---|---|
| Toccata (KIP-21 / post-KIP-21 blocks begin) | `467_579_632` | **1057** |
| ZK hardening (`inactivity_shortcut` required) | `476_232_000` | **1078** |

So in the historical archive:

- **1057–1077** are post-Toccata but **pre-ZK-hardening**: their blocks carry **no** `inactivity_shortcut`,
  and the verifier validates them via the identity activity root.
- **1078–1091** are **ZK-hardened**: their blocks carry the `inactivity_shortcut`.

The verifier handles both via `--zk-hardening-activation 476232000`. The flag has **no default** (the verifier
is born-hardened by default), so it must be passed **explicitly**; with a current build and the flag the full
`1057..=1091` sweep passes. If you omit it — or the image predates the ZK-hardening fix — every post-Toccata
period fails with:

```
... `inactivity_shortcut` is inconsistent with hardening activation: post-toccata block must carry an
inactivity_shortcut (born-hardened)
```

In that case, pass `--zk-hardening-activation 476232000` and use a current image.

## Interpreting the output

A healthy full run (testnet-10, with `--zk-hardening-activation 476232000`):

```
atan-verify: network=testnet-10 toccata_activation_daa=467579632 zk_hardening_activation=476232000 tx_prefix=97b4 igra_lane_id=97b10000 range=1057..=1091
period 1057: PASS (format=V2, pre-kip21=159477, post-kip21=...)
period 1078: PASS (format=V2, pre-kip21=0, post-kip21=192681)
period 1091: PASS (format=V2, pre-kip21=0, post-kip21=161882)
atan-verify: summary 35 passed / 0 failed / 0 missing of 35 period(s)
```

The startup line echoes the resolved config; `zk_hardening_activation=none(born-hardened)` means the flag was
not passed.

- `PASS` — the period's `seq_commit` chain and IGRA-lane replay match the stored values.
- `FAIL` — a mismatch; the `AtanError` names the offending block and the expected/actual values.
- `MISSING` — no `.pb` for that score in the directory (e.g. `--to` exceeds what is imported).
- `pre-kip21` / `post-kip21` — block-variant counts; a non-zero `pre-kip21` marks an activation-boundary
  period (e.g. 1057) or a pre-activation period.
- The container **exit code is non-zero** if any period failed or was missing — usable in scripts/CI.

## Notes

- Mount the volume **read-only** (`:ro`). Do not run the verifier with a writable mount.
- Always pass `-e RUST_LOG=warn,kaspa_atan_verify=info` (see the warning above).
- For the TN10 historical archive, always pass `--zk-hardening-activation 476232000` (no default).
- Cap `--to` at the last fully-imported finality score; the period currently being written is intentionally
  not visible to the tool.
- A wrong `--tx-prefix` / `--igra-lane-id` (not matching the node) is the most likely cause of a false
  `FAIL`; confirm them against `.env` before investigating data.
- See `atan/verify/README.md` in `rusty-kaspa-private` for the tool's full reference.
