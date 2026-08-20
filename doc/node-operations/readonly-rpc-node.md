# Read-Only RPC Node

A minimal, read-only Igra node for co-location on a hardened host. It runs `kaspad` and
`execution-layer` and serves `eth_*` reads to a local consumer through a fail-closed proxy, as
`RPC_URL_1 = http://igra-local-rpc:8545`.

Entry point: `docker-compose.readonly-rpc.yml`. Environment: `.env.readonly-rpc.example`.

## Why It Exists

A client that reads chain state continuously needs two independent `eth_*` endpoints. When both point at the same
third party, a fallback configuration has nothing to fall back to, and the consumer's view of Igra — our own chain —
comes entirely from someone else's node. This stack gives it a first endpoint we control.

## What It Cannot Do

**This stack cannot broadcast transactions.** It has no `rpc-provider` write path and no `kaswallet`, and the proxy
runs read-only. Anything that submits a transaction — funding, governance, any on-chain write — must go through an
external funded endpoint.

Read-only preflight checks may still use this endpoint. The announce simulation (`cast call` on
`announce(...)`), `getAnnouncedStorageLocations`, `cast balance` and `cast chain-id` are all `eth_call`-class reads
and are on the allowlist.

## Why A Proxy, And Not Just Narrower reth Flags

The obvious design is to restrict reth's `--http.api` and skip the third container. It does not work, and the reason
is worth recording so nobody re-derives it under time pressure.

kaspad's Igra adapter builds **two** endpoints from one host string: `{host}:8551` for the engine API and
`{host}:8545` for everything else. Every method not prefixed `engine_` goes to 8545 — and the block-building path
sends `eth_sendRawTransaction`, `admin_clearTxpool`, `txpool_content`, `net_version` and `eth_getBlock*` over it.
`clear_txpool_and_wait()` runs at the top of *every* proposal, not only non-empty ones.

So:

- Narrowing 8545 to `eth,net,web3` would break block production at the first proposal.
- No namespace set closes the write path anyway, because `eth_sendRawTransaction` lives in `eth` alongside every
  read the consumer needs, and reth filters by namespace, not by method.

Hence a method-level guard in front, which is what the proxy is. The stronger long-term design — move kaspad's
privileged path onto reth's auth IPC socket and enforce a method allowlist inside reth — is recorded as the target
architecture below.

One correction while you are here: the threat model sometimes cites `debug_setHead` as the danger. In this reth
fork that method is a no-op; the doc comment warning that it is destructive is inherited from upstream and does not
match the implementation. The real divergence primitive is `eth_sendRawTransaction`, and `admin_clearTxpool` is a
production-disruption path.

## Release Gates — Read Before Deploying

Three capabilities this stack depends on are not in any published image yet. Each fails **silently or expensively**
if you use an older tag, which is why `.env.readonly-rpc.example` ships them as `TODO_..._REPLACE_ME` placeholders
and the compose file requires them under names distinct from the mainnet pins.

| Gate | What is needed | Failure if ignored | Recoverable? |
|---|---|---|---|
| `READONLY_RPC_RETH_VERSION` (pruning) | A reth tag whose launcher supports `IGRA_RETH_PRUNE_DISTANCE_BLOCKS` | The variable is ignored and the node runs **archive mode**. | **No.** Pruning is one-way per data directory; correcting it later costs a full resync. |
| `READONLY_RPC_PROXY_VERSION` | An `rpc-provider` tag that starts **without a wallet** | The image builds its wallet client and requires `KASWALLET_PASSWORD` before binding a listener. With no kaswallet it exits before serving a request, and the consumer has no `RPC_URL_1` at all. | Yes — it fails loudly at bring-up. |
| `READONLY_RPC_RETH_VERSION` (file logging) | The **same** reth tag, with the launcher passing `--log.file.max-files 0` | reth's background file logger stays on at its default `debug` filter, writing a sustained ~1 GB rotating stream into `${IGRA_DATA_ROOT}/reth/.cache` — the same filesystem and I/O path as its own database. | Yes — add the flag and delete the logs; no resync. |

**On the third gate.** It rides the *same* reth release as the first: `--log.file.max-files` is an existing upstream
flag, so the only change is the launcher passing it. That makes the cost of including it approximately zero, and
there is no compose-side alternative — the log arguments are argv-only, with no `env =` and no environment
fallback, so nothing in this file can reach them.

It matters because a sustained debug-level write stream sharing the database's I/O path is precisely the contention
that was cited when co-location was first argued against. Accepting it as a permanent limitation would concede that
point for no reason, when the fix is one flag on a release we are already waiting for.

It is also the only gate here that is **recoverable after the fact**, and that is worth stating plainly: if you are
forced to choose, this is the one to defer. A gate that overstates its own severity gets ignored along with the two
that do not.

Confirm all three at bring-up rather than trusting the tag:

```bash
# Pruning actually active — not merely requested
sudo journalctl --no-pager -u docker CONTAINER_NAME=execution-layer-readonly-rpc \
  | grep 'Pruning: enabled; distance=600000'

# File logging actually disabled — the third gate. Any output here means the
# logger is still running and writing into the data filesystem.
sudo journalctl --no-pager -u docker CONTAINER_NAME=execution-layer-readonly-rpc \
  | grep -i 'log.file\|logs directory' || echo "ok: no file-logging output"

# Proxy actually serving. INSTALLER-ONLY (docker is not granted to deploy).
# bash, not sh: the proxy image is debian-slim where /bin/sh is dash, and
# /dev/tcp is a bash builtin — under dash this fails with "Directory
# nonexistent" even when the proxy is serving perfectly.
sudo docker exec rpc-proxy-readonly-rpc \
  bash -c 'exec 3<>/dev/tcp/127.0.0.1/8545 && printf "GET /health HTTP/1.0\r\n\r\n" >&3 && head -1 <&3'
```

If the first command prints nothing, the execution layer is running archive mode. Stop, destroy the reth data
directory, and start over with a correct image — do not "enable it later".

## Storage: What Is And Is Not Bounded

Two variables bound history, one per layer.

`IGRA_RETH_PRUNE_DISTANCE_BLOCKS=600000` bounds **four reth segments** — sender recovery, receipts, account
history, storage history — at roughly 7.3 days behind the tip (about 1.05 s/block as sampled on 2026-08-18; one week
is ~574,850 blocks, so 600,000 carries ~4% margin). Remeasure before relying on it: current head minus the head from
a week ago.

`KASPAD_RETENTION_PERIOD_DAYS=7` bounds locally retained L1 block history. Note this is *heavier* than kaspad's
~30-hour default — it is the one-week requirement applied to L1, not the lightest possible setting. kaspad's floor is
2 days, and its own size estimate excludes non-block stores.

**Neither bounds total disk.** Block bodies, transaction lookup, current state, Merkle data and kaspad's other
stores all keep growing. The host-side capacity guard remains a deployment prerequisite, not an optional extra.

**Budget for reth's file logs too.** `read_only: true` forces `XDG_CACHE_HOME` onto the data bind (see the compose
comment), which leaves reth's background file logger enabled at its default `debug` filter: up to 1 GB of rotating
logs, written continuously to the same filesystem and the same I/O path as the reth database. On a host whose
stated co-location risk is I/O contention with the co-tenant, that is a real cost, and the capacity guard sees
only the disk half of it. Removing it needs `--log.file.max-files 0` in the launcher — the P1 follow-up.

**Pruning does not make restarts survivable.** That is a separate mechanism and worth being precise about: the
execution layer runs `--trusted-only --disable-discovery`, so it has no peers at all and is advanced solely by
kaspad. After a stop it resumes from kaspad's replay; kaspad recovers gaps through L1 IBD plus the ATAN CDN import
its entrypoint requires. Retained reth history is not the catch-up buffer. What the window *does* determine is how
far back RPC queries reach.

**Consequence for the consumer:** `eth_getLogs` and receipts older than the window are unavailable here, so
`RPC_URL_2` must be archive-capable. A consumer with an empty or stale database that needs history deeper than the
window has to bootstrap from `RPC_URL_2`.

**Pruning is one-way.** reth persists the configuration into the data directory's `reth.toml`. Removing the variable
does not restore archive behaviour, and raising the distance does not bring deleted history back. Rollback is
destroying `${IGRA_DATA_ROOT}/reth` and resyncing. Set it correctly before the first sync.

## Host Prerequisites

Provisioned by the host's own setup procedure, not by this repository:

- **The whole repository checked out at `/opt/igra-orchestra`, root-owned** — not just the compose file. Both
  kaspad and the proxy bind-mount `./scripts/lib/watch-dependencies.sh`, and kaspad also mounts
  `./scripts/lib/parse-network-slug.sh`; those paths resolve relative to the compose file's directory. Copying the
  compose file alone leaves the mounts dangling and the containers fail at create.
- `${IGRA_DATA_ROOT}` with `kaspad/` and `reth/` subdirectories, **owned `1000:1000`** — which on this host is
  the host's operator account. All three services set `user: "1000:1000"` explicitly,
  which bypasses the images' own root-then-drop entrypoint setup, so ownership must be right *before* first start
  or the containers cannot write their data directories. The compose file uses `create_host_path: false`, so a typo
  fails at container create rather than silently creating a root-owned directory and resyncing onto the wrong
  filesystem.
- `${IGRA_JWT_PATH}` — the shared engine-API JWT, readable by uid 1000 in both containers, not writable by them.
- `igra-rpc.slice`, a systemd slice carrying the aggregate resource limits. The compose file places all three
  containers under it via `cgroup_parent`; the numbers live in the slice because `MemoryHigh` has no Compose
  equivalent and per-service limits would grant the stack several times the intended budget.
- Docker using the **systemd** cgroup driver (`docker info --format '{{.CgroupDriver}}'`). With `cgroupfs` a
  `.slice` parent fails at container create — loudly, which is the intended behaviour.
- A Linux host with systemd. The journald log driver and the slice parent both fail on macOS; `config` checks still
  run anywhere.

## Launching On A Locked-Down Host

The host's operator account runs under a **restricted sudo allowlist**: a fixed set of exact command lines, matched
in full rather than by prefix. Three consequences shape the design rather than merely constraining it:

- **`systemctl start`/`stop` of an arbitrary unit is not available.** A systemd unit the operator is expected to
  start is therefore not an option without extending the allowlist.
- **The operator account is not in the `docker` group**, so bare `docker ps`, `docker inspect`, `docker logs` and
  `docker run` all fail. Any verification step that shells out to `docker` is unavailable to it (see Verification).
- **Reading the journal via `journalctl -u docker` *is* available**, which is why journald logging is load-bearing
  rather than cosmetic — it is the only route to container output this account has.

Follow the pattern a hardened host already uses for its other services: **root-owned helper scripts named in the
sudo allowlist**, not a unit the operator drives. Boot persistence comes from `restart: unless-stopped` rather
than from a unit. Mirror that shape:

```bash
# /usr/local/sbin/igra-rpc-up   (root:root 0755) — one per verb
#!/bin/sh
exec /usr/bin/docker compose \
  --env-file /etc/igra-readonly-rpc/compose.env \
  -f /opt/igra-orchestra/docker-compose.readonly-rpc.yml \
  up -d --no-build --remove-orphans
```

with siblings `igra-rpc-status` (`ps`), `igra-rpc-stop` (`stop`) and `igra-rpc-restart`, added to
the host's sudo allowlist as four more exact lines.

Four details that matter:

- **`stop`, never `down`.** The consumer attaches to `igra-readonly-rpc` as an external network; `down` would try
  to remove a network still in use, and it would also remove the containers rather than pausing them.
- **Boot persistence comes from `restart: unless-stopped`**, as it does for the host's other services. No unit needed
  for that.
- **`igra-rpc.slice` is still a systemd unit**, but a *static* one — it only has to exist so `cgroup_parent` has
  somewhere to place the containers. Nobody starts it.
- **The compose file, the helper scripts and `/etc/igra-readonly-rpc/compose.env` must all be root-owned.** The
  host's other compose files are operator-writable and root-executed, which already makes
  `deploy` effectively root; a second root-executed path should not repeat that.

Merging into a co-tenant's compose file is rejected for a reason worth stating: the granted `down` would then stop
that service too.

Installation of the helpers, the sudoers lines, the slice and the file ownership is host-side work and lives in the
audit repository. **None of it exists yet** — until it does, this stack cannot be operated by `deploy` at all.

## Initial Sync — Two Stages, Not Optional

`.env.readonly-rpc.example` ships stage 1 as the default state.

**Stage 1 — L1 only.** With `IGRA_ENABLE=false`, kaspad syncs Kaspa without IGRA/ATAN overhead:

```bash
sudo igra-rpc-up
sudo journalctl --no-pager -u docker CONTAINER_NAME=kaspad-readonly-rpc -n 50
```

The granted journal line is `journalctl --no-pager -u docker *`, and sudo matches the whole command string — so
`--no-pager` must come before `-u`, and `-f` goes after it if you want to follow.

Wait for L1 sync to complete. Container health is not the gate — kaspad reports healthy as soon as gRPC is
listening, long before chain parity.

**Stage 2 — enable IGRA.**

> **`restart` will not do this.** `docker compose restart` restarts existing containers with the environment they
> were *created* with; it does not re-read the env file. Neither does `igra-rpc-restart`. A config change only
> takes effect through `up -d`, which recreates the container when its resolved config has changed. This applies
> to every future config change, not just `IGRA_ENABLE` — always route them through the up helper.

`/etc/igra-readonly-rpc/compose.env` is root-owned, so `deploy` cannot edit it. Stage 2 therefore needs a
dedicated root-owned helper, listed in sudoers alongside the others:

```bash
# /usr/local/sbin/igra-rpc-enable-igra   (root:root 0755)
#!/bin/sh
set -e
ENVFILE=/etc/igra-readonly-rpc/compose.env
COMPOSE=/opt/igra-orchestra/docker-compose.readonly-rpc.yml
sed -i 's/^IGRA_ENABLE=.*/IGRA_ENABLE=true/' "$ENVFILE"
grep -q '^IGRA_ENABLE=true$' "$ENVFILE" || { echo "IGRA_ENABLE not set" >&2; exit 1; }
/usr/bin/docker compose --env-file "$ENVFILE" -f "$COMPOSE" config -q
exec /usr/bin/docker compose --env-file "$ENVFILE" -f "$COMPOSE" up -d --no-build --remove-orphans
```

```bash
sudo igra-rpc-enable-igra
```

Then confirm pruning is active (above) and that the L2 head advances. If the head does not move, check that the
transition actually applied — a container still running with `IGRA_ENABLE=false` looks healthy and simply never
produces L2 blocks.

The go-live gate is parity with `RPC_URL_2`, not container health. Do not point the consumer at this endpoint
before then.

## Verification

**Read this before copying anything below.** The commands in the first group all invoke `docker`, and `deploy` is
not in the `docker` group — bare `docker ps`, `docker inspect`, `docker run` and `docker logs` all fail for that
account, and none of them is in the sudo grant. They are **installer-only**: run them while you still have
privileged access, during bring-up, and archive the output. After lockdown they are not re-runnable, the same way
hardened-host practice records that a container's own `read_only`, `cap_drop` and mounts are asserted at write time and not
re-checkable later".

The second group is what `deploy` can actually run afterwards, and it is the whole of the ongoing operational
surface.

### Installer-only — run during bring-up, archive the output

From the consumer's exact vantage point — inside the internal network:

> **Assert the exact response, never just "an error came back".** `eth_sendRawTransaction` is *on* the proxy's
> whitelist — it is blocked solely by read-only mode. If `READ_ONLY` were disabled the call would still fail, at
> transaction decoding, with a **different** error. A probe that only prints output therefore passes identically
> whether the guard is on or off, and this is the only live verification of this stack's core control. The script
> below fails the shell unless it sees the specific guard responses.

```bash
set -euo pipefail
NET=igra-readonly-rpc
RPC=http://igra-local-rpc:8545
probe() { sudo docker run --rm --network "$NET" curlimages/curl:8.10.1 -sS -m 5 \
  -H 'content-type: application/json' -d "$1" "$RPC"; }
expect() {  # expect <jq-filter> <payload> <description>
  out=$(probe "$2")
  echo "$out" | jq -e "$1" >/dev/null \
    || { echo "FAIL: $3 — got: $out" >&2; exit 1; }
  echo "ok: $3"
}

# Chain identity — must be Igra's id, and must match what RPC_URL_2 reports
expect '.result == "0x97b1"' \
  '{"jsonrpc":"2.0","id":1,"method":"eth_chainId","params":[]}' \
  'eth_chainId is 0x97b1 (38833 mainnet)'

# Reads work: a result, not an error
expect '.result != null and (.error | not)' \
  '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' \
  'eth_blockNumber returns a result'

# The write path is closed BY THE READ-ONLY GUARD, not by a decode failure.
# -32000 "Read-only mode is enabled" is the only response that proves it.
expect '.error.code == -32000 and (.error.message | test("[Rr]ead-only"))' \
  '{"jsonrpc":"2.0","id":1,"method":"eth_sendRawTransaction","params":["0x02"]}' \
  'eth_sendRawTransaction refused by read-only guard'

# Non-whitelisted methods: -32002, method not allowed. Note debug_setHead is a
# no-op in this reth fork, so if the whitelist were off it would return a
# RESULT — visibly different from this refusal.
for m in debug_setHead admin_clearTxpool txpool_content; do
  expect '.error.code == -32002' \
    "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$m\",\"params\":[]}" \
    "$m not on the allowlist"
done

# kaspad and the raw execution layer must be unresolvable from this network.
# Pull first and check the exit code explicitly: a bare `! docker run ...`
# treats ANY non-zero exit as "unreachable", so a registry hiccup would print
# ok without testing anything. busybox nslookup exits 1 on NXDOMAIN.
sudo docker pull -q busybox:1.36 >/dev/null
unresolvable() {
  set +e
  sudo docker run --rm --network "$NET" busybox:1.36 nslookup "$1" >/dev/null 2>&1
  rc=$?
  set -e
  case "$rc" in
    0) echo "FAIL: $1 resolves from the consumer network" >&2; exit 1 ;;
    1) echo "ok: $1 is unresolvable" ;;
    *) echo "FAIL: probe for $1 could not run (docker exit $rc) — result is not evidence" >&2; exit 1 ;;
  esac
}
unresolvable kaspad
unresolvable execution-layer
```

### Available to `deploy` after lockdown

```bash
# Container output — the granted journalctl line is the only route to it
sudo journalctl --no-pager -u docker CONTAINER_NAME=kaspad-readonly-rpc -n 20
sudo journalctl --no-pager -u docker CONTAINER_NAME=execution-layer-readonly-rpc -n 20
sudo journalctl --no-pager -u docker CONTAINER_NAME=rpc-proxy-readonly-rpc -n 20

# Pruning actually active (the release gate above)
sudo journalctl --no-pager -u docker CONTAINER_NAME=execution-layer-readonly-rpc \
  | grep 'Pruning: enabled; distance=600000'

# Stack state, once the helper scripts from the launch section exist
sudo igra-rpc-status
```

`ss -lntup` needs no docker access but **`sudo ss` is not in the grant** either, and unprivileged `ss` cannot show
the owning process. Checking for stray host listeners is an installer-time step; the compose file guarantees it
statically (CI asserts no `ports:` on any service), so there is nothing for `deploy` to re-verify.

`systemctl show igra-rpc.slice` is **not** granted either (only `systemctl --no-pager status docker` is), so
confirming the slice's `MemoryHigh`/`MemoryMax`/`CPUQuota` is likewise an installer-time check. If ongoing
visibility of the limits matters, it needs either another sudoers line or a status helper that prints them.

**Fail-closed drill — installer-only.** `docker stop`/`start` are not granted to `deploy`; run this during
bring-up, with a digest-pinned agent already running, and archive the result. Watch checkpoints before, during and
after: proving that `curl` fails is *not* proving the agent fell back.

```bash
sudo docker stop rpc-proxy-readonly-rpc
# consumer must show fallback to RPC_URL_2 and KEEP MAKING PROGRESS.
# Confirm against S3 object timestamps, not just agent logs.
sudo docker start rpc-proxy-readonly-rpc
```

## Divergence Monitoring

A co-located node that has diverged answers reads confidently, with no operational signal. Compare both endpoints at
a common height rather than comparing each one's own latest block:

**Where this can run is not obvious, and getting it wrong makes the monitor silently useless.** `igra-local-rpc`
resolves only through Docker's embedded DNS, from a container attached to `igra-readonly-rpc` — and that network is
`internal`, so nothing on it can reach an external `RPC_URL_2`. The host can reach `RPC_URL_2` but cannot resolve
the alias. **No single vantage point works by default.** Run the monitor in a small container attached to *both*
`igra-readonly-rpc` and a network with egress.

**It must be a *user-defined* network, not the default `bridge`.** Docker refuses to combine a user-defined
network with the built-in `bridge` network-mode at container create — `conflicting options: cannot attach both
user-defined and non-user-defined network-modes` — so `--network bridge` fails on every version. Create a
dedicated bridge once, rather than reusing the stack's `backend`, so the monitor gains no route to the raw
execution layer:

The script below is not in any image. Mount it read-only from a root-owned path rather than baking a one-off
image, so changing the thresholds does not mean a rebuild:

```bash
sudo docker network create igra-rpc-monitor-egress          # once

sudo docker run --rm \
  --network igra-readonly-rpc \
  --network igra-rpc-monitor-egress \
  -v /usr/local/sbin/igra-rpc-divergence:/divergence:ro \
  --entrypoint /divergence \
  ghcr.io/<image-with-curl-and-jq>
```

Any image with `curl` and `jq` works. Keep `/usr/local/sbin/igra-rpc-divergence` root-owned `0755`, beside the
other host helpers.

```bash
#!/bin/bash
# Exits non-zero on any fault. An `echo`-only monitor reports success to a
# systemd timer during the exact condition it exists to signal.
set -euo pipefail
RPC1=http://igra-local-rpc:8545
RPC2=<external-endpoint>
MAX_LAG=100
REORG_MARGIN=30

# --max-time is not optional: -fsS fails on an HTTP error but bounds nothing in
# time. A peer that accepts the connection and then stops responding would hang
# the monitor forever — leaving the timer "running" and silently never
# reporting the fault it exists to report. --connect-timeout alone is not
# enough; it bounds only connection setup.
rpc() { curl -fsS --connect-timeout 5 --max-time 15 -H 'content-type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"$2\",\"params\":$3}" "$1"; }

# Chain identity first: two endpoints on different chains agree about nothing.
c1=$(rpc "$RPC1" eth_chainId '[]' | jq -er .result)
c2=$(rpc "$RPC2" eth_chainId '[]' | jq -er .result)
[ "$c1" = "$c2" ] || { echo "CHAIN MISMATCH: $c1 != $c2" >&2; exit 2; }

h1=$(( $(rpc "$RPC1" eth_blockNumber '[]' | jq -er .result) ))
h2=$(( $(rpc "$RPC2" eth_blockNumber '[]' | jq -er .result) ))

# Lag check FIRST. The hash comparison below runs under the lower tip, so a node
# stalled thousands of blocks behind passes it perfectly — its old blocks are
# correct, it just stopped producing new ones. On a co-located node competing
# for I/O with its co-tenant, a stall is the likelier of the two failures, and
# it is invisible to a fork check.
lag=$(( h1 > h2 ? h1 - h2 : h2 - h1 ))
if [ "$lag" -gt "$MAX_LAG" ]; then
  echo "STALL: RPC1 at $h1, RPC2 at $h2 — $lag blocks apart (max $MAX_LAG)" >&2
  exit 3
fi

# Then the fork check, at a height both endpoints have reached.
common=$(( (h1 < h2 ? h1 : h2) - REORG_MARGIN ))
[ "$common" -gt 0 ] || { echo "chain too young to compare" >&2; exit 4; }
tag=$(printf '0x%x' "$common")

b1=$(rpc "$RPC1" eth_getBlockByNumber "[\"$tag\",false]" | jq -er .result.hash)
b2=$(rpc "$RPC2" eth_getBlockByNumber "[\"$tag\",false]" | jq -er .result.hash)
[ "$b1" = "$b2" ] || { echo "DIVERGENCE at $tag: $b1 != $b2" >&2; exit 5; }

echo "ok: same chain, lag ${lag}, hashes agree at ${tag}"
```

Both checks are needed and they catch different faults: the lag check finds a node that stopped, the hash check
finds a node that went somewhere else. Neither substitutes for the other.

`MAX_LAG=100` is roughly 100 seconds at the sampled cadence — tune it against observed steady-state drift before
alerting on it, or the first busy period pages someone for nothing.

Distinct exit codes (2 chain mismatch, 3 stall, 4 chain too young, 5 divergence) let the alert say which fault
fired. `curl -fsS --max-time` and `jq -er` fail the script on a null, an error object, an HTTP error or a stalled
response, and `set -e` propagates that. Give the systemd unit a `TimeoutStartSec` as a second bound anyway.
Scheduling and alert delivery remain host-side scope.

## Target Architecture (Not Yet Implemented)

The proxy is the deliverable design, but the stronger endstate is native enforcement in reth: move kaspad's
privileged path onto the auth IPC socket the launcher already creates, and enforce a method-level allowlist on the
public HTTP listener inside the binary. That removes the dangerous methods rather than filtering them, and drops the
stack back to two containers.

It needs reth work plus a kaspad transport change, and should ride the same release train as the pruning work. Two
things to settle before starting: hold the allowlist in **configuration**, never as compiled constants — otherwise a
routine consumer upgrade needs a reth source release, recreating the third-party dependency this stack exists
to remove — and soak-test the IPC transport at production cadence, since it serializes every call over a single
connection where HTTP used two pooled clients.

## Known Limitations

- **No inbound kaspad P2P.** No ports are published, so kaspad syncs outbound-only. Fewer peers, marginally slower;
  acceptable for a leaf node.
- **The method allowlist is broader than any single consumer needs.** The shipped whitelist is a general provider list.
  It includes read-only `debug_trace*`, which are exposure and DoS surface rather than divergence risk. The exact
  consumer's method set has not been captured. To capture it, set `RPC_PROXY_RUST_LOG=info` and restart — the proxy
  logs every request at info, so one signing session's journal yields the used set and the list can then be
  narrowed. Return it to `warn` afterwards: consumers poll continuously and info-level logging of every
  request is a sustained write load on the host journal.
- **The consumer's compose file needs an edit this repository does not make, and the obvious form of it breaks the
  consumer.** A service with no `networks:` key sits on its project's implicit default network, which is how it
  reaches everything outside the host. Declaring a top-level `external: true` network does **not** attach the
  service; and a service-level `networks:` list is *exhaustive*, so naming only `igra-readonly-rpc` silently
  removes the default attachment. Because that network is `internal` — no gateway, no egress — the consumer would
  then lose all outbound access. It must list **both**:

  ```yaml
  services:
    <consumer>:
      # ... existing keys unchanged ...
      networks:
        # REQUIRED: without this entry the consumer loses all egress. An
        # explicit list replaces the implicit default attachment.
        #
        # gw_priority pins which network provides the default route. Both
        # entries otherwise render at priority 0, and Docker then breaks the tie
        # by network NAME — so egress would silently depend on the project name
        # sorting ahead of `igra-readonly-rpc`, and could flip to the internal
        # network (no gateway at all) after an unrelated rename.
        default:
          gw_priority: 1
        igra-readonly-rpc:

  networks:
    default:
    igra-readonly-rpc:
      external: true          # created by docker-compose.readonly-rpc.yml,
                              # which must be up first
  ```

  Assert the result **before** `up -d` — this is a failure that would only show up later as missing outbound
  traffic. Unlike most checks here this one needs **no sudo and no docker group**: `compose config` only parses and
  interpolates YAML, it never contacts the daemon, so the unprivileged operator can run it directly at any time.

  ```bash
  /usr/bin/docker compose -f <consumer-compose-file> config --format json \
    | jq -e '.services["<consumer>"].networks
             | has("default") and has("igra-readonly-rpc")
             and (.default.gw_priority // 0) > 0'
  ```

  That file is owned by whoever operates the consumer; this stack cannot be reached until the change lands.
- **Images must be digest-pinned, and CI now enforces it.** All three image variables must be either an unresolved
  `TODO_..._REPLACE_ME` placeholder or a `<tag>@sha256:<64-hex>` pin — a bare tag fails the build. This replaced an
  earlier check that merely asserted the gated tags were still placeholders, which would have deleted itself in the
  very PR that introduced the risk it guarded against.

  Resolve a digest with `docker buildx imagetools inspect igranetwork/<image>:<tag>`.

  Enforcing it here matters because nothing downstream will: the host-side verifier's digest check reads `.Image`,
  which is the image **ID** rather than `.Config.Image` or `RepoDigests`, so a container built from a mutable bare
  tag passes it.
- **Duplicated service definitions.** This file copies trimmed `kaspad` and `execution-layer` definitions from
  `docker-compose.yml` rather than inheriting them, so the mainnet stack can change without silently changing what
  runs on a signer host. CI asserts the guards that must not disappear; entrypoint changes in the mainnet file still
  need mirroring by hand.
- **Until the third release gate lands, reth writes ~1 GB of debug-level logs onto the data filesystem.** Tracked
  as a gate above rather than accepted here, because the fix is one launcher flag on a release already required.
- **The container hardening is untested against these images.** All three services run `user: "1000:1000"`,
  `read_only: true`, `cap_drop: ["ALL"]`, `no-new-privileges`, `apparmor=docker-default` and a `pids_limit` —
  matching the bar a hardened co-tenant is normally held to, because co-location's whole risk is an escape
  landing on the machine that holds the signing credential. None of it could be exercised here: both required
  images are unreleased. The reasoning is that neither service binds a privileged port (so `cap_drop: ALL` costs
  nothing), and every write path is a bind mount or tmpfs (so a read-only root is viable) — but that is reasoning,
  not a test. If a container fails at start during first bring-up, relax **one** key on the affected service, note
  which, and file it; do not remove the whole block.
- **Memory limits are deliberately not per-container.** `MemoryHigh`/`MemoryMax` live in the `igra-rpc.slice` unit
  because they are stack-wide numbers; setting `mem_limit` on each of three services would grant the stack roughly
  three times the intended budget. `pids_limit` is per-container because it does not aggregate that way.
- **Isolation is permanently weakened.** Co-locating this stack with the signer means a container or kernel escape
  reaches the host. That is an accepted trade-off recorded outside this repository, not something this
  configuration can close.
