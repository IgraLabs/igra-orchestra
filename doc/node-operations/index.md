# Node Operations

Operational reference for running Igra Orchestra nodes.

- **[Worker Configuration](worker-configuration.md)** - Worker pairs, profiles, and scaling
- **[Wallet Management](wallet-management.md)** - Balance checking, address sync, and wallet balance API
- **[Health Check Integration](health-check.md)** - Monitoring, Slack alerts, and health check configuration
- **[ATAN-Only Mode](atan-only.md)** - Run kaspad saving finality periods without the full IGRA stack
- **[ATAN Verification](atan-verification.md)** - Verify stored post-KIP-21 finality-period archives with the offline `kaspa-atan-verify` tool
- **[Environment Reference](environment-reference.md)** - All operational environment variables
- **[Galleon → testnet-10 Migration](migrate-galleon-to-testnet-10.md)** - One-shot upgrade for existing Galleon operators on `NETWORK=testnet` to the uniform `NETWORK=testnet-10` schema (preserves IBD state)
- **[Reth Upgrade: 1.9.3 → 2.5.1](upgrade-reth-1.9-to-2.5.md)** - Drop the execution-layer database and resync when `RETH_VERSION` moves to the `2.5.1-igra.<n>` line; kaspad data is preserved (24+ hours, L2 RPC offline)
- **[Migrate keys to directory mounts](migrate-keys-to-directory-mounts.md)** - One-time per-node move of flat `keys.kaswallet-N.json` files into per-worker directories, required by the kaswallet 3.0.3 atomic `keys.json` save (avoids the single-file-mount `EBUSY` crash-loop)
- **[Running a CPU Miner](running-a-cpu-miner.md)** - Optionally produce Kaspa L1 blocks for an isolated local network with an external CPU miner
