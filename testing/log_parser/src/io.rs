use crate::constants::{
    ELIGIBLE_SET_FILE, INCLUDED_SET_FILE, LOG_FILE_DATE_FORMAT, LOG_FILE_EXTENSION,
    LOG_FILE_PREFIX, MAPPING_LOG_FILE,
};
use crate::error::{ParserError, Result};
use crate::models::{L1TxEligible, L2TxIncluded, MappingRecord};
use chrono::{NaiveDate, Utc};
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::{BufRead, BufReader, BufWriter, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

// ============================================================================
// File Monitoring - Discovery and Incremental Reading
// ============================================================================

/// Monitors a directory for date-based log files and tracks read positions
pub struct LogMonitor {
    log_dir: PathBuf,
    /// Map of filename -> FileState
    file_states: HashMap<String, FileState>,
}

impl LogMonitor {
    pub fn new(log_dir: PathBuf) -> Self {
        Self {
            log_dir,
            file_states: HashMap::new(),
        }
    }

    /// Get the current date-based log filename
    pub fn current_log_filename() -> String {
        let now = Utc::now();
        format!(
            "{}{}{}",
            LOG_FILE_PREFIX,
            now.format(LOG_FILE_DATE_FORMAT),
            LOG_FILE_EXTENSION
        )
    }

    /// Get the log filename for a specific date
    pub fn log_filename_for_date(date: NaiveDate) -> String {
        format!(
            "{}{}{}",
            LOG_FILE_PREFIX,
            date.format(LOG_FILE_DATE_FORMAT),
            LOG_FILE_EXTENSION
        )
    }

    /// Check if a filename matches the IGRA event log pattern
    pub fn is_event_log_file(filename: &str) -> bool {
        filename.starts_with(LOG_FILE_PREFIX) && filename.ends_with(LOG_FILE_EXTENSION)
    }

    /// Extract date from log filename
    pub fn extract_date_from_filename(filename: &str) -> Option<NaiveDate> {
        if !Self::is_event_log_file(filename) {
            return None;
        }

        let date_part = filename
            .strip_prefix(LOG_FILE_PREFIX)?
            .strip_suffix(LOG_FILE_EXTENSION)?;

        NaiveDate::parse_from_str(date_part, LOG_FILE_DATE_FORMAT).ok()
    }

    /// Discover all event log files in directory
    pub fn discover_log_files(&self) -> Result<Vec<PathBuf>> {
        let mut log_files = Vec::new();

        let entries = fs::read_dir(&self.log_dir).map_err(|e| ParserError::FileOpen {
            path: self.log_dir.clone(),
            source: e,
        })?;

        for entry in entries {
            let entry = entry.map_err(|e| ParserError::FileOpen {
                path: self.log_dir.clone(),
                source: e,
            })?;

            let filename = entry.file_name();
            let filename_str = filename.to_string_lossy();

            if Self::is_event_log_file(&filename_str) {
                log_files.push(entry.path());
            }
        }

        // Sort by date (oldest to newest)
        log_files.sort_by(|a, b| {
            let date_a = Self::extract_date_from_filename(
                &a.file_name().unwrap().to_string_lossy(),
            );
            let date_b = Self::extract_date_from_filename(
                &b.file_name().unwrap().to_string_lossy(),
            );
            date_a.cmp(&date_b)
        });

        Ok(log_files)
    }

    /// Get or create FileState for a log file
    pub fn get_file_state(&mut self, path: &Path) -> &mut FileState {
        let filename = path.file_name().unwrap().to_string_lossy().to_string();
        self.file_states
            .entry(filename)
            .or_insert_with(|| FileState::new(path.to_path_buf()))
    }

    /// Read new lines from a specific file
    pub fn read_new_lines(&mut self, path: &Path) -> Result<Vec<String>> {
        let state = self.get_file_state(path);
        state.read_new_lines()
    }
}

// ============================================================================
// File State - Position Tracking for Incremental Reading
// ============================================================================

/// Tracks file read position for incremental reading
#[derive(Debug, Clone)]
pub struct FileState {
    path: PathBuf,
    position: u64,
    #[cfg(unix)]
    inode: Option<u64>,
}

impl FileState {
    pub fn new(path: PathBuf) -> Self {
        Self {
            path,
            position: 0,
            #[cfg(unix)]
            inode: None,
        }
    }

    /// Read new lines from file since last position
    pub fn read_new_lines(&mut self) -> Result<Vec<String>> {
        // Update inode if on Unix
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            if let Ok(metadata) = fs::metadata(&self.path) {
                let current_inode = metadata.ino();

                // Check if file was rotated (inode changed)
                if let Some(old_inode) = self.inode {
                    if current_inode != old_inode {
                        tracing::warn!(
                            "File inode changed for {} (old: {}, new: {}). This shouldn't happen with date-based rotation. Resetting position.",
                            self.path.display(),
                            old_inode,
                            current_inode
                        );
                        self.position = 0;
                    }
                }

                self.inode = Some(current_inode);
            }
        }

        let path = self.path.clone();
        let position = self.position;
        let lines = self.read_from_file(&path, position)?;
        Ok(lines)
    }

    /// Read lines from file starting at a given position
    fn read_from_file(&mut self, file_path: &Path, start_position: u64) -> Result<Vec<String>> {
        let mut file = File::open(file_path).map_err(|e| ParserError::FileOpen {
            path: file_path.to_path_buf(),
            source: e,
        })?;

        // Seek to the starting position
        file.seek(SeekFrom::Start(start_position))
            .map_err(|e| ParserError::FileOpen {
                path: file_path.to_path_buf(),
                source: e,
            })?;

        let mut reader = BufReader::new(file);
        let mut lines = Vec::new();

        // Read lines and track actual position
        loop {
            let mut line = String::new();
            match reader.read_line(&mut line) {
                Ok(0) => break, // EOF
                Ok(_bytes) => {
                    // Remove the trailing newline if present
                    if line.ends_with('\n') {
                        line.pop();
                        if line.ends_with('\r') {
                            line.pop();
                        }
                    }

                    // Only add non-empty lines
                    if !line.trim().is_empty() {
                        lines.push(line);
                    }
                }
                Err(e) => {
                    return Err(ParserError::FileOpen {
                        path: file_path.to_path_buf(),
                        source: e,
                    });
                }
            }
        }

        // Get actual current position in file
        let final_position = reader
            .stream_position()
            .map_err(|e| ParserError::FileOpen {
                path: file_path.to_path_buf(),
                source: e,
            })?;

        self.position = final_position;

        Ok(lines)
    }
}

// ============================================================================
// Artifact Writing - Buffered Output
// ============================================================================

/// Manages buffered writes to artifact files
///
/// # File Mode: Overwrite (Fresh Start)
///
/// **IMPORTANT**: This writer **overwrites** existing files on startup.
///
/// Each test session starts with clean artifacts. Restarting the parser
/// means starting a new test - we never append to old results.
///
/// # Buffering Strategy
///
/// All writes use `BufWriter` for performance. Buffer is flushed periodically
/// via `flush_all()` to minimize data loss risk while maintaining throughput.
pub struct ArtifactWriters {
    eligible_writer: BufWriter<File>,
    included_writer: BufWriter<File>,
    csv_writer: csv::Writer<BufWriter<File>>,
}

impl ArtifactWriters {
    /// Create new artifact writers, **overwriting** any existing files
    ///
    /// Opens three files in write mode (truncates if exists):
    /// - `eligible_set.jsonl` - JSONL file for L1_TX_ELIGIBLE events
    /// - `included_set.jsonl` - JSONL file for L2_TX_INCLUDED events
    /// - `mapping_log.csv` - CSV file for joined mapping records
    pub fn new(artifacts_dir: &Path) -> Result<Self> {
        let eligible_path = artifacts_dir.join(ELIGIBLE_SET_FILE);
        let included_path = artifacts_dir.join(INCLUDED_SET_FILE);
        let csv_path = artifacts_dir.join(MAPPING_LOG_FILE);

        // Open files in WRITE mode (truncates existing files)
        let eligible_file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&eligible_path)
            .map_err(|e| ParserError::FileWrite {
                path: eligible_path.clone(),
                source: e,
            })?;

        let included_file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&included_path)
            .map_err(|e| ParserError::FileWrite {
                path: included_path.clone(),
                source: e,
            })?;

        let csv_file = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(&csv_path)
            .map_err(|e| ParserError::FileWrite {
                path: csv_path.clone(),
                source: e,
            })?;

        // CSV writer always writes headers since we're starting fresh
        let csv_writer = csv::WriterBuilder::new()
            .has_headers(true)
            .from_writer(BufWriter::new(csv_file));

        tracing::info!("Initialized artifact writers (fresh files created):");
        tracing::info!("  - {}", eligible_path.display());
        tracing::info!("  - {}", included_path.display());
        tracing::info!("  - {}", csv_path.display());

        Ok(Self {
            eligible_writer: BufWriter::new(eligible_file),
            included_writer: BufWriter::new(included_file),
            csv_writer,
        })
    }

    /// Write an L1_TX_ELIGIBLE event to eligible_set.jsonl
    pub fn write_eligible(&mut self, event: &L1TxEligible) -> Result<()> {
        let json = serde_json::to_string(event)?;
        writeln!(self.eligible_writer, "{}", json).map_err(|e| ParserError::Io(e))?;
        Ok(())
    }

    /// Write an L2_TX_INCLUDED event to included_set.jsonl
    pub fn write_included(&mut self, event: &L2TxIncluded) -> Result<()> {
        let json = serde_json::to_string(event)?;
        writeln!(self.included_writer, "{}", json).map_err(|e| ParserError::Io(e))?;
        Ok(())
    }

    /// Write a mapping record (joined L1+L2 event) to mapping_log.csv
    pub fn write_mapping(&mut self, record: &MappingRecord) -> Result<()> {
        self.csv_writer.serialize(record)?;
        Ok(())
    }

    /// Flush all buffered data to disk
    ///
    /// Should be called:
    /// - After processing each batch of file changes
    /// - Before shutdown
    /// - After errors (to save as much data as possible)
    pub fn flush_all(&mut self) -> Result<()> {
        self.eligible_writer.flush()?;
        self.included_writer.flush()?;
        self.csv_writer.flush()?;
        Ok(())
    }
}
