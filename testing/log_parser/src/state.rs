use crate::models::{L1TxEligible, L2TxIncluded, MappingRecord};
use std::collections::HashMap;

/// Holds parsed L1 events in memory for O(1) join operations with L2 events
///
/// # Memory Model: Self-Cleaning HashMap
///
/// This structure uses a **HashMap that automatically removes matched entries**.
/// Matched L1 events are deleted immediately after L2 matching, keeping memory
/// proportional to **unmatched events** rather than **total events**.
///
/// ## Memory Optimization
///
/// - **L1 arrives** → Stored in HashMap (waiting for L2 match)
/// - **L2 arrives + match found** → L1 **removed** from HashMap
/// - **Result**: HashMap only contains unmatched L1s
///
/// This reduces typical memory usage by 10-100x compared to storing all L1s.
///
/// ## What Remains in Memory
///
/// The HashMap at any point contains:
/// 1. **Waiting L1s** - L1 events waiting for their L2 match (typically small)
/// 2. **Orphaned L1s** - L1 events that will never match (useful for debugging)
///
/// At shutdown, `cache_size()` reveals orphaned L1s that never matched with L2.
///
/// ## Data Flow
///
/// 1. **L1 event arrives** → Stored in `eligible_index` HashMap
/// 2. **L2 event arrives** → Lookup in `eligible_index` by `l2_payload_hash`
/// 3. **If match found** → Create `MappingRecord` for CSV output, **remove L1 from HashMap**
/// 4. **If no match** → L2 event written to included set, no mapping created
///
/// ## Thread Safety
///
/// This struct is wrapped in `Arc<Mutex<_>>` by the parser for thread-safe access.
///
#[derive(Debug)]
pub struct ParserState {
    /// Maps l2_payload_hash -> L1TxEligible for instant O(1) lookups
    ///
    /// Key: The `l2_payload_hash` field from L1TxEligible events
    /// Value: The complete L1TxEligible event data
    ///
    /// This index allows instant matching when L2_TX_INCLUDED events arrive.
    eligible_index: HashMap<String, L1TxEligible>,

    /// Statistics tracking
    processed_l1_count: usize,
    processed_l2_count: usize,
    matched_count: usize,
}

impl ParserState {
    /// Create a new parser state with empty index
    pub fn new() -> Self {
        Self {
            eligible_index: HashMap::new(),
            processed_l1_count: 0,
            processed_l2_count: 0,
            matched_count: 0,
        }
    }

    /// Add an L1 eligible event to the in-memory index
    ///
    /// The event is stored in the HashMap using `l2_payload_hash` as the key.
    /// This allows instant O(1) lookup when matching L2 events arrive.
    ///
    /// The L1 event will remain in memory until:
    /// 1. A matching L2 event arrives (L1 removed during match)
    /// 2. Parser shuts down (memory cleared)
    ///
    /// # Duplicate Handling
    ///
    /// If an L1 event with the same `l2_payload_hash` already exists, it is **replaced**.
    /// This should not happen in normal operation (payload hashes should be unique).
    pub fn add_eligible(&mut self, event: L1TxEligible) {
        let hash = event.l2_payload_hash.clone();

        // Warn if duplicate (shouldn't happen in normal operation)
        if self.eligible_index.contains_key(&hash) {
            tracing::warn!(
                "Duplicate L1 event with l2_payload_hash={} (replacing previous)",
                hash
            );
        }

        self.eligible_index.insert(hash, event);
        self.processed_l1_count += 1;
    }

    /// Try to find a matching L1 event for the given L2 event
    ///
    /// Performs O(1) HashMap lookup using `l2_payload_hash` as the key.
    ///
    /// **IMPORTANT**: Matched L1 events are **removed** from the HashMap after matching.
    /// This keeps memory usage proportional to unmatched events, not total events.
    ///
    /// # Returns
    ///
    /// - `Some(MappingRecord)` if a matching L1 event is found (L1 removed from HashMap)
    /// - `None` if no matching L1 event exists in the index
    ///
    /// # Why No Match?
    ///
    /// An L2 event may have no match because:
    /// 1. The L1 event hasn't arrived yet (out-of-order processing)
    /// 2. The L1 event failed validation and was dropped
    /// 3. Data corruption or missing log data
    ///
    /// # Memory Optimization
    ///
    /// By removing matched L1s, the HashMap only contains:
    /// - **Waiting L1s** (pending L2 match) - typically small
    /// - **Orphaned L1s** (never matched) - useful for debugging
    ///
    /// This reduces memory from O(all L1s) to O(unmatched L1s).
    pub fn find_match(&mut self, l2_event: &L2TxIncluded) -> Option<MappingRecord> {
        self.processed_l2_count += 1;

        self.eligible_index
            .remove(&l2_event.l2_payload_hash)
            .map(|l1_event| {
                self.matched_count += 1;
                MappingRecord::from_events(&l1_event, l2_event)
            })
    }

    /// Get the current number of unmatched L1 events in memory
    ///
    /// Since matched L1s are removed from the HashMap, this returns:
    /// - **Waiting L1s** (pending their L2 match)
    /// - **Orphaned L1s** (will never match)
    ///
    /// At shutdown, a non-zero value indicates orphaned L1s that never matched with L2.
    pub fn cache_size(&self) -> usize {
        self.eligible_index.len()
    }

    /// Get the number of unmatched L1 events (alias for cache_size)
    ///
    /// This is a clearer name that reflects the memory optimization behavior.
    pub fn unmatched_count(&self) -> usize {
        self.cache_size()
    }

    /// Log current statistics to tracing
    ///
    /// Outputs:
    /// - Number of L1 events processed (total)
    /// - Number of L2 events processed (total)
    /// - Number of successful matches (mappings created)
    /// - Number of unmatched L1s (still in HashMap)
    /// - Match rate percentage
    pub fn log_stats(&self) {
        let match_rate = if self.processed_l2_count > 0 {
            (self.matched_count as f64 / self.processed_l2_count as f64) * 100.0
        } else {
            0.0
        };

        tracing::info!(
            "Stats: L1={} L2={} Matched={} Unmatched={} | Match rate: {:.1}%",
            self.processed_l1_count,
            self.processed_l2_count,
            self.matched_count,
            self.unmatched_count(),
            match_rate
        );
    }
}

impl Default for ParserState {
    fn default() -> Self {
        Self::new()
    }
}
