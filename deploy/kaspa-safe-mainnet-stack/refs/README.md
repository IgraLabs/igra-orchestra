# Mainnet Proposal Builder Reference Files

Put the real mainnet bridge reference files here before starting
proposal-builder:

- `kas-exit-bridge-contract-authenticity.expected.json`
- `kas-exit-bridge-query-audit-methodology.md`
- `checkpoint.initial.json`

These files must correspond to the real Igra L2 mainnet KasExitBridge,
Mailbox, MerkleTreeHook, and the selected starting checkpoint.

Safe API does not need these files. They are only mounted into the separate
proposal-builder Docker container.

The `keb.methodologySha256` value in `config/proposal-builder.json` must equal:

```bash
sha256sum refs/kas-exit-bridge-query-audit-methodology.md
```
