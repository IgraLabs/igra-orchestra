# IGRA Orchestra

A Docker Compose-based deployment environment for IGRA Orchestra components.

## Getting Started

Choose your deployment guide:

- **[Mainnet](quick-setup-mainnet.md)** - Public mainnet deployment with pre-built images
- **[Galleon Testnet](quick-setup-galleon-testnet.md)** - Public Galleon testnet deployment with pre-built images

## Operations

- **[Node Operations](node-operations/index.md)** - Worker config, wallet API, balance monitoring, health checks, ATAN-only mode, and external CPU mining
- **[Reth Upgrade: 1.9.3 → 2.5.1](node-operations/upgrade-reth-1.9-to-2.5.md)** - Drop the execution-layer database and resync when `RETH_VERSION` moves to the `2.5.1-igra.<n>` line; kaspad data is preserved (24+ hours, L2 RPC offline)
- **[Kaspa Wallet Guide](kaspa-wallet.md)** - Wallet setup and management for all networks
- **[Log Management](log-management.md)** - Automated log cleanup for servers

## Troubleshooting

- **[Docker Volume Permissions](troubleshooting/docker-volume-permissions.md)** - Fix permission denied errors
- **[Kaspad DB Upgrade Prompt](troubleshooting/kaspad-db-upgrade.md)** - Run the one-time noninteractive kaspad DB metadata upgrade
- **[Service Restart Debugging](troubleshooting/service-restart-debugging.md)** - Diagnose fail-fast exits, restart loops, and Docker log persistence
- **[SSL Certificate Issues](troubleshooting/ssl-certificate.md)** - Fix Traefik certificate resolver errors

## Requirements

- Docker Engine 23.0+ and Docker Compose V2+
- At least 32GB RAM (recommended for production)
- Git and SSH access to github.com

## Quick Start

For the fastest setup, use the automated scripts:

```bash
# IGRA Mainnet
./scripts/setup-mainnet.sh

# Galleon Testnet
./scripts/setup-galleon-testnet.sh
```

For full details, see the [README on GitHub](https://github.com/IgraLabs/igra-orchestra).
