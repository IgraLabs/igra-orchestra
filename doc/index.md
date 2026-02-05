# IGRA Orchestra

A Docker Compose-based deployment environment for IGRA Orchestra components.

## Getting Started

Choose your deployment guide:

- **[Galleon Testnet](quick-setup-galleon-testnet.md)** - Public testnet deployment with pre-built images
- **[Galleon Mainnet](quick-setup-galleon-mainnet.md)** - Public mainnet deployment with pre-built images

## Operations

- **[Kaspa Wallet Guide](kaspa-wallet.md)** - Wallet setup and management for all networks
- **[Log Management](log-management.md)** - Automated log cleanup for servers

## Troubleshooting

- **[Docker Volume Permissions](troubleshooting/docker-volume-permissions.md)** - Fix permission denied errors
- **[SSL Certificate Issues](troubleshooting/ssl-certificate.md)** - Fix Traefik certificate resolver errors

## Requirements

- Docker Engine 23.0+ and Docker Compose V2+
- At least 32GB RAM (recommended for production)
- Git and SSH access to github.com

## Quick Start

For the fastest setup, use the automated scripts:

```bash
# Testnet
./scripts/setup-galleon-testnet.sh

# Mainnet
./scripts/setup-galleon-mainnet.sh
```

For full details, see the [README on GitHub](https://github.com/IgraLabs/igra-orchestra).
