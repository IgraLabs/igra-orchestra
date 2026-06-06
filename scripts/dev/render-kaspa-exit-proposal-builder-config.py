#!/usr/bin/env python3
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path


CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l"
GENERATOR = [0x98F2BC8E61, 0x79B76D99E2, 0xF33E5FB3C4, 0xAE2EABE2A8, 0x1E4F43E470]


def log(message):
    print(f"[render-builder-config] {message}")


def die(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


def env(name, default=""):
    return os.environ.get(name, default)


def load_env(path):
    if not path.exists():
        return
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        os.environ.setdefault(key, value.strip().strip("\"'"))


def load_json(path):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        die(f"missing required file: {path}")
    except json.JSONDecodeError as exc:
        die(f"invalid JSON in {path}: {exc}")


def write_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2) + "\n")


def polymod(values):
    chk = 1
    for value in values:
        top = chk >> 35
        chk = ((chk & 0x07FFFFFFFF) << 5) ^ value
        for index, generator in enumerate(GENERATOR):
            if (top >> index) & 1:
                chk ^= generator
    return chk


def prefix_expand(prefix):
    return [ord(char) & 0x1F for char in prefix] + [0]


def convert_bits(data, from_bits, to_bits, pad=False):
    acc = 0
    bits = 0
    result = []
    max_value = (1 << to_bits) - 1
    max_acc = (1 << (from_bits + to_bits - 1)) - 1
    for value in data:
        if value < 0 or value >> from_bits:
            die("invalid Kaspa address payload value")
        acc = ((acc << from_bits) | value) & max_acc
        bits += from_bits
        while bits >= to_bits:
            bits -= to_bits
            result.append((acc >> bits) & max_value)
    if pad and bits:
        result.append((acc << (to_bits - bits)) & max_value)
    elif bits >= from_bits or ((acc << (to_bits - bits)) & max_value):
        die("invalid Kaspa address padding")
    return bytes(result)


def kaspa_p2sh_script_public_key(address):
    if ":" not in address:
        die(f"Kaspa address has no prefix: {address}")
    prefix, payload = address.lower().split(":", 1)
    try:
        data = [CHARSET.index(char) for char in payload]
    except ValueError as exc:
        die(f"invalid Kaspa address character in {address}: {exc}")
    if len(data) <= 8:
        die(f"Kaspa address payload is too short: {address}")
    if polymod(prefix_expand(prefix) + data) != 1:
        die(f"Kaspa address checksum failed: {address}")
    decoded = convert_bits(data[:-8], 5, 8)
    if len(decoded) != 33:
        die(f"expected 33-byte P2SH address payload, got {len(decoded)} bytes")
    version = decoded[0]
    if version != 8:
        die(f"expected Kaspa P2SH address version 8, got {version}")
    return "aa20" + decoded[1:].hex() + "87"


def ensure_file(path, description):
    if not path.is_file():
        die(f"{description} not found: {path}")


def maybe_copy_default_methodology(project_dir, target):
    if target.is_file():
        return
    source = project_dir / "tools/kasExitBridge/docs/kas-exit-bridge-query-audit-methodology.md"
    ensure_file(source, "vendored methodology")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, target)


def maybe_create_initial_checkpoint(path):
    if path.is_file():
        return
    block_tag = int(env("KASPA_EXIT_BUILDER_INITIAL_CHECKPOINT_BLOCK", "0"))
    write_json(
        path,
        {
            "version": 1,
            "blockTag": block_tag,
            "sourceRange": {
                "fromBlock": 0,
                "toBlock": block_tag,
                "startStateBlock": 0,
                "endStateBlock": block_tag,
            },
        },
    )


def resolve_project_path(project_dir, path):
    path = Path(path)
    if path.is_absolute():
        return path
    return project_dir / path


def resolve_runtime_path(project_dir, work_dir, value):
    value = str(value)
    if value == "/work":
        return work_dir, value
    if value.startswith("/work/"):
        return work_dir / value[len("/work/") :], value
    path = Path(value)
    if path.is_absolute():
        return path, value
    host_path = project_dir / path
    return host_path, str(host_path)


def main():
    script_dir = Path(__file__).resolve().parent
    project_dir = script_dir.parent.parent
    env_file = Path(env("ORCHESTRA_ENV_FILE", project_dir / ".env.kaspa-exit-devnet"))
    if not env_file.is_absolute():
        env_file = project_dir / env_file
    load_env(env_file)

    work_dir = project_dir / "build/kaspa-exit-devnet"
    wallet_metadata = load_json(work_dir / "wallets/metadata.json")
    federation_file, _ = resolve_runtime_path(
        project_dir,
        work_dir,
        env("KASPA_FEDERATION_ID_FILE", "/work/results/federation.json"),
    )
    federation = load_json(federation_file)

    out_path, _ = resolve_runtime_path(
        project_dir,
        work_dir,
        env("IGRA_PROPOSAL_BUILDER_CONFIG", "/work/proposal-builder/builder.json"),
    )

    bridge_address = env("KASPA_EXIT_BUILDER_BRIDGE_ADDRESS") or wallet_metadata.get("custodyAddress") or wallet_metadata.get("canonicalAddress")
    if not bridge_address:
        die("bridge address not found; run real-spend-e2e first or set KASPA_EXIT_BUILDER_BRIDGE_ADDRESS")

    bridge_script = (
        env("KASPA_EXIT_BUILDER_BRIDGE_SCRIPT_PUBLIC_KEY")
        or kaspa_p2sh_script_public_key(bridge_address)
    ).removeprefix("0x").lower()
    derivation_path = env("KASPA_EXIT_BUILDER_DERIVATION_PATH") or wallet_metadata.get("canonicalPath") or "m/0/0/1"
    xpubs = wallet_metadata.get("xpubs") or federation.get("xpubs")
    if not xpubs:
        die("federation xpubs not found in wallet metadata or federation file")

    expected_values, expected_values_runtime = resolve_runtime_path(
        project_dir,
        work_dir,
        env(
            "KASPA_EXIT_BUILDER_EXPECTED_VALUES_FILE",
            "/work/proposal-builder/kas-exit-bridge-contract-authenticity.expected.json",
        ),
    )
    methodology, methodology_runtime = resolve_runtime_path(
        project_dir,
        work_dir,
        env(
            "KASPA_EXIT_BUILDER_METHODOLOGY_FILE",
            "/work/proposal-builder/kas-exit-bridge-query-audit-methodology.md",
        ),
    )
    checkpoint, checkpoint_runtime = resolve_runtime_path(
        project_dir,
        work_dir,
        env(
            "KASPA_EXIT_BUILDER_INITIAL_CHECKPOINT_FILE",
            "/work/proposal-builder/checkpoint.initial.json",
        ),
    )

    maybe_copy_default_methodology(project_dir, methodology)
    maybe_create_initial_checkpoint(checkpoint)
    ensure_file(expected_values, "contract expected-values file")
    ensure_file(methodology, "methodology file")
    ensure_file(checkpoint, "initial checkpoint file")

    methodology_hash = env("KASPA_EXIT_BUILDER_METHODOLOGY_SHA256") or hashlib.sha256(methodology.read_bytes()).hexdigest()
    federation_id = env("KASPA_FEDERATION_ID") or federation.get("id") or federation.get("federationId")

    config = {
        "network": env("NETWORK", wallet_metadata.get("network", "devnet")),
        "l2ChainId": int(env("IGRA_CHAIN_ID", "38833")),
        "igraRpcUrl": env("KASPA_EXIT_BUILDER_IGRA_RPC_URL", "http://execution-layer:8545"),
        "safeApiUrl": env("KASPA_EXIT_BUILDER_SAFE_API_URL", "http://kaspa-safe-api:8888/api/v1/kaspa"),
        "federationId": federation_id,
        "proposedBy": env("KASPA_EXIT_BUILDER_PROPOSED_BY", "igra-proposal-builder-rs-devnet"),
        "contracts": {
            "kasExitBridge": env("KASPA_EXIT_BRIDGE_ADDRESS", "0x0000000000000000000000000000000000000000"),
            "mailbox": env("KASPA_EXIT_MAILBOX_ADDRESS", "0x0000000000000000000000000000000000000000"),
            "merkleTreeHook": env("KASPA_EXIT_MERKLE_TREE_HOOK_ADDRESS", "0x0000000000000000000000000000000000000000"),
        },
        "bridge": {
            "address": bridge_address,
            "scriptPublicKey": bridge_script,
            "derivationPath": derivation_path,
            "threshold": int(wallet_metadata.get("threshold") or federation.get("threshold") or env("KASPA_E2E_THRESHOLD", "2")),
            "ecdsa": False,
            "kpubs": xpubs,
        },
        "finality": {
            "confirmationBlocks": int(env("KASPA_EXIT_BUILDER_CONFIRMATION_BLOCKS", "12")),
        },
        "keb": {
            "expectedValuesFile": expected_values_runtime,
            "methodologyFile": methodology_runtime,
            "methodologySha256": methodology_hash,
            "initialCheckpointFile": checkpoint_runtime,
            "deltaBlocks": int(env("KASPA_EXIT_BUILDER_DELTA_BLOCKS", "86400")),
        },
        "kaspa": {
            "rpcUrl": env("KASPA_EXIT_BUILDER_KASPA_RPC_URL", "http://kaspad:18610"),
            "coinbaseMaturityDaa": int(env("KASPA_E2E_COINBASE_MATURITY_DAA", "1000")),
            "minConfirmationsDaa": int(env("KASPA_EXIT_BUILDER_MIN_CONFIRMATIONS_DAA", "0")),
            "minAmountSompi": int(env("KASPA_EXIT_BUILDER_MIN_AMOUNT_SOMPI", "0")),
            "maxInputs": int(env("KASPA_EXIT_BUILDER_MAX_INPUTS", "64")),
        },
        "pst": {
            "txIdPrefix": env("TX_ID_PREFIX", "97b1"),
            "maxPayloadNonceAttempts": int(env("KASPA_EXIT_BUILDER_MAX_PAYLOAD_NONCE_ATTEMPTS", "1000000")),
            "feeSompi": int(env("KASPA_EXIT_BUILDER_FEE_SOMPI", "1000000")),
            "allowPlaceholderPstForTests": False,
        },
        "state": {
            "path": "/work/proposal-builder/state.json",
        },
    }

    write_json(out_path, config)
    log(f"wrote {out_path}")
    log(f"bridge address: {bridge_address}")
    log(f"bridge scriptPublicKey: {bridge_script}")


if __name__ == "__main__":
    main()
