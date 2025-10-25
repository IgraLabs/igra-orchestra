#!/usr/bin/env bash
set -euo pipefail

# Daily
# 2 nodes with fresh daa - aka live -  (don't download data) and 1 node with historical data (same as caravel so it must download data)
# so let's use fresh env 
# if the nodes are live, then they must use the same DAA. if 
# on-merge to staging branch

APP_NAME="kaspa-wallet-sweeper"
PKG_NAME="kaspa-cli-sweeper"
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
name = "kaspa-cli-sweeper"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1.45", features = ["full"] }
kaspa-wrpc-client = "0.15"
kaspa-wallet-core = "0.15"
kaspa-rpc-core = "0.15"
kaspa-consensus-core = "0.15"
workflow-core = "0.18"
futures = "0.3"
thiserror = "1.0"
EOF_CARGO

    # src/main.rs
    mkdir -p "$SRC_DIR"
    cat >"$SRC_DIR/main.rs" <<'EOF_MAIN'
use kaspa_consensus_core::network::NetworkId;
use kaspa_wallet_core::{
    prelude::*,
    rpc::Rpc,
};
use kaspa_wrpc_client::KaspaRpcClient;
use std::str::FromStr;
use std::sync::Arc;
use std::{env, io::Write};
use workflow_core::abortable::Abortable;

#[derive(Debug, thiserror::Error)]
enum SweepError {
    #[error("Wallet error: {0}")]
    Wallet(String),
    #[error("RPC error: {0}")]
    Rpc(String),
    #[error("No mature balance to sweep")]
    NoBalance,
}

#[tokio::main]
async fn main() -> Result<(), SweepError> {
    // Get configuration from environment
    let url = env::var("KASPA_WRPC_URL").unwrap_or_else(|_| "ws://localhost:17610".to_string());
    let wallet_name = env::var("WALLET_NAME").unwrap_or_else(|_| "kaspa".to_string());
    let password = env::var("WALLET_PASSWORD").unwrap_or_else(|_| "123456".to_string());
    let network_str = env::var("KASPA_NETWORK").unwrap_or_else(|_| "testnet-11".to_string());

    // Parse network ID directly (preserves suffix)
    let network_id = NetworkId::from_str(&network_str)
        .map_err(|e| SweepError::Wallet(format!("Invalid network '{}': {}", network_str, e)))?;

    println!("🔧 Configuration:");
    println!("  RPC URL: {}", url);
    println!("  Network: {}", network_str);
    println!("  Wallet name: {}", wallet_name);
    println!();

    // Create RPC client - SAME AS kaspa_daa_reader.sh
    let encoding = WrpcEncoding::Borsh;
    let rpc_client = Arc::new(
        KaspaRpcClient::new(encoding, Some(&url), None, Some(network_id), None)
            .map_err(|e| SweepError::Rpc(format!("Failed to create RPC client: {}", e)))?
    );

    // Connect to kaspad - SAME AS kaspa_daa_reader.sh
    let options = ConnectOptions {
        block_async_connect: true,
        connect_timeout: Some(std::time::Duration::from_secs(10)),
        strategy: ConnectStrategy::Fallback,
        ..Default::default()
    };

    println!("📡 Connecting to Kaspa node...");
    rpc_client.connect(Some(options)).await
        .map_err(|e| SweepError::Rpc(format!("Failed to connect: {}", e)))?;
    println!("✅ Connected to Kaspa node");
    println!();

    // Create Rpc wrapper
    let rpc_ctl = rpc_client.ctl().clone();
    let rpc_api: Arc<DynRpcApi> = rpc_client;
    let rpc = Rpc::new(rpc_api, rpc_ctl);

    // Create storage using Wallet::local_store()
    println!("🔐 Opening wallet storage...");
    let storage = Wallet::local_store()
        .map_err(|e| SweepError::Wallet(format!("Failed to create storage: {}", e)))?;

    // Create wallet instance with RPC and storage
    let wallet = Arc::new(
        Wallet::try_with_rpc(Some(rpc), storage.clone(), Some(network_id))
            .map_err(|e| SweepError::Wallet(format!("Failed to create wallet: {}", e)))?
    );

    // Start wallet services FIRST (before opening)
    println!("🚀 Starting wallet...");
    wallet.start().await
        .map_err(|e| SweepError::Wallet(format!("Failed to start wallet: {}", e)))?;

    // Open wallet by name
    println!("🔐 Opening wallet '{}'...", wallet_name);
    let wallet_secret = Secret::from(password.as_str());
    let open_args = WalletOpenArgs::default_with_legacy_accounts();
    let guard = wallet.guard();
    let guard_lock = guard.lock().await;

    wallet.open(&wallet_secret, Some(wallet_name.clone()), open_args, &guard_lock).await
        .map_err(|e| SweepError::Wallet(format!("Failed to open wallet: {}", e)))?;

    // Activate accounts (IMPORTANT: same as kaspa-cli does)
    println!("🔄 Activating accounts...");
    wallet.activate_accounts(None, &guard_lock).await
        .map_err(|e| SweepError::Wallet(format!("Failed to activate accounts: {}", e)))?;

    // Get accounts
    let accounts_stream = wallet.accounts(None, &guard_lock).await
        .map_err(|e| SweepError::Wallet(format!("Failed to get accounts: {}", e)))?;

    use futures::StreamExt;
    let accounts: Vec<_> = accounts_stream.collect().await;

    if accounts.is_empty() {
        return Err(SweepError::Wallet("No accounts found in wallet".to_string()));
    }

    let account = accounts[0].as_ref()
        .map_err(|e| SweepError::Wallet(format!("Failed to get account: {}", e)))?
        .clone();

    println!("✅ Using account: {}", account.name_or_id());

    // Wait for sync - poll balance until available (with timeout)
    println!("⏳ Waiting for wallet sync...");
    let mut retries = 0;
    let max_retries = 30;
    let balance = loop {
        if let Some(bal) = account.balance() {
            break bal;
        }
        tokio::time::sleep(std::time::Duration::from_secs(1)).await;
        retries += 1;
        if retries >= max_retries {
            return Err(SweepError::Wallet("Timeout waiting for balance sync".to_string()));
        }
        print!(".");
        std::io::stdout().flush().ok();
    };
    println!();
    println!();

    let kas_mature = balance.mature as f64 / 100_000_000.0;
    let kas_pending = balance.pending as f64 / 100_000_000.0;
    let kas_outgoing = balance.outgoing as f64 / 100_000_000.0;

    println!("💰 Wallet balance:");
    println!("  Mature: {} KAS ({} UTXOs)", kas_mature, balance.mature_utxo_count);
    println!("  Pending: {} KAS ({} UTXOs)", kas_pending, balance.pending_utxo_count);
    println!("  Outgoing: {} KAS", kas_outgoing);
    println!("  Stasis: {} UTXOs (immature coinbase)", balance.stasis_utxo_count);
    println!();

    if balance.mature == 0 {
        if balance.stasis_utxo_count > 0 {
            println!("⚠️  No mature balance to sweep");
            println!("   You have {} immature coinbase UTXOs in stasis", balance.stasis_utxo_count);
            println!("   These require 1000 blocks (DAA score difference) to mature");
            return Err(SweepError::NoBalance);
        } else {
            println!("⚠️  Wallet is empty");
            return Err(SweepError::NoBalance);
        }
    }

    println!("🧹 Consolidating {} KAS ({} UTXOs) to change address...", kas_mature, balance.mature_utxo_count);
    if balance.stasis_utxo_count > 0 {
        println!("   (Skipping {} immature coinbase UTXOs)", balance.stasis_utxo_count);
    }
    println!();

    // Get change address to send funds back to
    let change_address = account.change_address()
        .map_err(|e| SweepError::Wallet(format!("Failed to get change address: {}", e)))?;

    println!("📍 Change address: {}", change_address);
    println!();

    // Use send() with mature balance to avoid immature UTXOs
    // This consolidates UTXOs while keeping funds in the same wallet
    let payment_secret = None; // No payment secret for this wallet
    let abortable = Abortable::default();

    // Send mature balance back to our own change address (consolidation)
    // Reduce amount by a small margin to avoid immature coinbase edge cases
    // With many mining rewards, some "mature" UTXOs may not be fully mature (1000 blocks)
    let safety_margin = balance.mature / 1000; // 0.1% safety margin
    let send_amount = balance.mature.saturating_sub(safety_margin).saturating_sub(100_000_000); // Also subtract 1 KAS minimum

    let kas_to_send = send_amount as f64 / 100_000_000.0;
    println!("💡 Sending {} KAS (leaving small buffer to avoid immature UTXOs)", kas_to_send);
    println!();

    let outputs = PaymentOutputs::from((change_address.clone(), send_amount));

    let (summary, tx_ids) = account
        .send(
            outputs.into(),          // Destination: our own change address
            Fees::SenderPays(0),     // Sender pays fees (no priority fee)
            payment_secret,          // payment_secret
            wallet_secret.clone(),   // wallet_secret
            None,                    // payload
            &abortable,              // abortable
            None,                    // notifier
        )
        .await
        .map_err(|e| {
            let error_msg = e.to_string();
            if error_msg.contains("immature") || error_msg.contains("coinbase") {
                SweepError::Wallet(format!(
                    "Consolidation failed due to immature UTXOs:\n{}\n\n\
                    Coinbase rewards require 1000 blocks to mature.\n\
                    Wait for more blocks and try again.",
                    error_msg
                ))
            } else {
                SweepError::Wallet(format!("Consolidation failed: {}", error_msg))
            }
        })?;

    println!("✅ Consolidation successful!");
    println!();
    println!("📝 Transaction summary:");
    println!("  {}", summary);
    println!();
    println!("Transaction IDs:");
    for (idx, tx_id) in tx_ids.iter().enumerate() {
        println!("  {}. {}", idx + 1, tx_id);
    }

    std::io::stdout().flush().ok();

    // Stop wallet
    wallet.stop().await
        .map_err(|e| SweepError::Wallet(format!("Failed to stop wallet: {}", e)))?;

    Ok(())
}
EOF_MAIN
}

calc_hash() {
    if command -v sha256sum >/dev/null 2>&1; then
        (cat "$MANIFEST_PATH" 2>/dev/null || echo ""; cat "$SRC_DIR/main.rs" 2>/dev/null || echo "") | sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        (cat "$MANIFEST_PATH" 2>/dev/null || echo ""; cat "$SRC_DIR/main.rs" 2>/dev/null || echo "") | shasum -a 256 | awk '{print $1}'
    else
        echo "error: neither sha256sum nor shasum found" >&2
        exit 1
    fi
}

needs_rebuild() {
    write_sources
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
        echo "🔨 Building kaspa-wallet-sweeper (this may take a few minutes on first run)..."
        (cd "$CACHE_DIR" && cargo build --release --quiet 2>&1 | grep -v "warning:" || true)
        echo "✅ Build complete"
        echo ""
    fi
}

show_usage() {
    cat <<EOF
Usage: kaspa_wallet_sweeper.sh

Consolidates all mature UTXOs in an existing Kaspa wallet by sweeping them back
to the wallet's change address. This reduces UTXO count and optimizes future transactions.

Optional environment variables:
  KASPA_WRPC_URL     - Kaspa WRPC endpoint (default: ws://localhost:17610)
  WALLET_NAME        - Wallet name (default: kaspa)
  WALLET_PASSWORD    - Wallet password (default: 123456)
  KASPA_NETWORK      - Network type (default: testnet-11)

Example:
  WALLET_NAME="kaspa" \\
  WALLET_PASSWORD="123456" \\
  KASPA_NETWORK="testnet-10" \\
  KASPA_WRPC_URL="ws://localhost:17210" \\
  ./kaspa_wallet_sweeper.sh

Note: This script connects directly to kaspad (NOT kaswallet).
      Funds stay in YOUR wallet - they are consolidated to your change address.
      Only mature UTXOs will be swept. Immature coinbase rewards
      (requiring 1000 blocks to mature) will be skipped automatically.
EOF
}

main() {
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi

    ensure_tools
    mkdir -p "$CACHE_DIR"
    build_if_needed
    exec "$BIN_PATH" "$@"
}

main "$@"
