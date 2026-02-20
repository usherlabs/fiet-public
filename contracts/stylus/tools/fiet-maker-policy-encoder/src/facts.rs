//! Mock facts provider for testing.

pub use fiet_maker_policy_types::{FactsError, FactsProvider, Slot0};

/// Mock facts provider for off-chain testing.
/// 
/// This can be used to test check program encoding/decoding
/// without requiring on-chain state.
pub struct MockFactsProvider {
    pub block_timestamp: u64,
}

impl MockFactsProvider {
    pub fn new(block_timestamp: u64) -> Self {
        Self { block_timestamp }
    }
}

impl FactsProvider for MockFactsProvider {
    fn block_timestamp(&self) -> u64 {
        self.block_timestamp
    }
}

