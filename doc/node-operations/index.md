# Node Operations

Operational reference for running Igra Orchestra nodes.

- **[Worker Configuration](worker-configuration.md)** - Worker pairs, profiles, and scaling
- **[Wallet Management](wallet-management.md)** - Balance checking, address sync, and wallet balance API
- **[Health Check Integration](health-check.md)** - Monitoring, Slack alerts, and health check configuration
- **[ATAN-Only Mode](atan-only.md)** - Run kaspad saving finality periods without the full IGRA stack
- **[ATAN Verification](atan-verification.md)** - Verify stored post-KIP-21 finality-period archives with the offline `kaspa-atan-verify` tool
- **[Environment Reference](environment-reference.md)** - All operational environment variables
- **[Galleon → testnet-10 Migration](migrate-galleon-to-testnet-10.md)** - One-shot upgrade for existing Galleon operators on `NETWORK=testnet` to the uniform `NETWORK=testnet-10` schema (preserves IBD state)
- **[Toccata Upgrade — Part One: Mainnet v2.3 → v3.0](upgrade-mainnet-v2.3-to-v3.0.md)** - Part one of the Toccata (KIP-21) upgrade for existing mainnet operators: bring the backend (kaspad/reth) to v3.0 before the fork while workers stay on 2.3 (reconciles `.env`; preserves volumes)
- **[Running a CPU Miner](running-a-cpu-miner.md)** - Optionally produce Kaspa L1 blocks for an isolated local network with an external CPU miner
