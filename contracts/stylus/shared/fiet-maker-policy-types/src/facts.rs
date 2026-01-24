use alloy_primitives::{Address, FixedBytes, U256};

/// Errors during fact acquisition.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FactsError {
    /// Used by off-chain mocks or partially implemented providers.
    NotImplemented,
    /// Attempted to `staticcall` a target/selector that is not allowlisted.
    ForbiddenCall { target: Address, selector: [u8; 4] },
    /// The underlying call failed.
    CallFailed,
    /// Return data was malformed or could not be decoded.
    MalformedReturn,
}

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

    /// Get settled amounts for a position (amount0, amount1).
    fn get_settled_amounts(
        &self,
        _position_id: FixedBytes<32>,
    ) -> Result<(U256, U256), FactsError> {
        Err(FactsError::NotImplemented)
    }

    /// Get commitment maxima for a position (commitment0, commitment1).
    fn get_commitment_maxima(
        &self,
        _position_id: FixedBytes<32>,
    ) -> Result<(U256, U256), FactsError> {
        Err(FactsError::NotImplemented)
    }

    /// Get grace period remaining in seconds for a position.
    /// Returns the time remaining until the grace period expires, or 0 if expired.
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

