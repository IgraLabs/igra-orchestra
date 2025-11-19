use std::path::PathBuf;
use thiserror::Error;

#[derive(Error, Debug)]
pub enum ParserError {
    #[error("Failed to open log file: {path}")]
    FileOpen {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Failed to read line {line} from {file}")]
    LineRead {
        file: String,
        line: usize,
        #[source]
        source: std::io::Error,
    },

    #[error("Validation failed: {reason}")]
    ValidationError { reason: String },

    #[error("Failed to write to {path}")]
    FileWrite {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },

    #[error("Serialization failed")]
    Serialization(#[from] serde_json::Error),

    #[error("CSV write failed")]
    CsvWrite(#[from] csv::Error),

    #[error("IO error")]
    Io(#[from] std::io::Error),
}

pub type Result<T> = std::result::Result<T, ParserError>;
