# Proposal Builder Reference Files

Put federation-specific proposal-builder reference files here before starting
the `proposal-builder` service:

- `kas-exit-bridge-contract-authenticity.expected.json`
- `kas-exit-bridge-query-audit-methodology.md`
- `checkpoint.initial.json`

The Safe API does not need these files. They are only used by the Rust
proposal-builder daemon.

The `methodologySha256` value in `config/proposal-builder.json` must match the
SHA-256 of `kas-exit-bridge-query-audit-methodology.md`.
