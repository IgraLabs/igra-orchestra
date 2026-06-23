# IGRA Orchestra

A Docker Compose-based deployment environment for IGRA Orchestra components.

## Getting Started

Choose your deployment guide:

- **[Mainnet](quick-setup-mainnet.md)** - Public mainnet deployment with pre-built images
- **[Galleon Testnet](quick-setup-galleon-testnet.md)** - Public Galleon testnet deployment with pre-built images

## Operations

- **[Node Operations](node-operations/index.md)** - Worker config, wallet API, balance monitoring, health checks, ATAN-only mode, and external CPU mining
- **[Toccata Upgrade — Part One: Mainnet v2.3 → v3.0](node-operations/upgrade-mainnet-v2.3-to-v3.0.md)** - Part one of the Toccata (KIP-21) upgrade: bring the backend (kaspad/reth) to v3.0 before the fork while workers stay on 2.3 (reconcile `.env`, preserve volumes)
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
