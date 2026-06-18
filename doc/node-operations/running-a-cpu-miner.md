# Running a CPU Miner

Optionally produce Kaspa L1 blocks yourself using an external CPU miner. In normal operation you do **not** need this — kaspad's integrated Igra adapter builds blocks, and on mainnet or a synced public testnet the network already provides hashrate. This runbook is for **local/dev scenarios**: an isolated devnet or a private testnet with no external miners, where the L1 DAG will not advance unless something mines it.

The miner is no longer bundled into the stack; run it out-of-band with [`kaspanet/cpuminer`](https://github.com/kaspanet/cpuminer).

## When to use

- You run an isolated local network (no DNS-seed peers, no external hashrate) and need blocks produced so L2 activity can proceed.
- You are testing block production or chain progression locally.

Do **not** run a CPU miner against mainnet or a healthy public testnet — it serves no purpose there and wastes CPU.

## Prerequisites

- A running `kaspad` (started with the `kaspad` or `backend` profile).
- Your network's gRPC port. kaspad serves gRPC on `KASPAD_GRPC_PORT` and publishes it to the host on `127.0.0.1` only:

  | Network | `KASPAD_GRPC_PORT` | Miner network flag | Payout address prefix |
  |---------|--------------------|--------------------|-----------------------|
  | mainnet | `16110` | _(none — default)_ | `kaspa:` |
  | testnet-10 (Galleon) | `16210` | `--testnet` | `kaspatest:` |
  | local devnet | `16210` | `--devnet` | `kaspadev:` |

- A payout (mining) address with the prefix matching your network. Generate one with the Kaspa wallet — see [Kaspa Wallet Guide](../kaspa-wallet.md).

## Get the miner

`kaspanet/cpuminer` is a Rust CPU miner; its binary is named `kaspa-miner`. Pick one:

- **Prebuilt binary** — download for your platform from the [releases page](https://github.com/kaspanet/cpuminer/releases).
- **Docker image**:

    ```bash
    docker pull kaspanet/cpuminer
    ```

- **Build from source** (Rust toolchain required):

    ```bash
    git clone https://github.com/kaspanet/cpuminer.git
    cd cpuminer
    cargo build --release
    # binary at target/release/kaspa-miner
    ```

## Run it

The simplest setup runs the miner on the **same host** as the stack, because kaspad's gRPC port is published to `127.0.0.1`. Point it at `127.0.0.1:<KASPAD_GRPC_PORT>` with the network flag and payout address that match your network. Example for testnet-10:

```bash
./kaspa-miner --testnet -s 127.0.0.1 -p 16210 -a kaspatest:YOUR_ADDRESS -t 2
```

Common flags (run `kaspa-miner --help` to confirm for your version):

| Flag | Meaning |
|------|---------|
| `-a, --mining-address` | Payout address (network-prefixed). Required. |
| `-s, --kaspad-address` | Node host/IP (default `127.0.0.1`). |
| `-p, --port` | Node gRPC port. Set to `KASPAD_GRPC_PORT`. |
| `-t, --threads` | Mining threads (default: all cores). Keep low for local testing. |
| `--testnet` / `--devnet` | Select the network (omit for mainnet). |
| `--mine-when-not-synced` | Mine before the node reports synced (see below). |

Always pass `-p` explicitly so it matches `KASPAD_GRPC_PORT`, rather than relying on the miner's per-network default.

### Running the miner in a container

To use the Docker image instead, attach it to the stack's Compose network and address kaspad by service name:

```bash
docker run --rm --network <project>_default kaspanet/cpuminer \
  --testnet -s kaspad -p 16210 -a kaspatest:YOUR_ADDRESS -t 2
```

Find the network name with `docker network ls` — it is `<compose-project>_default` (the project defaults to the directory name).

## Networking note

kaspad publishes its gRPC port as `127.0.0.1:${KASPAD_GRPC_PORT}` (see `docker-compose.yml`), so it is reachable only from the host, not the public network. Run the miner on the same host, attach it to the Compose network (above), or use an SSH tunnel from a remote machine. Do not expose the gRPC port publicly.

## Fresh / unsynced chains

On a brand-new local chain with no peers, kaspad will not hand out block templates until it considers itself synced. Pass `--mine-when-not-synced` to the miner to begin anyway. Note that the stack's kaspad does not enable unsynced mining on its own. On mainnet or a public testnet, simply wait for IBD to finish, then mine.

## Verify

- Miner logs report accepted/submitted blocks.
- kaspad's block count / DAA score increases — check the kaspad logs:

    ```bash
    docker compose logs -f kaspad
    ```

See [Environment Reference](environment-reference.md) for the full port list per network.

## Notes

- `kaspanet/cpuminer` is testnet/dev oriented. The upstream [README](https://github.com/kaspanet/cpuminer) and `kaspa-miner --help` are the source of truth for flags and supported versions; adjust the commands above if they differ.
- License: Apache-2.0 / MIT.
