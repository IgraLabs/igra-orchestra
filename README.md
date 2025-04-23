# Igra Orchestra Setup Guide

## Overview

IGRA Orchestra orchestrates a modular system of services that together support the IGRA Devnet protocol. It includes:

### 🧠 IGRA Core Services
- **block-builder** — L2 block producer ([GitHub](https://github.com/IgraLabs/block-builder))
- **execution-layer** — reth-based L2 execution layer ([GitHub](https://github.com/IgraLabs/execution-layer))
- **rpc-provider** — RPC provider for user interactions ([GitHub](https://github.com/IgraLabs/igra-rpc-provider))
- **kaswallet** — L1 wallet acting as transaction relayer ([GitHub](https://github.com/IgraLabs/kaswallet))
- **viaduct** — extracts L2-relevant data from L1  ([GitHub](https://github.com/IgraLabs/rusty-kaspa-private))

### 🔌 Extensions (Optional)
- **KASPA Explorer** — set of services of the L1 block explorer
- **Dynamic workers** — additional `rpc-provider + kaswallet` instances

This guide explains how to set up and run the full system in a local development environment.

---

## Prerequisites

- Git
- Docker & Docker Compose v2+
- SSH access to Igralabs GitHub repositories

---

## Setup

### 1. Clone the Repository

```bash
git clone git@github.com:IgraLabs/igra-orchestra.git
cd igra-orchestra
```

### 2. Create JWT Secret

Used for authentication between block-builder and execution-layer.

```bash
mkdir -p keys
openssl rand -hex 32 > keys/jwt.hex
chmod 600 keys/jwt.hex
```

### 3. Clone Required Repositories

Run the setup script to clone dependent services repos.

```bash
chmod +x setup-repos.sh

# Use default branches ..
./setup-repos.sh

# .. or specific branches
# for: block-builder, execution-layer, kaswallet, igra-rpc-provider, rusty-kaspa
./setup-repos.sh main main main dev featureX
```

---

## Configuration

### 🔐 Wallet Key Files

Each `kaswallet` instance (core or worker) requires a distinct JSON key file:

- **Core** wallet: `keys.core.json`
- **Worker 1** wallet: `keys.kaswallet-0.json`
- **Worker 2** wallet: `keys.kaswallet-1.json`
- **Worker 3** wallet: `keys.kaswallet-2.json` (and so on)

Each is mounted as `/app/keys.json` inside the container.

Default keys are provided, but you can create and fund with KAS your own if needed.

---

## Running Services

### 🔧 Start Core Services

```bash
devnet.sh up
```

This launches all core components: `execution-layer`, `block-builder`, `viaduct`, `rpc-provider`, `kaswallet`, `traefik`.

### 🔁 Start With N Workers

```bash
devnet.sh with-workers 1 2 3
```

This brings up additional `rpc-provider-N` + `kaswallet-N` containers behind the load balancer.

### 🧼 Stop Everything

```bash
devnet.sh down
```

Or to clean all containers/volumes:

```bash
devnet.sh clean
```

---

## Access Control & Routing

### 🔑 Access Tokens

RPC requests URLs must begin with a valid access token, e.g.:

```
http://localhost:8545/9fb27a48631c486b9e5937ac140829d6/eth_call
```

There are 10 supported tokens. Traefik strips the token and forwards the request to an available worker.

---

## Component Overview

- **execution-layer**: reth node with custom genesis, JWT-auth secured
- **block-builder**: signs L2 blocks using `jwt.hex`, exposed on port 8561
- **rpc-provider**: validates transactions and proxies Ethereum RPC
- **kaswallet**: submits valid transactions to L1 via WebSocket
- **viaduct**: tracks KASPA DAG and drives forward sync
- **traefik**: validates token routes and balances requests
- **KASPA explorer** *(optional)*: browser frontend and REST/WS backend

---

## Troubleshooting

### 🚫 Missing Keys

```bash
devnet.sh with-workers 1 2
# => ❌ Missing key file: ../keys.worker2.json
```

Each `kaswallet` must have its corresponding key file.

Ensure `jwt.hex` has the mode 600.

Check files exist, they are accessible, files paths in `docker-compose.*.yml` files match your directory structure.


### 🔄 Volume Mount Issues

- Ensure `keys/*.json` and `keys/jwt.hex` exist
- Use absolute or relative paths properly
- `chmod 600 keys/jwt.hex`

---

## License

[TODO]
