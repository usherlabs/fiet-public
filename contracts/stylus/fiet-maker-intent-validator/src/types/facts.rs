use stylus_sdk::alloy_primitives::{Address, FixedBytes, U256};

use crate::errors::FactsError;

/// Slot0 snapshot for Uniswap v4 pool.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Slot0 {
    pub sqrt_price_x96: U256,
    pub tick: i32,
    pub protocol_fee: u32,
    pub lp_fee: u32,
}

/// Facts provider abstraction, implemented differently on-chain vs off-chain.
pub trait FactsProvider {
    fn block_timestamp(&self) -> u64;

    fn get_slot0(&self, pool_id: FixedBytes<32>) -> Result<Slot0, FactsError>;

    fn is_rfs_closed(&self, position_id: FixedBytes<32>) -> Result<bool, FactsError>;

    fn queue_amount(&self, lcc: Address, owner: Address) -> Result<U256, FactsError>;

    fn reserve_of(&self, lcc: Address) -> Result<U256, FactsError>;

    /// Get settled amounts for a position (amount0, amount1).
    fn get_settled_amounts(&self, position_id: FixedBytes<32>) -> Result<(U256, U256), FactsError>;

    /// Get commitment maxima for a position (commitment0, commitment1).
    fn get_commitment_maxima(&self, position_id: FixedBytes<32>) -> Result<(U256, U256), FactsError>;

    /// Get grace period remaining in seconds for a position.
    /// Returns the time remaining until the grace period expires, or 0 if expired.
    fn grace_period_remaining(&self, position_id: FixedBytes<32>) -> Result<u64, FactsError>;

    fn staticcall_u256(
        &self,
        target: Address,
        selector: [u8; 4],
        args: &[u8],
    ) -> Result<U256, FactsError>;
}

