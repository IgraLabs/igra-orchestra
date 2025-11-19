// Core modules
pub mod constants;
pub mod error;
pub mod io;
pub mod models;
pub mod parser;
pub mod state;

// Re-export commonly used types for convenience
pub use error::{ParserError, Result};
pub use models::{L1TxEligible, L2TxIncluded, LogEvent, MappingRecord, TxType, Validate};
pub use parser::run;
pub use state::ParserState;
