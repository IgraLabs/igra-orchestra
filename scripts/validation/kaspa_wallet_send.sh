#!/usr/bin/env bash
set -euo pipefail

APP_NAME="kaspa-wallet-send"
PKG_NAME="kaspa-wallet-send"
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
name = "kaspa-wallet-send"
version = "0.1.0"
edition = "2021"

[dependencies]
tokio = { version = "1.45", features = ["full"] }
kaspa-wrpc-client = "0.15"
kaspa-wallet-core = "0.15"
kaspa-rpc-core = "0.15"
kaspa-addresses = "0.15"
kaspa-consensus-core = "0.15"
workflow-core = "0.18"
futures = "0.3"
thiserror = "1.0"
EOF_CARGO

    # src/main.rs
    mkdir -p "$SRC_DIR"
    cat >"$SRC_DIR/main.rs" <<'EOF_MAIN'
use kaspa_addresses::Address;
use kaspa_consensus_core::network::{NetworkId, NetworkType};
use kaspa_wallet_core::{
    prelude::*,
    rpc::Rpc,
};
use kaspa_wrpc_client::KaspaRpcClient;
use std::sync::Arc;
use std::{env, io::Write};
use workflow_core::abortable::Abortable;

#[derive(Debug, thiserror::Error)]
enum SendError {
    #[error("Wallet error: {0}")]
    Wallet(String),
    #[error("RPC error: {0}")]
    Rpc(String),
    #[error("Missing required environment variable: {0}")]
    EnvVar(String),
    #[error("Invalid address: {0}")]
    Address(String),
    #[error("Invalid amount: {0}")]
    Amount(String),
    #[error("Invalid fee: {0}")]
    Fee(String),
    #[error("No mature balance available")]
    NoBalance,
}

#[tokio::main]
async fn main() -> Result<(), SendError> {
    // Get configuration from environment
    let url = env::var("KASPA_WRPC_URL").unwrap_or_else(|_| "ws://localhost:17610".to_string());
    let wallet_name = env::var("WALLET_NAME").unwrap_or_else(|_| "kaspa".to_string());
    let to_address = env::var("TO_ADDRESS")
        .map_err(|_| SendError::EnvVar("TO_ADDRESS".to_string()))?;
    let amount_str = env::var("AMOUNT_KAS")
        .map_err(|_| SendError::EnvVar("AMOUNT_KAS".to_string()))?;
    let fee_str = env::var("FEE_SOMPI").unwrap_or_else(|_| "0".to_string());
    let password = env::var("WALLET_PASSWORD").unwrap_or_else(|_| "123456".to_string());
    let network_str = env::var("KASPA_NETWORK").unwrap_or_else(|_| "testnet-11".to_string());

    // Parse amount (in KAS, convert to sompi)
    let amount_kas: f64 = amount_str.parse()
        .map_err(|e| SendError::Amount(format!("Failed to parse amount: {}", e)))?;
    let amount_sompi = (amount_kas * 100_000_000.0) as u64;

    // Parse fee (in sompi)
    let fee_sompi: u64 = fee_str.parse()
        .map_err(|e| SendError::Fee(format!("Failed to parse fee: {}", e)))?;

    // Parse network
    let network_type = match network_str.as_str() {
        "mainnet" => NetworkType::Mainnet,
        "testnet" | "testnet-10" => NetworkType::Testnet,
        "testnet-11" => NetworkType::Testnet,
        "devnet" => NetworkType::Devnet,
        _ => {
            eprintln!("Unknown network: {}, defaulting to testnet-11", network_str);
            NetworkType::Testnet
        }
    };
    let network_id = NetworkId::try_from(network_type)
        .map_err(|e| SendError::Wallet(format!("Invalid network: {}", e)))?;

    println!("🔧 Configuration:");
    println!("  RPC URL: {}", url);
    println!("  Network: {}", network_str);
    println!("  Wallet name: {}", wallet_name);
    println!("  To address: {}", to_address);
    println!("  Amount: {} KAS ({} sompi)", amount_kas, amount_sompi);
    println!("  Priority fee: {} sompi", fee_sompi);
    println!();

    // Parse destination address
    let destination = Address::try_from(to_address.as_str())
        .map_err(|e| SendError::Address(format!("Invalid destination address: {}", e)))?;

    // Create RPC client - SAME AS kaspa_daa_reader.sh
    let encoding = WrpcEncoding::Borsh;
    let rpc_client = Arc::new(
        KaspaRpcClient::new(encoding, Some(&url), None, Some(network_id), None)
            .map_err(|e| SendError::Rpc(format!("Failed to create RPC client: {}", e)))?
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
        .map_err(|e| SendError::Rpc(format!("Failed to connect: {}", e)))?;
    println!("✅ Connected to Kaspa node");
    println!();

    // Create Rpc wrapper
    let rpc_ctl = rpc_client.ctl().clone();
    let rpc_api: Arc<DynRpcApi> = rpc_client;
    let rpc = Rpc::new(rpc_api, rpc_ctl);

    // Create storage using Wallet::local_store()
    println!("🔐 Opening wallet storage...");
    let storage = Wallet::local_store()
        .map_err(|e| SendError::Wallet(format!("Failed to create storage: {}", e)))?;

    // Create wallet instance with RPC and storage
    let wallet = Arc::new(
        Wallet::try_with_rpc(Some(rpc), storage.clone(), Some(network_id))
            .map_err(|e| SendError::Wallet(format!("Failed to create wallet: {}", e)))?
    );

    // Start wallet services FIRST (before opening)
    println!("🚀 Starting wallet...");
    wallet.start().await
        .map_err(|e| SendError::Wallet(format!("Failed to start wallet: {}", e)))?;

    // Open wallet by name
    println!("🔐 Opening wallet '{}'...", wallet_name);
    let wallet_secret = Secret::from(password.as_str());
    let open_args = WalletOpenArgs::default_with_legacy_accounts();
    let guard = wallet.guard();
    let guard_lock = guard.lock().await;

    wallet.open(&wallet_secret, Some(wallet_name.clone()), open_args, &guard_lock).await
        .map_err(|e| SendError::Wallet(format!("Failed to open wallet: {}", e)))?;

    // Activate accounts (IMPORTANT: same as kaspa-cli does)
    println!("🔄 Activating accounts...");
    wallet.activate_accounts(None, &guard_lock).await
        .map_err(|e| SendError::Wallet(format!("Failed to activate accounts: {}", e)))?;

    // Get accounts
    let accounts_stream = wallet.accounts(None, &guard_lock).await
        .map_err(|e| SendError::Wallet(format!("Failed to get accounts: {}", e)))?;

    use futures::StreamExt;
    let accounts: Vec<_> = accounts_stream.collect().await;

    if accounts.is_empty() {
        return Err(SendError::Wallet("No accounts found in wallet".to_string()));
    }

    let account = accounts[0].as_ref()
        .map_err(|e| SendError::Wallet(format!("Failed to get account: {}", e)))?
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
            return Err(SendError::Wallet("Timeout waiting for balance sync".to_string()));
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

    if balance.mature < amount_sompi {
        return Err(SendError::NoBalance);
    }

    println!("💸 Sending {} KAS to {}", amount_kas, to_address);
    println!();

    // Create payment output and destination
    let payment_output = PaymentOutput::new(destination, amount_sompi);
    let payment_destination = PaymentDestination::from(payment_output);

    let priority_fee = Fees::SenderPays(fee_sompi);
    let payment_secret = None;
    let payload = None;
    let abortable = Abortable::default();

    // Send the transaction
    let (summary, tx_ids) = account
        .send(
            payment_destination,
            priority_fee,
            None,  // fee_rate (use default)
            wallet_secret.clone(),
            payload,
            &abortable,
            payment_secret,
        )
        .await
        .map_err(|e| {
            let error_msg = e.to_string();
            if error_msg.contains("immature") || error_msg.contains("coinbase") {
                SendError::Wallet(format!(
                    "Send failed due to immature UTXOs:\n{}\n\n\
                    Coinbase rewards require 1000 blocks to mature.",
                    error_msg
                ))
            } else {
                SendError::Wallet(format!("Send failed: {}", error_msg))
            }
        })?;

    println!("✅ Transaction sent successfully!");
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
        .map_err(|e| SendError::Wallet(format!("Failed to stop wallet: {}", e)))?;

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
        echo "🔨 Building kaspa-wallet-send (this may take a few minutes on first run)..."
        (cd "$CACHE_DIR" && cargo build --release --quiet 2>&1 | grep -v "warning:" || true)
        echo "✅ Build complete"
        echo ""
    fi
}

show_usage() {
    cat <<EOF
Usage: kaspa_wallet_send.sh

Sends KAS from a wallet to a specified address using kaspa-wallet-core.
Uses the same approach as kaspa_daa_reader.sh (kaspa-wrpc-client + kaspa-wallet-core).

Required environment variables:
  TO_ADDRESS         - Destination Kaspa address
  AMOUNT_KAS         - Amount to send in KAS (e.g., "100.5")

Optional environment variables:
  KASPA_WRPC_URL     - Kaspa WRPC endpoint (default: ws://localhost:17610)
  WALLET_NAME        - Wallet name (default: kaspa)
  WALLET_PASSWORD    - Wallet password (default: 123456)
  KASPA_NETWORK      - Network type (default: testnet-11)
  FEE_SOMPI          - Priority fee in sompi (default: 0)

Example:
  TO_ADDRESS="kaspadev:qqqeharzns4r0tp4f8fmf95p42ymqcugq37ly93qrn3c95hqtm6tzmalhwan2" \\
  AMOUNT_KAS="1000" \\
  FEE_SOMPI="1000" \\
  WALLET_NAME="kaspa" \\
  WALLET_PASSWORD="123456" \\
  KASPA_NETWORK="devnet" \\
  ./kaspa_wallet_send.sh

Note: This script connects directly to kaspad (NOT kaswallet).
      Only mature UTXOs will be used. Amount is in KAS, fee is in sompi.
      1 KAS = 100,000,000 sompi
EOF
}

main() {
    if [[ "${1:-}" == "-h" ]] || [[ "${1:-}" == "--help" ]]; then
        show_usage
        exit 0
    fi

    if [[ -z "${TO_ADDRESS:-}" ]]; then
        echo "error: TO_ADDRESS environment variable is required" >&2
        echo "" >&2
        show_usage
        exit 1
    fi

    if [[ -z "${AMOUNT_KAS:-}" ]]; then
        echo "error: AMOUNT_KAS environment variable is required" >&2
        echo "" >&2
        show_usage
        exit 1
    fi

    ensure_tools
    mkdir -p "$CACHE_DIR"
    build_if_needed
    exec "$BIN_PATH" "$@"
}

main "$@"
