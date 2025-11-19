use std::time::Duration;

// ============================================================================
// Input Log File Patterns
// ============================================================================

/// Prefix for IGRA event log files
///
/// Log files follow the pattern: IGRA-events-YYYY-MM-DD.ndjson
pub const LOG_FILE_PREFIX: &str = "IGRA-events-";

/// File extension for IGRA event log files
pub const LOG_FILE_EXTENSION: &str = ".ndjson";

/// Date format used in log filenames
///
/// Format: YYYY-MM-DD (e.g., 2025-11-20)
pub const LOG_FILE_DATE_FORMAT: &str = "%Y-%m-%d";

// ============================================================================
// Output Artifact Filenames
// ============================================================================

/// Output file for L1_TX_ELIGIBLE events (JSONL format)
pub const ELIGIBLE_SET_FILE: &str = "eligible_set.jsonl";

/// Output file for L2_TX_INCLUDED events (JSONL format)
pub const INCLUDED_SET_FILE: &str = "included_set.jsonl";

/// Output file for joined L1+L2 mapping records (CSV format)
pub const MAPPING_LOG_FILE: &str = "mapping_log.csv";

// ============================================================================
// Parser Configuration
// ============================================================================

/// Debounce delay for file change events
///
/// After a file changes, we wait this duration for additional changes
/// before processing. This batches rapid writes and reduces redundant I/O.
///
/// Why 200ms? Balance between responsiveness and batching efficiency.
pub const DEBOUNCE_DURATION: Duration = Duration::from_millis(200);

/// File watcher async channel buffer size
///
/// Number of file change events that can be queued before backpressure.
/// 100 is sufficient for typical log rotation scenarios.
pub const FILE_WATCHER_CHANNEL_SIZE: usize = 100;

/// File watcher polling interval
///
/// How often the file watcher checks for changes. 1 second provides
/// good responsiveness without excessive CPU usage.
pub const FILE_WATCHER_POLL_INTERVAL: Duration = Duration::from_secs(1);

/// Idle wait duration when no pending changes
///
/// When there are no pending file changes, we wait this long before
/// checking again. Set to 1 hour to minimize CPU usage during idle periods.
pub const IDLE_WAIT_DURATION: Duration = Duration::from_secs(3600);

/// Frequency of statistics logging
///
/// Log statistics (including unmatched L1 count) every N L1 events processed.
/// This helps monitor the number of L1s waiting for L2 matches during streaming.
pub const MEMORY_LOG_INTERVAL: usize = 10_000;
