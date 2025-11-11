#!/usr/bin/env bash
set -euo pipefail

APP_NAME="kaspa-daa-reader"
PKG_NAME="kaspa-cli-tools" # matches Cargo.toml [package].name
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/$APP_NAME"
SRC_DIR="$CACHE_DIR/src"
MANIFEST_PATH="$CACHE_DIR/Cargo.toml"
BIN_PATH="$CACHE_DIR/target/release/$PKG_NAME"
HASH_FILE="$CACHE_DIR/.src.sha256"

ensure_tools() {
    if ! command -v cargo >/dev/null 2>&1; then
        echo "error: cargo is required but not installed. Install Rust (https://rustup.rs) and retry." >&2
        exit 1
    fi
}

write_sources() {
    mkdir -p "$SRC_DIR"
    # Cargo.toml
    cat >"$MANIFEST_PATH" <<'EOF_CARGO'
[package]
name = "kaspa-cli-tools"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1.45", features = ["full"] }
kaspa-wrpc-client = "0.15"
kaspa-wallet-core = "0.15"
kaspa-rpc-core = "0.15"
EOF_CARGO

    # src/main.rs
    mkdir -p "$SRC_DIR"
    cat >"$SRC_DIR/main.rs" <<'EOF_MAIN'
use kaspa_rpc_core::GetBlockDagInfoResponse;
use kaspa_wallet_core::prelude::{ConnectOptions, ConnectStrategy, WrpcEncoding};
use kaspa_wrpc_client::{prelude::RpcApi, KaspaRpcClient};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{env, io::Write};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = env::var("KASPA_WRPC_URL").unwrap_or_else(|_| "ws://localhost:17210".to_string());
    let encoding = WrpcEncoding::Borsh;

    let client = KaspaRpcClient::new(encoding, Some(&url), None, None, None)?;

    let options = ConnectOptions {
        block_async_connect: true,
        connect_timeout: Some(Duration::from_secs(5)),
        strategy: ConnectStrategy::Fallback,
        ..Default::default()
    };

    client.connect(Some(options)).await?;

    let dag: GetBlockDagInfoResponse = client.get_block_dag_info().await?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    println!("virtual_daa_score: {}", dag.virtual_daa_score);
    println!("timestamp: {}", now);
    std::io::stdout().flush().ok();

    Ok(())
}
EOF_MAIN
}

calc_hash() {
    # Hash the embedded sources to trigger rebuilds when they change
    # macOS: use shasum -a 256; Linux often has sha256sum
    if command -v sha256sum >/dev/null 2>&1; then
        (printf '%s\n' "$(cat <<'EOS'
[package]
name = "kaspa-cli-tools"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1.45", features = ["full"] }
kaspa-wrpc-client = "0.15"
kaspa-wallet-core = "0.15"
kaspa-rpc-core = "0.15"
EOS
)"; printf '%s\n' "$(cat <<'EOS'
use kaspa_rpc_core::GetBlockDagInfoResponse;
use kaspa_wallet_core::prelude::{ConnectOptions, ConnectStrategy, WrpcEncoding};
use kaspa_wrpc_client::{prelude::RpcApi, KaspaRpcClient};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use std::{env, io::Write};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = env::var("KASPA_WRPC_URL").unwrap_or_else(|_| "ws://localhost:17210".to_string());
    let encoding = WrpcEncoding::Borsh;

    let client = KaspaRpcClient::new(encoding, Some(&url), None, None, None)?;

    let options = ConnectOptions {
        block_async_connect: true,
        connect_timeout: Some(Duration::from_secs(5)),
        strategy: ConnectStrategy::Fallback,
        ..Default::default()
    };

    client.connect(Some(options)).await?;

    let dag: GetBlockDagInfoResponse = client.get_block_dag_info().await?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs();
    println!("virtual_daa_score: {}", dag.virtual_daa_score);
    println!("timestamp: {}", now);
    std::io::stdout().flush().ok();

    Ok(())
}
EOS
)" ) | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        (printf '%s\n' "$(cat <<'EOS'
[package]
name = "kaspa-cli-tools"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1.45", features = ["full"] }
kaspa-wrpc-client = "0.15"
kaspa-wallet-core = "0.15"
kaspa-rpc-core = "0.15"
EOS
)"; printf '%s\n' "$(cat <<'EOS'
use kaspa_rpc_core::GetBlockDagInfoResponse;
use kaspa_wallet_core::prelude::{ConnectOptions, ConnectStrategy, WrpcEncoding};
use kaspa_wrpc_client::{prelude::RpcApi, KaspaRpcClient};
use std::time::Duration;
use std::{env, io::Write};

#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let url = env::var("KASPA_WRPC_URL").unwrap_or_else(|_| "ws://localhost:17210".to_string());
    let encoding = WrpcEncoding::Borsh;

    let client = KaspaRpcClient::new(encoding, Some(&url), None, None, None)?;

    let options = ConnectOptions {
        block_async_connect: true,
        connect_timeout: Some(Duration::from_secs(5)),
        strategy: ConnectStrategy::Fallback,
        ..Default::default()
    };

    client.connect(Some(options)).await?;

    let dag: GetBlockDagInfoResponse = client.get_block_dag_info().await?;
    println!("virtual_daa_score: {}", dag.virtual_daa_score);
    println!("timestamp: {}", dag.timestamp);
    std::io::stdout().flush().ok();

    Ok(())
}
EOS
)" ) | shasum -a 256 | awk '{print $1}'
    else
        echo "error: neither sha256sum nor shasum found" >&2
        exit 1
    fi
}

needs_rebuild() {
    local new_hash
    new_hash="$(calc_hash)"
    if [[ ! -f "$HASH_FILE" ]]; then
        echo "$new_hash" >"$HASH_FILE"
        return 0
    fi
    local old_hash
    old_hash="$(cat "$HASH_FILE" 2>/dev/null || true)"
    if [[ "$new_hash" != "$old_hash" ]]; then
        echo "$new_hash" >"$HASH_FILE"
        return 0
    fi
    if [[ ! -x "$BIN_PATH" ]]; then
        return 0
    fi
    return 1
}

build_if_needed() {
    if needs_rebuild; then
        write_sources
        (cd "$CACHE_DIR" && cargo build --release)
    fi
}

main() {
    ensure_tools
    mkdir -p "$CACHE_DIR"
    build_if_needed
    exec "$BIN_PATH" "$@"
}

main "$@"


