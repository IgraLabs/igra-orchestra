use crate::error::{ParserError, Result};
use serde::{Deserialize, Serialize};

/// Trait for validating event data
pub trait Validate {
    fn validate(&self) -> Result<()>;
}

/// Transaction type
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum TxType {
    Entry,
    UnzippedPayload,
}

/// Event emitted by Translator when L1 tx is eligible for L2 inclusion
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct L1TxEligible {
    pub l1_txid: String,
    pub l1_block_daa: u64,
    pub l2_payload_hash: String,
    pub l1_block_timestamp: u64,
    pub tx_type: TxType,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_address: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub entry_amount_sompi: Option<u64>,
}

/// Event emitted by Assembler when L2 tx is included in a block
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct L2TxIncluded {
    pub l2_payload_hash: String,
    pub l2_block_hash: String,
    pub l2_block_number: u64,
    pub l2_block_daa: u64,
    pub l2_block_timestamp: u64,
    pub tx_type: TxType,
}

/// Joined record for mapping log
#[derive(Debug, Serialize, Deserialize, PartialEq)]
pub struct MappingRecord {
    pub l2_payload_hash: String,
    pub l1_txid: String,
    pub l1_block_daa: u64,
    pub l1_block_timestamp: u64,
    pub l2_block_hash: String,
    pub l2_block_number: u64,
    pub l2_block_daa: u64,
    pub l2_block_timestamp: u64,
}

/// Unified log event for deserialization
#[derive(Debug, Deserialize)]
#[serde(tag = "type")]
pub enum LogEvent {
    #[serde(rename = "L1_TX_ELIGIBLE")]
    L1TxEligible(L1TxEligible),
    #[serde(rename = "L2_TX_INCLUDED")]
    L2TxIncluded(L2TxIncluded),
}

impl Validate for L1TxEligible {
    fn validate(&self) -> Result<()> {
        if self.l1_txid.is_empty() {
            return Err(ParserError::ValidationError {
                reason: "l1_txid cannot be empty".to_string(),
            });
        }
        if self.l1_block_daa == 0 {
            return Err(ParserError::ValidationError {
                reason: "l1_block_daa must be greater than 0".to_string(),
            });
        }
        if self.l2_payload_hash.is_empty() {
            return Err(ParserError::ValidationError {
                reason: "l2_payload_hash cannot be empty".to_string(),
            });
        }
        if self.l1_block_timestamp == 0 {
            return Err(ParserError::ValidationError {
                reason: "l1_block_timestamp must be greater than 0".to_string(),
            });
        }
        Ok(())
    }
}

impl Validate for L2TxIncluded {
    fn validate(&self) -> Result<()> {
        if self.l2_payload_hash.is_empty() {
            return Err(ParserError::ValidationError {
                reason: "l2_payload_hash cannot be empty".to_string(),
            });
        }
        if self.l2_block_hash.is_empty() {
            return Err(ParserError::ValidationError {
                reason: "l2_block_hash cannot be empty".to_string(),
            });
        }
        if self.l2_block_number == 0 {
            return Err(ParserError::ValidationError {
                reason: "l2_block_number must be greater than 0".to_string(),
            });
        }
        if self.l2_block_daa == 0 {
            return Err(ParserError::ValidationError {
                reason: "l2_block_daa must be greater than 0".to_string(),
            });
        }
        if self.l2_block_timestamp == 0 {
            return Err(ParserError::ValidationError {
                reason: "l2_block_timestamp must be greater than 0".to_string(),
            });
        }
        Ok(())
    }
}

impl MappingRecord {
    pub fn from_events(eligible: &L1TxEligible, included: &L2TxIncluded) -> Self {
        Self {
            l2_payload_hash: included.l2_payload_hash.clone(),
            l1_txid: eligible.l1_txid.clone(),
            l1_block_daa: eligible.l1_block_daa,
            l1_block_timestamp: eligible.l1_block_timestamp,
            l2_block_hash: included.l2_block_hash.clone(),
            l2_block_number: included.l2_block_number,
            l2_block_daa: included.l2_block_daa,
            l2_block_timestamp: included.l2_block_timestamp,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_l1_validate_empty_txid() {
        let event = L1TxEligible {
            l1_txid: "".to_string(),
            l1_block_daa: 100,
            l2_payload_hash: "0xhash".to_string(),
            l1_block_timestamp: 1000,
            tx_type: TxType::UnzippedPayload,
            entry_address: None,
            entry_amount_sompi: None,
        };
        assert!(event.validate().is_err());
    }

    #[test]
    fn test_l1_validate_zero_daa() {
        let event = L1TxEligible {
            l1_txid: "0xabc".to_string(),
            l1_block_daa: 0,
            l2_payload_hash: "0xhash".to_string(),
            l1_block_timestamp: 1000,
            tx_type: TxType::UnzippedPayload,
            entry_address: None,
            entry_amount_sompi: None,
        };
        assert!(event.validate().is_err());
    }

    #[test]
    fn test_l1_validate_zero_timestamp() {
        let event = L1TxEligible {
            l1_txid: "0xabc".to_string(),
            l1_block_daa: 100,
            l2_payload_hash: "0xhash".to_string(),
            l1_block_timestamp: 0,
            tx_type: TxType::UnzippedPayload,
            entry_address: None,
            entry_amount_sompi: None,
        };
        assert!(event.validate().is_err());
    }

    #[test]
    fn test_l1_validate_success() {
        let event = L1TxEligible {
            l1_txid: "0xabc".to_string(),
            l1_block_daa: 100,
            l2_payload_hash: "0xhash".to_string(),
            l1_block_timestamp: 1000,
            tx_type: TxType::UnzippedPayload,
            entry_address: None,
            entry_amount_sompi: None,
        };
        assert!(event.validate().is_ok());
    }

    #[test]
    fn test_l2_validate_zero_daa() {
        let event = L2TxIncluded {
            l2_payload_hash: "0xhash".to_string(),
            l2_block_hash: "0xblock".to_string(),
            l2_block_number: 42,
            l2_block_daa: 0,
            l2_block_timestamp: 1000,
            tx_type: TxType::UnzippedPayload,
        };
        assert!(event.validate().is_err());
    }

    #[test]
    fn test_l2_validate_zero_timestamp() {
        let event = L2TxIncluded {
            l2_payload_hash: "0xhash".to_string(),
            l2_block_hash: "0xblock".to_string(),
            l2_block_number: 42,
            l2_block_daa: 200,
            l2_block_timestamp: 0,
            tx_type: TxType::UnzippedPayload,
        };
        assert!(event.validate().is_err());
    }

    #[test]
    fn test_l2_validate_success() {
        let event = L2TxIncluded {
            l2_payload_hash: "0xhash".to_string(),
            l2_block_hash: "0xblock".to_string(),
            l2_block_number: 42,
            l2_block_daa: 200,
            l2_block_timestamp: 1000,
            tx_type: TxType::UnzippedPayload,
        };
        assert!(event.validate().is_ok());
    }
}
