#!/usr/bin/env bash
set -euo pipefail

network="${NETWORK:-devnet}"
kaspad_rpc_host="${KASPAD_RPC_HOST:-kaspad}"
kaspad_grpc_port="${KASPAD_GRPC_PORT:-16610}"
wallet_password="${WALLET_PASSWORD:-stage-msig-pass}"

mkdir -p /work/wallets /work/logs /work/results

network_flag=""
if [[ "${network}" != "mainnet" ]]; then
    network_flag="--${network}"
fi

echo "wallet-tools: waiting for /work/wallets/metadata.json"
while [[ ! -f /work/wallets/metadata.json ]]; do
    sleep 1
done

echo "wallet-tools: starting signer wallet daemons"
for index in 0 1 2; do
    port=$((8082 + index))
    keys_file="/work/wallets/signer-${index}.keys.json"
    if [[ ! -f "${keys_file}" ]]; then
        echo "wallet-tools: missing ${keys_file}" >&2
        exit 1
    fi

    /usr/local/bin/kaspawallet ${network_flag} start-daemon \
        --keys-file "${keys_file}" \
        --password "${wallet_password}" \
        --rpcserver "${kaspad_rpc_host}:${kaspad_grpc_port}" \
        --listen "0.0.0.0:${port}" \
        --wait-timeout 60 \
        >"/work/logs/wallet-${index}.log" 2>&1 &
    echo "$!" >"/work/logs/wallet-${index}.pid"
done

echo "wallet-tools: daemons started"
wait -n
