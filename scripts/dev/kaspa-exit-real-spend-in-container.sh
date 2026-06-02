#!/usr/bin/env bash
set -euo pipefail

metadata="/work/wallets/metadata.json"
results_dir="/work/results"
logs_dir="/work/logs"
network="${NETWORK:-devnet}"
password="${WALLET_PASSWORD:-stage-msig-pass}"
api_base="${SAFE_API_BASE_URL:-http://kaspa-safe-api:8888/api/v1/kaspa}"
kaspad_rpc_host="${KASPAD_RPC_HOST:-kaspad}"
kaspad_grpc_port="${KASPAD_GRPC_PORT:-16610}"
kaspad_rpc="${kaspad_rpc_host}:${kaspad_grpc_port}"
spend_amount="${KASPA_E2E_SPEND_AMOUNT_KAS:-1}"
fee_rate="${KASPA_E2E_FEE_RATE:-1}"
coinbase_maturity="${KASPA_E2E_COINBASE_MATURITY_DAA:-1000}"
poll_seconds="${KASPA_E2E_POLL_SECONDS:-2}"

mkdir -p "${results_dir}" "${logs_dir}"

network_flag=""
if [[ "${network}" != "mainnet" ]]; then
    network_flag="--${network}"
fi

json_post() {
    local url="$1"
    local payload="$2"
    curl -fsS -H 'Content-Type: application/json' -X POST --data "${payload}" "${url}"
}

wait_tcp() {
    local host="$1"
    local port="$2"
    local label="$3"
    for _ in $(seq 1 180); do
        if nc -z "${host}" "${port}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "timed out waiting for ${label} at ${host}:${port}" >&2
    return 1
}

wait_http() {
    local url="$1"
    local label="$2"
    for _ in $(seq 1 180); do
        if curl -fsS "${url}" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    echo "timed out waiting for ${label} at ${url}" >&2
    return 1
}

wait_wallet() {
    local port="$1"
    local label="$2"
    for _ in $(seq 1 180); do
        if kaspawallet ${network_flag} balance --daemonaddress "127.0.0.1:${port}" >/tmp/wallet-balance.out 2>/tmp/wallet-balance.err; then
            return 0
        fi
        sleep 1
    done
    echo "timed out waiting for ${label}; last error:" >&2
    cat /tmp/wallet-balance.err >&2 || true
    return 1
}

balance_sompi() {
    local address="$1"
    kaspa-msig-fixture balance --rpc "${kaspad_rpc}" --address "${address}" | jq -r '.balanceSompi'
}

mature_balance_sompi() {
    local address="$1"
    local current_daa
    local utxos
    current_daa="$(kaspa-msig-fixture dag-info --rpc "${kaspad_rpc}" | jq -r '.virtualDaaScore')"
    utxos="$(kaspa-msig-fixture utxos --rpc "${kaspad_rpc}" --address "${address}")"
    jq -r \
        --argjson currentDaa "${current_daa}" \
        --argjson maturity "${coinbase_maturity}" \
        '[.entries[].utxoEntry
          | select((.isCoinbase | not) or ($currentDaa >= (.blockDaaScore + $maturity)))
          | .amount] | add // 0' <<<"${utxos}"
}

wait_mature_address_balance() {
    local address="$1"
    local min_sompi="$2"
    local label="$3"
    local mature="0"
    local total="0"
    for _ in $(seq 1 1200); do
        mature="$(mature_balance_sompi "${address}")"
        total="$(balance_sompi "${address}")"
        if [[ "${mature}" =~ ^[0-9]+$ ]] && (( mature >= min_sompi )); then
            echo "${mature}"
            return 0
        fi
        echo "waiting for ${label}: total=${total} mature=${mature} required=${min_sompi}" >&2
        sleep "${poll_seconds}"
    done
    echo "timed out waiting for ${label}; total=${total} mature=${mature}" >&2
    return 1
}

wait_address_balance() {
    local address="$1"
    local min_sompi="$2"
    local label="$3"
    local current="0"
    for _ in $(seq 1 240); do
        current="$(balance_sompi "${address}")"
        if [[ "${current}" =~ ^[0-9]+$ ]] && (( current >= min_sompi )); then
            echo "${current}"
            return 0
        fi
        sleep "${poll_seconds}"
    done
    echo "timed out waiting for ${label}; last balance ${current} sompi" >&2
    return 1
}

extract_bundle() {
    awk '/^[0-9a-fA-F]+(_[0-9a-fA-F]+)*$/ { value=$0 } END { if (value != "") print value }'
}

wait_tcp "${kaspad_rpc_host}" "${kaspad_grpc_port}" "kaspad gRPC"
wait_http "http://kaspa-safe-api:8888/check/" "safe-api"

for index in 0 1 2; do
    wait_tcp 127.0.0.1 "$((8082 + index))" "wallet daemon ${index}"
    wait_wallet "$((8082 + index))" "wallet daemon ${index}"
done

canonical_index="$(jq -r '.signers[] | select(.cosignerIndex == 0) | .index' "${metadata}")"
second_index="$(jq -r '([.signers[] | select(.cosignerIndex == 1) | .index] + [.signers[] | select(.cosignerIndex != 0) | .index])[0]' "${metadata}")"
canonical_port="$((8082 + canonical_index))"
recipient="$(jq -r '.recipient.address' "${metadata}")"
custody_address="$(jq -r '.custodyAddress // empty' "${metadata}")"

if [[ -z "${custody_address}" ]]; then
    echo "metadata does not contain custodyAddress; run the host e2e command first" >&2
    exit 1
fi

echo "custody address: ${custody_address}"
echo "recipient address: ${recipient}"

required_sompi="$(jq -nr --arg amount "${spend_amount}" '($amount | tonumber) * 100000000 | floor')"
custody_mature_balance="$(wait_mature_address_balance "${custody_address}" "${required_sompi}" "mature custody UTXOs")"
echo "mature custody balance: ${custody_mature_balance} sompi"

echo "creating Safe Transaction Service federation"
xpubs_json="$(jq -c '.xpubs' "${metadata}")"
participants_json="$(jq -c '[.signers[] | {name: ("signer-" + (.index|tostring) + "-cosigner-" + (.cosignerIndex|tostring)), xpub: .xpub}]' "${metadata}")"
federation_payload="$(jq -nc \
    --arg name "kaspa-exit-devnet-e2e" \
    --arg network "${network}" \
    --argjson threshold "$(jq -r '.threshold' "${metadata}")" \
    --argjson xpubs "${xpubs_json}" \
    --argjson participants "${participants_json}" \
    '{name: $name, network: $network, threshold: $threshold, xpubs: $xpubs, participants: $participants}')"

federation_response="$(json_post "${api_base}/federations/" "${federation_payload}" || true)"
if [[ -z "${federation_response}" || "$(printf '%s' "${federation_response}" | jq -r '.id // empty')" == "" ]]; then
    fingerprint="$(printf '%s' "${xpubs_json}" | jq -c 'sort' | sha256sum | awk '{print $1}')"
    federation_response="$(curl -fsS "${api_base}/federations/" \
        | jq --arg network "${network}" --arg fingerprint "${fingerprint}" \
          -c '.results[] | select(.network == $network and .xpubFingerprint == $fingerprint)' \
        | head -n 1)"
fi
federation_id="$(printf '%s' "${federation_response}" | jq -r '.id')"
if [[ -z "${federation_id}" || "${federation_id}" == "null" ]]; then
    echo "failed to create or find federation" >&2
    printf '%s\n' "${federation_response}" >&2
    exit 1
fi
printf '%s\n' "${federation_response}" > "${results_dir}/federation.json"

echo "creating unsigned spend proposal"
unsigned_bundle=""
for _ in $(seq 1 180); do
    set +e
    unsigned_output="$(kaspawallet ${network_flag} create-unsigned-transaction \
        --daemonaddress "127.0.0.1:${canonical_port}" \
        --to-address "${recipient}" \
        --from-address "${custody_address}" \
        --send-amount "${spend_amount}" \
        --fee-rate "${fee_rate}" 2>"${logs_dir}/create-unsigned.err")"
    status="$?"
    set -e
    if [[ "${status}" == "0" ]]; then
        unsigned_bundle="$(printf '%s\n' "${unsigned_output}" | extract_bundle)"
        if [[ -n "${unsigned_bundle}" ]]; then
            break
        fi
    fi
    sleep "${poll_seconds}"
done
if [[ -z "${unsigned_bundle}" ]]; then
    echo "failed to create unsigned transaction; last error:" >&2
    cat "${logs_dir}/create-unsigned.err" >&2 || true
    exit 1
fi
printf '%s\n' "${unsigned_bundle}" > "${results_dir}/unsigned-bundle.hex"

proposal_payload="$(jq -nc \
    --arg unsignedBundleHex "${unsigned_bundle}" \
    --arg proposedBy "signer-${canonical_index}" \
    '{unsignedBundleHex: $unsignedBundleHex, proposedBy: $proposedBy, origin: {source: "kaspa-exit-devnet-real-spend-e2e"}}')"
proposal_response="$(json_post "${api_base}/federations/${federation_id}/transactions/" "${proposal_payload}")"
proposal_hash="$(printf '%s' "${proposal_response}" | jq -r '.proposalHash')"
printf '%s\n' "${proposal_response}" > "${results_dir}/proposal-created.json"

echo "signing proposal with signer ${canonical_index}"
signed_one="$(kaspawallet ${network_flag} sign \
    --keys-file "/work/wallets/signer-${canonical_index}.keys.json" \
    --password "${password}" \
    --transaction "${unsigned_bundle}" 2>"${logs_dir}/sign-one.err" | extract_bundle)"
signature_one_payload="$(jq -nc --arg signedBundleHex "${signed_one}" --arg signer "signer-${canonical_index}" '{signedBundleHex: $signedBundleHex, signer: $signer}')"
signature_one_response="$(json_post "${api_base}/transactions/${proposal_hash}/signatures/" "${signature_one_payload}")"
merged_one="$(printf '%s' "${signature_one_response}" | jq -r '.mergedBundleHex')"
printf '%s\n' "${signature_one_response}" > "${results_dir}/proposal-after-signature-one.json"

echo "signing proposal with signer ${second_index}"
signed_two="$(kaspawallet ${network_flag} sign \
    --keys-file "/work/wallets/signer-${second_index}.keys.json" \
    --password "${password}" \
    --transaction "${merged_one}" 2>"${logs_dir}/sign-two.err" | extract_bundle)"
signature_two_payload="$(jq -nc --arg signedBundleHex "${signed_two}" --arg signer "signer-${second_index}" '{signedBundleHex: $signedBundleHex, signer: $signer}')"
signature_two_response="$(json_post "${api_base}/transactions/${proposal_hash}/signatures/" "${signature_two_payload}")"
proposal_status="$(printf '%s' "${signature_two_response}" | jq -r '.status')"
merged_two="$(printf '%s' "${signature_two_response}" | jq -r '.mergedBundleHex')"
printf '%s\n' "${signature_two_response}" > "${results_dir}/proposal-ready.json"
printf '%s\n' "${merged_two}" > "${results_dir}/merged-bundle.hex"
if [[ "${proposal_status}" != "ready" ]]; then
    echo "proposal did not become ready; status=${proposal_status}" >&2
    exit 1
fi

echo "broadcasting via Safe Transaction Service helper"
broadcast_payload="$(jq -nc --arg rpcUrl "${kaspad_rpc}" '{rpcUrl: $rpcUrl}')"
broadcast_response="$(json_post "${api_base}/transactions/${proposal_hash}/broadcast/" "${broadcast_payload}")"
printf '%s\n' "${broadcast_response}" > "${results_dir}/proposal-broadcasted.json"
broadcast_status="$(printf '%s' "${broadcast_response}" | jq -r '.status')"
if [[ "${broadcast_status}" != "broadcasted" ]]; then
    echo "proposal did not broadcast; status=${broadcast_status}" >&2
    exit 1
fi

recipient_balance="$(wait_address_balance "${recipient}" "${required_sompi}" "recipient receive")"
custody_balance_after="$(balance_sompi "${custody_address}")"
broadcast_tx_ids="$(printf '%s' "${broadcast_response}" | jq -c '.broadcastTxIds')"

jq -n \
    --arg federationId "${federation_id}" \
    --arg proposalHash "${proposal_hash}" \
    --arg custodyAddress "${custody_address}" \
    --arg recipientAddress "${recipient}" \
    --arg canonicalSigner "signer-${canonical_index}" \
    --arg secondSigner "signer-${second_index}" \
    --arg custodyMatureBalanceSompi "${custody_mature_balance}" \
    --arg custodyBalanceAfterSompi "${custody_balance_after}" \
    --arg recipientBalanceSompi "${recipient_balance}" \
    --argjson broadcastTxIds "${broadcast_tx_ids}" \
    '{
      ok: true,
      federationId: $federationId,
      proposalHash: $proposalHash,
      custodyAddress: $custodyAddress,
      recipientAddress: $recipientAddress,
      canonicalSigner: $canonicalSigner,
      secondSigner: $secondSigner,
      broadcastTxIds: $broadcastTxIds,
      custodyMatureBalanceSompi: ($custodyMatureBalanceSompi | tonumber),
      custodyBalanceAfterSompi: ($custodyBalanceAfterSompi | tonumber),
      recipientBalanceSompi: ($recipientBalanceSompi | tonumber)
    }' > "${results_dir}/e2e-result.json"

cat "${results_dir}/e2e-result.json"
