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

    fn staticcall_u256(
        &self,
        target: Address,
        selector: [u8; 4],
        args: &[u8],
    ) -> Result<U256, FactsError>;
}

