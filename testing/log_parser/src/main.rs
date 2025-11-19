use clap::Parser;
use log_parser::Result;
use std::path::PathBuf;

/// Log parser for Zero Loss Validation
///
/// Continuously watches and processes IGRA event logs to transform them
/// into normalized artifacts for validation.
///
/// Processes IGRA-events-YYYY-MM-DD.ndjson files from the log directory.
/// These files contain both L1_TX_ELIGIBLE and L2_TX_INCLUDED events in NDJSON format.
///
/// EXAMPLE:
///   log_parser --logs-dir logs --artifacts-dir artifacts
#[derive(Parser, Debug)]
#[command(version, about, long_about = None)]
struct Args {
    /// Path to logs directory containing IGRA event files
    #[arg(long)]
    logs_dir: PathBuf,

    /// Path to artifacts output directory
    #[arg(long)]
    artifacts_dir: PathBuf,
}

#[tokio::main]
async fn main() -> Result<()> {
    tracing_subscriber::fmt::init();

    let args = Args::parse();

    log_parser::run(args.logs_dir, args.artifacts_dir).await
}
