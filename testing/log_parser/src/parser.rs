use crate::constants::{
    DEBOUNCE_DURATION, FILE_WATCHER_CHANNEL_SIZE, FILE_WATCHER_POLL_INTERVAL, IDLE_WAIT_DURATION,
    MEMORY_LOG_INTERVAL,
};
use crate::error::{ParserError, Result};
use crate::io::{ArtifactWriters, LogMonitor};
use crate::models::{L1TxEligible, L2TxIncluded, LogEvent, Validate};
use crate::state::ParserState;
use notify::{Event, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::signal;
use tokio::sync::mpsc;

/// Manages debouncing state for file change notifications
struct DebounceState {
    pending_paths: HashSet<PathBuf>,
    last_event_time: Option<tokio::time::Instant>,
}

impl DebounceState {
    fn new() -> Self {
        Self {
            pending_paths: HashSet::new(),
            last_event_time: None,
        }
    }

    fn add_path(&mut self, path: PathBuf) {
        self.pending_paths.insert(path);
        self.last_event_time = Some(tokio::time::Instant::now());
    }

    fn has_pending(&self) -> bool {
        self.last_event_time.is_some()
    }

    fn calculate_delay(&self) -> Duration {
        match self.last_event_time {
            Some(last_time) => {
                let elapsed = last_time.elapsed();
                if elapsed >= DEBOUNCE_DURATION {
                    Duration::from_millis(0) // Ready to process now
                } else {
                    DEBOUNCE_DURATION - elapsed // Wait remaining time
                }
            }
            None => IDLE_WAIT_DURATION, // No pending changes, wait indefinitely
        }
    }

    fn clear(&mut self) {
        self.pending_paths.clear();
        self.last_event_time = None;
    }
}

/// Streaming log parser that watches log files and processes events in real-time
///
/// # Overview
///
/// This parser runs continuously, watching for new IGRA event log files and changes to existing files.
/// As events arrive, they are:
/// 1. Validated
/// 2. Written to artifact files (eligible_set.jsonl, included_set.jsonl)
/// 3. Stored in memory for L1/L2 matching
/// 4. Joined to create mapping records (mapping_log.csv)
///
/// # Architecture
///
/// ```text
/// File System Changes (notify crate)
///         ↓
///   File Watcher Thread
///         ↓
///   Async Channel (mpsc)
///         ↓
///   Event Loop (tokio::select!)
///         ↓
///   ┌─────┴─────┐
///   │ Debouncer │ (200ms delay to batch rapid changes)
///   └─────┬─────┘
///         ↓
///   Process Log Files
///         ↓
///   Read New Lines (position tracking)
///         ↓
///   Parse & Validate Events
///         ↓
///   ┌──────────┴──────────┐
///   │  L1_TX_ELIGIBLE     │  L2_TX_INCLUDED
///   ├─────────────────────┼────────────────────
///   │ Store in HashMap    │  Lookup L1 match
///   │ Write to JSONL      │  Write to JSONL
///   └─────────────────────┴────────────────────
///                         ↓
///                 Write Mapping (if match)
///                         ↓
///                    Flush to Disk
/// ```
///
/// # Error Handling
///
/// **IMPORTANT**: Any error during processing causes immediate shutdown.
/// This is critical for Zero-Loss testing - if errors occur, the test is invalid.
///
/// # Memory Management
///
/// Uses self-cleaning HashMap that removes matched L1 events (see `ParserState` docs).
/// Memory usage stays proportional to unmatched events. Unmatched count logged periodically.
///
pub struct Parser {
    log_dir: PathBuf,
    monitor: Arc<Mutex<LogMonitor>>,
    parser_state: Arc<Mutex<ParserState>>,
    writers: Arc<Mutex<ArtifactWriters>>,
}

impl Parser {
    /// Create a new streaming parser
    ///
    /// # Arguments
    ///
    /// * `log_dir` - Directory containing IGRA-events-*.ndjson files
    /// * `artifacts_dir` - Directory where output artifacts will be written
    ///
    /// # Initialization
    ///
    /// This constructor:
    /// 1. Creates a `LogMonitor` for tracking file positions
    /// 2. Creates a `ParserState` with self-cleaning L1 event cache
    /// 3. Creates `ArtifactWriters` that **overwrite** existing files
    ///
    /// # Panics
    ///
    /// Panics if artifact writers cannot be initialized (e.g., permission denied).
    /// This is intentional - we cannot proceed without writable artifacts.
    ///
    pub fn new(log_dir: PathBuf, artifacts_dir: PathBuf) -> Self {
        let monitor = Arc::new(Mutex::new(LogMonitor::new(log_dir.clone())));
        let parser_state = Arc::new(Mutex::new(ParserState::new()));
        let writers = Arc::new(Mutex::new(
            ArtifactWriters::new(&artifacts_dir).expect("Failed to initialize writers"),
        ));

        Self {
            log_dir,
            monitor,
            parser_state,
            writers,
        }
    }

    /// Start streaming mode with file watching
    ///
    /// # Event Loop
    ///
    /// This method runs an infinite loop using `tokio::select!` to handle:
    /// 1. **Ctrl+C signals** - Triggers graceful shutdown
    /// 2. **File change notifications** - Queued for processing
    /// 3. **Debounce timer** - Processes accumulated file changes after 200ms of quiet
    ///
    /// ## Why Debouncing?
    ///
    /// Log files may receive many rapid writes (e.g., bursts of events).
    /// Without debouncing, we'd process the same file repeatedly, wasting CPU.
    ///
    /// Debouncing batches rapid changes:
    /// - File changes are collected in a `HashSet` (deduplicated)
    /// - After 200ms of no new changes, we process all accumulated paths
    /// - This reduces redundant file reads
    ///
    /// ## Error Handling: STOP ON ERROR
    ///
    /// **CRITICAL**: Any error during processing immediately stops the parser.
    /// This is required for Zero-Loss testing:
    /// - If we can't process events → test is invalid
    /// - If we can't write artifacts → test is invalid
    /// - Continuing after errors risks silent data loss
    ///
    /// Before stopping, we attempt to flush buffered data to minimize loss.
    ///
    /// # Graceful Shutdown
    ///
    /// On Ctrl+C:
    /// 1. Process any pending file changes
    /// 2. Flush all buffered writes
    /// 3. Log final statistics
    /// 4. Exit cleanly
    ///
    pub async fn run(&self) -> Result<()> {
        tracing::info!("Starting streaming...");

        let (tx, mut rx) = mpsc::channel(FILE_WATCHER_CHANNEL_SIZE);
        let _watcher = self.setup_file_watcher(tx)?;

        self.initialize_processing()?;

        self.event_loop(&mut rx).await
    }

    /// Initialize by processing existing files and logging initial stats
    fn initialize_processing(&self) -> Result<()> {
        tracing::info!("Processing existing log content...");
        self.process_existing_files()?;

        let state = self.parser_state.lock().unwrap();
        state.log_stats();

        tracing::info!("Watching for changes. Press Ctrl+C to stop.");
        Ok(())
    }

    /// Main event loop that handles file changes, debouncing, and shutdown
    async fn event_loop(&self, rx: &mut mpsc::Receiver<PathBuf>) -> Result<()> {
        let mut debouncer = DebounceState::new();

        loop {
            let delay = debouncer.calculate_delay();

            tokio::select! {
                _ = signal::ctrl_c() => {
                    return self.handle_shutdown(&debouncer.pending_paths);
                }

                Some(path) = rx.recv() => {
                    debouncer.add_path(path);
                }

                _ = tokio::time::sleep(delay), if debouncer.has_pending() => {
                    self.handle_debounced_processing(&mut debouncer)?;
                }
            }
        }
    }

    /// Handle graceful shutdown: process pending changes and flush
    fn handle_shutdown(&self, pending_paths: &HashSet<PathBuf>) -> Result<()> {
        tracing::info!("Received Ctrl+C, initiating graceful shutdown...");

        if !pending_paths.is_empty() {
            tracing::info!("Processing {} pending file changes before shutdown...", pending_paths.len());
            if let Err(e) = self.process_pending_paths(pending_paths) {
                tracing::error!("Error processing pending paths during shutdown: {}", e);
                // Continue to flush - save what we can
            }
        }

        tracing::info!("Flushing buffered data...");
        self.flush_and_log_final_stats()?;

        tracing::info!("Shutdown complete.");
        Ok(())
    }

    /// Process accumulated file changes after debounce period
    fn handle_debounced_processing(&self, debouncer: &mut DebounceState) -> Result<()> {
        if debouncer.pending_paths.is_empty() {
            debouncer.clear();
            return Ok(());
        }

        tracing::debug!("Processing {} accumulated file changes", debouncer.pending_paths.len());

        // CRITICAL: Stop on error (don't continue with corrupt state)
        if let Err(e) = self.process_pending_paths(&debouncer.pending_paths) {
            tracing::error!("FATAL: Error processing file changes: {}", e);
            tracing::error!("Stopping parser to prevent data loss");

            // Try to flush before stopping
            let _ = self.flush_writers();

            return Err(e);
        }

        debouncer.clear();
        Ok(())
    }

    // ========================================================================
    // File Watching
    // ========================================================================

    /// Setup filesystem watcher for log directory
    ///
    /// Creates a `notify::RecommendedWatcher` that monitors the log directory for:
    /// - File modifications (new events appended)
    /// - File creation (new date-based log files)
    ///
    /// # Architecture
    ///
    /// The watcher runs in a separate thread and communicates via channels:
    /// 1. OS filesystem events → `notify` crate (sync)
    /// 2. `notify` → std::sync::mpsc channel (sync)
    /// 3. Tokio task bridges to async world
    /// 4. tokio::sync::mpsc → main event loop (async)
    ///
    /// # Why This Complexity?
    ///
    /// The `notify` crate uses synchronous OS APIs, but our main loop is async (tokio).
    /// We need a bridge task to forward events from sync to async world.
    ///
    fn setup_file_watcher(&self, tx: mpsc::Sender<PathBuf>) -> Result<RecommendedWatcher> {
        let (notify_tx, notify_rx) = std::sync::mpsc::channel();

        let mut watcher: RecommendedWatcher = Watcher::new(
            notify_tx,
            notify::Config::default().with_poll_interval(FILE_WATCHER_POLL_INTERVAL),
        )
        .map_err(|e| ParserError::ValidationError {
            reason: format!("Failed to create file watcher: {}", e),
        })?;

        tracing::info!("Watching log directory: {}", self.log_dir.display());
        watcher
            .watch(&self.log_dir, RecursiveMode::NonRecursive)
            .map_err(|e| ParserError::FileOpen {
                path: self.log_dir.clone(),
                source: std::io::Error::new(std::io::ErrorKind::Other, e),
            })?;

        // Forward events to async channel
        tokio::spawn(async move {
            while let Ok(event_result) = notify_rx.recv() {
                match event_result {
                    Ok(event) => {
                        if Self::is_relevant_event(&event) {
                            for path in event.paths {
                                let _ = tx.send(path).await;
                            }
                        }
                    }
                    Err(e) => {
                        tracing::warn!("File watch error: {}", e);
                    }
                }
            }
        });

        Ok(watcher)
    }

    /// Check if a filesystem event is relevant for processing
    ///
    /// We only care about:
    /// - `Modify` events (new data appended to existing files)
    /// - `Create` events (new log files created)
    ///
    /// We ignore:
    /// - `Remove` events (don't care about deletions)
    /// - `Access` events (just reads, not modifications)
    /// - `Rename` events (date-based logs shouldn't be renamed)
    ///
    fn is_relevant_event(event: &Event) -> bool {
        matches!(
            event.kind,
            notify::EventKind::Modify(_) | notify::EventKind::Create(_)
        )
    }

    // ========================================================================
    // File Processing
    // ========================================================================

    /// Process all existing log files in the log directory
    ///
    /// Called once on startup before starting the file watcher.
    /// This ensures we catch up with any events that were logged before streaming started.
    ///
    /// # Fresh Start Behavior
    ///
    /// Even though we process existing files, artifact output is fresh because
    /// `ArtifactWriters` truncates files on initialization.
    ///
    fn process_existing_files(&self) -> Result<()> {
        let log_files = {
            let monitor = self.monitor.lock().unwrap();
            monitor.discover_log_files()?
        };

        tracing::info!("Found {} existing log files to process", log_files.len());

        for log_file in log_files {
            tracing::info!("Processing existing file: {}", log_file.display());
            self.process_log_file(&log_file)?;
        }

        Ok(())
    }

    /// Process all paths that have accumulated during debounce window
    ///
    /// # Error Handling
    ///
    /// Stops on first error - does not continue processing remaining paths.
    /// This is intentional for Zero-Loss testing.
    ///
    fn process_pending_paths(&self, paths: &HashSet<PathBuf>) -> Result<()> {
        for path in paths {
            self.handle_file_change(path)?;
        }
        Ok(())
    }

    /// Handle a single file change notification
    ///
    /// Filters for IGRA event log files (IGRA-events-*.ndjson) and processes them.
    /// Other files in the directory are ignored.
    ///
    fn handle_file_change(&self, path: &Path) -> Result<()> {
        // Check if this is an event log file
        if let Some(filename) = path.file_name() {
            if LogMonitor::is_event_log_file(&filename.to_string_lossy()) {
                self.process_log_file(path)?;
            }
        }
        Ok(())
    }

    /// Process new lines from a log file
    ///
    /// # Incremental Reading
    ///
    /// Uses `LogMonitor` to track file position. Only reads lines that haven't been
    /// processed yet. This is crucial for efficiency - we don't re-read entire files.
    ///
    /// # Mixed Event Types
    ///
    /// Each log file contains BOTH L1_TX_ELIGIBLE and L2_TX_INCLUDED events.
    /// We parse each line and dispatch to the appropriate handler.
    ///
    /// # Post-Processing
    ///
    /// After processing all new lines, we flush writers to ensure data is persisted.
    ///
    fn process_log_file(&self, path: &Path) -> Result<()> {
        let lines = {
            let mut monitor = self.monitor.lock().unwrap();
            monitor.read_new_lines(path)?
        };

        if lines.is_empty() {
            return Ok(());
        }

        tracing::debug!("Processing {} new lines from {}", lines.len(), path.display());

        for line in lines {
            self.process_event_line(&line)?;
        }

        // Flush writers
        {
            let mut writers = self.writers.lock().unwrap();
            writers.flush_all()?;
        }

        // Log unmatched L1 count periodically
        {
            let state = self.parser_state.lock().unwrap();
            let unmatched = state.unmatched_count();
            if unmatched % MEMORY_LOG_INTERVAL == 0 && unmatched > 0 {
                tracing::info!(
                    "Status update: {} unmatched L1 events (waiting for L2 matches)",
                    unmatched
                );
            }
        }

        Ok(())
    }

    // ========================================================================
    // Event Processing
    // ========================================================================

    /// Process a single line from the log file
    ///
    /// # Line Format
    ///
    /// Each line is a JSON object with a `type` field:
    /// - `{"type": "L1_TX_ELIGIBLE", ...}` → L1 event handler
    /// - `{"type": "L2_TX_INCLUDED", ...}` → L2 event handler
    ///
    /// # Error Handling
    ///
    /// - Parse errors → logged as warnings, line is skipped
    /// - Validation errors → logged as warnings, event is skipped
    /// - Write errors → propagated (stops processing)
    ///
    fn process_event_line(&self, line: &str) -> Result<()> {
        match self.parse_log_event(line)? {
            Some(LogEvent::L1TxEligible(event)) => {
                self.handle_l1_event(event)?;
            }
            Some(LogEvent::L2TxIncluded(event)) => {
                self.handle_l2_event(event)?;
            }
            None => {} // Skip unparseable lines
        }
        Ok(())
    }

    /// Handle an L1_TX_ELIGIBLE event
    ///
    /// # Processing Steps
    ///
    /// 1. **Validate** - Check required fields are non-empty/non-zero
    /// 2. **Store in memory** - Add to HashMap for future L2 matching
    /// 3. **Write to artifact** - Append to eligible_set.jsonl
    ///
    /// # Memory Behavior
    ///
    /// L1 events stay in memory until their L2 match arrives (then removed).
    /// Only unmatched L1s remain in memory, keeping usage minimal.
    ///
    fn handle_l1_event(&self, event: L1TxEligible) -> Result<()> {
        // Validate
        if let Err(e) = event.validate() {
            tracing::warn!("Invalid L1 event: {}", e);
            return Ok(());
        }

        // Store in memory index
        {
            let mut state = self.parser_state.lock().unwrap();
            state.add_eligible(event.clone());
        }

        // Write to artifact
        {
            let mut writers = self.writers.lock().unwrap();
            writers.write_eligible(&event)?;
        }

        tracing::debug!("Processed L1 eligible: {}", event.l1_txid);
        Ok(())
    }

    /// Handle an L2_TX_INCLUDED event
    ///
    /// # Processing Steps
    ///
    /// 1. **Validate** - Check required fields
    /// 2. **Write to artifact** - Append to included_set.jsonl
    /// 3. **Try to match** - Look up L1 event by l2_payload_hash
    /// 4. **If match found** - Create MappingRecord and write to mapping_log.csv
    ///
    /// # When No Match Exists
    ///
    /// An L2 event may have no matching L1 event because:
    /// - L1 event hasn't arrived yet (out-of-order)
    /// - L1 event failed validation
    /// - L1 event missing from logs (data loss!)
    ///
    /// No match is logged at debug level. For Zero-Loss testing, you should
    /// verify all L2 events have matches.
    ///
    fn handle_l2_event(&self, event: L2TxIncluded) -> Result<()> {
        // Validate
        if let Err(e) = event.validate() {
            tracing::warn!("Invalid L2 event: {}", e);
            return Ok(());
        }

        // Write included event
        {
            let mut writers = self.writers.lock().unwrap();
            writers.write_included(&event)?;
        }

        // Try to join with L1 event
        let mapping_record = {
            let mut state = self.parser_state.lock().unwrap();
            state.find_match(&event)
        };

        if let Some(record) = mapping_record {
            let mut writers = self.writers.lock().unwrap();
            writers.write_mapping(&record)?;

            tracing::debug!("Matched: {} -> {}", record.l1_txid, record.l2_block_hash);
        }

        tracing::debug!("Processed L2 included: {}", event.l2_payload_hash);
        Ok(())
    }

    /// Parse a log line into a LogEvent
    ///
    /// # Error Handling
    ///
    /// Parse errors are logged but don't stop processing. This allows the parser
    /// to continue even if individual lines are corrupted.
    ///
    /// Returns `Ok(None)` for unparseable lines.
    ///
    fn parse_log_event(&self, line: &str) -> Result<Option<LogEvent>> {
        match serde_json::from_str::<LogEvent>(line) {
            Ok(event) => Ok(Some(event)),
            Err(e) => {
                tracing::warn!("Failed to parse log line: {}", e);
                Ok(None)
            }
        }
    }

    // ========================================================================
    // Shutdown & Cleanup
    // ========================================================================

    /// Helper method to flush writers without error handling
    ///
    /// Used during error recovery - we try to flush but don't fail if it doesn't work.
    ///
    fn flush_writers(&self) {
        if let Ok(mut writers) = self.writers.lock() {
            let _ = writers.flush_all();
        }
    }

    /// Flush all buffered writes and log final statistics
    ///
    /// Called during graceful shutdown. Ensures all data is persisted before exit.
    ///
    fn flush_and_log_final_stats(&self) -> Result<()> {
        {
            let mut writers = self.writers.lock().unwrap();
            writers.flush_all()?;
        }

        {
            let state = self.parser_state.lock().unwrap();
            tracing::info!("=== Final Statistics ===");
            state.log_stats();

            // Warn if orphaned L1s exist (never matched with L2)
            let unmatched = state.unmatched_count();
            if unmatched > 0 {
                tracing::warn!(
                    "Found {} orphaned L1 events (never matched with L2)",
                    unmatched
                );
            }
        }

        Ok(())
    }
}

/// Run the log parser in streaming mode
///
/// This is the main entry point from main.rs.
///
/// # Arguments
///
/// * `logs_dir` - Directory containing IGRA event log files
/// * `artifacts_dir` - Directory where output artifacts will be written
///
pub async fn run(logs_dir: PathBuf, artifacts_dir: PathBuf) -> Result<()> {
    // Ensure directories exist
    std::fs::create_dir_all(&artifacts_dir)?;

    tracing::info!("Starting streaming mode");
    tracing::info!("  log_dir: {}", logs_dir.display());
    tracing::info!("  artifacts_dir: {}", artifacts_dir.display());

    let parser = Parser::new(logs_dir, artifacts_dir);
    parser.run().await
}
