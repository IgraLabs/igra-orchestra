# Enable KIP-21 Lane Mode

## Who this is for

Operators on a network whose KIP-21 fork has activated (or is imminent) and
who want kaspad/kaswallet to operate on the dedicated IGRA lane namespace.

The shipped `.env.<network>.example` templates default `IGRA_LANE_ID=` empty
so a routine `cp` does **not** silently switch a pre-fork stack into lane
mode. Frigate (`testnet-12`) is the one exception — it is KIP-21 active from
genesis and ships with the canonical lane id pre-filled. If you operate
Frigate, you can skip this runbook.

## What enabling lane mode does

When `IGRA_LANE_ID` is non-empty:

- **kaspad** receives `--igra-lane-id=$IGRA_LANE_ID` on its command line.
- **kaswallet** (each replica) receives `--igra-lane-id=$IGRA_LANE_ID`.
- **rpc-provider** sees `IGRA_LANE_ID` in its environment.
- The **ATAN auto-import path** switches from
  `{CDN_BASE_URL}/{NETWORK}/{TX_ID_PREFIX}/index.pb`
  to
  `{CDN_BASE_URL}/{NETWORK}/{IGRA_LANE_ID}/index.pb`.
- The **ATAN uploader** uploads under the same lane-id namespace.

Pre-fork operators leaving `IGRA_LANE_ID` empty behave exactly as before.

## Prerequisites

- KIP-21-capable kaspad, kaswallet, and rpc-provider images already pulled
  (update the relevant `versions.<network>.env` tags first).
- Canonical IGRA lane id for your network confirmed with Igra Labs ops. The
  current value across published networks is
  `97b1000000000000000000000000000000000000`.
- The lane-namespaced ATAN CDN object exists for your network — i.e.
  `{CDN_BASE_URL}/{NETWORK}/{IGRA_LANE_ID}/index.pb` is reachable. If not,
  keep a pinned `ATAN_IMPORT_URL` override (see step 4). kaspad will now
  refuse to start if `ATAN_IMPORT_URL` is set but does not contain
  `IGRA_LANE_ID` — that mismatch was the main pre-flip footgun this runbook
  guards against.
- A recent `.env` backup, in case you need to roll back.

## Steps

1. Stop the stack:

   ```bash
   docker compose --profile backend --profile frontend-w5 down
   ```

   Adjust the `frontend-w*` profile to match the worker count you run.

2. Update image tags to KIP-21-lane-capable versions in
   `versions.<network>.env` (or directly in `.env` if you append the
   versions file). Pull:

   ```bash
   docker compose --profile backend --profile frontend-w5 pull
   ```

3. Set `IGRA_LANE_ID` in `.env`:

   ```env
   IGRA_LANE_ID=97b1000000000000000000000000000000000000
   ```

   Use the canonical value confirmed in Prerequisites.

4. Reconcile `ATAN_IMPORT_URL`:

   - **Recommended**: comment out / remove `ATAN_IMPORT_URL=` so kaspad
     auto-constructs the lane-id path from `CDN_BASE_URL`, `NETWORK`, and
     `IGRA_LANE_ID`.
   - **Override**: if you must keep a pinned URL, point it at
     `{CDN_BASE_URL}/{NETWORK}/{IGRA_LANE_ID}/index.pb`. The substring
     `IGRA_LANE_ID` must appear in the URL — kaspad's startup safety check
     exits 1 otherwise (the ATAN-only compose downgrades this to a warning).

5. Start the stack:

   ```bash
   docker compose --profile backend --profile frontend-w5 up -d --no-build
   docker compose logs -f kaspad
   ```

## Verify

After the stack is up, confirm lane mode is plumbed through every consumer.

- **kaspad** — its resolved command line includes `--igra-lane-id`:

  ```bash
  docker compose exec kaspad sh -c 'ps -o args= -p 1' | tr ' ' '\n' | grep igra-lane-id
  ```

  Should print `--igra-lane-id=97b1000000000000000000000000000000000000`.

- **kaswallet** — same check on any worker:

  ```bash
  docker compose exec kaswallet-0 sh -c 'ps -o args= 1' | tr ' ' '\n' | grep igra-lane-id
  ```

- **rpc-provider** — env contains the lane id:

  ```bash
  docker compose exec rpc-provider-0 env | grep '^IGRA_LANE_ID='
  ```

- **ATAN import URL** — kaspad's startup log should show the resolved
  `--atan-import-url` flag using the lane id segment:

  ```bash
  docker compose logs kaspad | grep -E 'atan-import-url|atan_import_url' | head -5
  ```

  Expect the path ending in `/$IGRA_LANE_ID/index.pb`, not
  `/$TX_ID_PREFIX/index.pb`.

## Rollback

Lane mode is a runtime-only switch — no volume or chain-state changes.

1. Stop the stack:

   ```bash
   docker compose --profile backend --profile frontend-w5 down
   ```

2. In `.env`, set `IGRA_LANE_ID=` empty and restore your previous
   `ATAN_IMPORT_URL` if you changed it.

3. (Optional) Revert image tags in `versions.<network>.env` to the pre-fork
   versions.

4. Start the stack:

   ```bash
   docker compose --profile backend --profile frontend-w5 up -d --no-build
   ```

kaspad/kaswallet return to passing `--atan-transaction-id-prefix=$TX_ID_PREFIX`
without a lane flag, and the ATAN import URL auto-constructs back under the
`TX_ID_PREFIX` namespace.
