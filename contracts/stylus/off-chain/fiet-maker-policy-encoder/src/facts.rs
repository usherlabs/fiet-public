//! Mock facts provider for testing.

use alloy_primitives::{Address, FixedBytes, U256};

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

/// Trait for providing facts (matches on-chain FactsProvider interface).
pub trait FactsProvider {
    fn block_timestamp(&self) -> u64;
    fn get_slot0(&self, _pool_id: FixedBytes<32>) -> Result<Slot0, FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn is_rfs_closed(&self, _position_id: FixedBytes<32>) -> Result<bool, FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn queue_amount(&self, _lcc: Address, _owner: Address) -> Result<U256, FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn reserve_of(&self, _lcc: Address) -> Result<U256, FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn get_settled_amounts(&self, _position_id: FixedBytes<32>) -> Result<(U256, U256), FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn get_commitment_maxima(&self, _position_id: FixedBytes<32>) -> Result<(U256, U256), FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn grace_period_remaining(&self, _position_id: FixedBytes<32>) -> Result<u64, FactsError> {
        Err(FactsError::NotImplemented)
    }
    fn staticcall_u256(
        &self,
        _target: Address,
        _selector: [u8; 4],
        _args: &[u8],
    ) -> Result<U256, FactsError> {
        Err(FactsError::NotImplemented)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Slot0 {
    pub sqrt_price_x96: U256,
    pub tick: i32,
    pub protocol_fee: u32,
    pub lp_fee: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FactsError {
    NotImplemented,
    ForbiddenCall,
    CallFailed,
    MalformedReturn,
}

impl FactsProvider for MockFactsProvider {
    fn block_timestamp(&self) -> u64 {
        self.block_timestamp
    }
}

