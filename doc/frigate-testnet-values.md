# Frigate Testnet Pending Values

Frigate (`testnet-12`) is not launch-ready until every `TODO_TN12_*_REPLACE_ME`
value has been replaced in the rendered `.env`.

Use this file as the tracked checklist for values that must be published before
operators can run `scripts/setup-frigate-testnet.sh` through service startup.

## Chain Parameters

- `IGRA_CHAIN_ID`
- `IGRA_LAUNCH_DAA_SCORE`
- `GENESIS_BLOCK_HASH`
- `TX_ID_PREFIX`
- `L1_REFERENCE_TIMESTAMP`
- `L1_REFERENCE_DAA_SCORE`
- `MIN_PROTOCOL_FEE_PER_GAS_GWEI`
- `IGRA_ENTRY_MIN_AMOUNT`
- `IGRA_LOCK_SCRIPT_PUBKEY`
- `EL_ONE_TIME_ADDRESS`
- `BITCOIN_BLOCK_HASH`
- `ETHEREUM_BLOCK_HASH`
- `KASPA_BLOCK_HASH`

## Operations Values

- `HEALTH_CHECK_API_KEY`
- `NODE_HEALTH_CHECK_URL`
- Frigate RPC load balancer hostname, once published

## Image Versions

- `KASPAD_VERSION`
- `RETH_VERSION`
- `KASWALLET_VERSION`
- `RPC_PROVIDER_VERSION`
- `NODE_HEALTH_CHECK_VERSION`
- `ATAN_UPLOADER_VERSION`
