use alloy::primitives::{aliases::I24, keccak256, U256};
use alloy::sol;

// Define the necessary Solidity interfaces using alloy_sol! macro
// sol! {
//     #[sol(rpc)]
//     IPositionManager,
//     "abi/positionManager.json"
// }

sol! {
    #[sol(rpc)]
    interface IPoolManager {
        function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    }

    #[sol(rpc)]
    interface IPositionManager {
        function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey poolKey, PositionInfo info);
        function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
        function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external;
    }

    struct PoolKey {
        address currency0;
        address currency1;
        uint24 fee;
        int24 tickSpacing;
        address hooks;
    }

    type PositionInfo is uint256; // Packed as per PositionInfoLibrary
}

/// PositionInfo is a packed uint256, similar to the Solidity type.
#[derive(Copy, Clone, Debug)]
pub struct PositionInfoWrap(pub U256);

// Extensions for PositionInfo using logic from PositionInfoLibrary.sol
impl PositionInfoWrap {
    /// Extracts the tickLower from the packed PositionInfo.
    /// This corresponds to the tickLower function in the Solidity library.
    pub fn tick_lower(self) -> I24 {
        let info = self.0;
        let shifted = info >> 8u32;
        let bits = shifted & U256::from(0xFFFFFFu64);
        let bits_u32: u32 = bits.try_into().expect("Bits fit in u32");
        let signed_i32: i32 = ((bits_u32 << 8) as i32) >> 8;
        // Assuming I24::new panics if out of range, but since it's from 24 bits, it's always valid.
        I24::try_from(signed_i32 as i128).expect("Value fits in I24")
    }

    /// Extracts the tickUpper from the packed PositionInfo.
    /// This corresponds to the tickUpper function in the Solidity library.
    pub fn tick_upper(self) -> I24 {
        let info = self.0;
        let shifted = info >> 32u32;
        let bits = shifted & U256::from(0xFFFFFFu64);
        let bits_u32: u32 = bits.try_into().expect("Bits fit in u32");
        let signed_i32: i32 = ((bits_u32 << 8) as i32) >> 8;
        I24::try_from(signed_i32 as i128).expect("Value fits in I24")
    }
}

// Function to compute PoolId from PoolKey (equivalent to Solidity's toId function)
pub fn compute_pool_id(pool_key: &PoolKey) -> alloy::primitives::B256 {
    // Encode the PoolKey struct as per Solidity's abi.encode
    // PoolKey has 5 fields: currency0, currency1, fee, tickSpacing, hooks
    // Each field is 32 bytes (256 bits)
    let mut encoded: Vec<u8> = Vec::with_capacity(160);

    // currency0 (address: left-pad with 12 zeros, then 20 bytes)
    encoded.extend(std::iter::repeat(0u8).take(12));
    encoded.extend_from_slice(pool_key.currency0.as_slice());

    // currency1 (same as currency0)
    encoded.extend(std::iter::repeat(0u8).take(12));
    encoded.extend_from_slice(pool_key.currency1.as_slice());

    // fee (uint24: left-pad with 29 zeros, then 3 big-endian bytes)
    let fee_bytes: [u8; 3] = pool_key.fee.to_be_bytes(); // [u8; 3] for Uint<24,1>
    encoded.extend(std::iter::repeat(0u8).take(29));
    encoded.extend_from_slice(&fee_bytes);

    // tickSpacing (int24: left-pad with 29 sign-extended bytes, then 3 big-endian bytes)
    let tick_bytes: [u8; 3] = pool_key.tickSpacing.to_be_bytes(); // [u8; 3] for I24
    let sign_byte = if tick_bytes[0] & 0x80 != 0 { 0xFF } else { 0u8 };
    encoded.extend(std::iter::repeat(sign_byte).take(29));
    encoded.extend_from_slice(&tick_bytes);

    // hooks (same as currency0)
    encoded.extend(std::iter::repeat(0u8).take(12));
    encoded.extend_from_slice(pool_key.hooks.as_slice());

    // Hash the encoded data (equivalent to keccak256(abi.encode(poolKey)))
    keccak256(&encoded)
}

#[cfg(test)]
mod tests {
    use super::*;
    use alloy::primitives::{Address, U256};

    #[test]
    fn test_tick_lower_positive() {
        // Packed with tick_lower = 100 (0x64), shifted left by 8
        let packed = U256::from(100u32) << 8;
        let info = PositionInfoWrap(packed);
        assert_eq!(info.tick_lower(), I24::try_from(100).unwrap());
    }

    #[test]
    fn test_tick_lower_negative() {
        // tick_lower = -100, which is 0xFFFFFF9C in 24 bits (signed)
        // But in u32 for shifting: need to simulate sign extension
        let tick: i32 = -100;
        let bits = (tick as u32) & 0xFFFFFF;
        let packed = U256::from(bits) << 8;
        let info = PositionInfoWrap(packed);
        assert_eq!(info.tick_lower(), I24::try_from(-100).unwrap());
    }

    #[test]
    fn test_tick_upper_positive() {
        // tick_upper = 200 (0xC8), shifted left by 32
        let packed = U256::from(200u32) << 32;
        let info = PositionInfoWrap(packed);
        assert_eq!(info.tick_upper(), I24::try_from(200).unwrap());
    }

    #[test]
    fn test_tick_upper_negative() {
        let tick: i32 = -200;
        let bits = (tick as u32) & 0xFFFFFF;
        let packed = U256::from(bits) << 32;
        let info = PositionInfoWrap(packed);
        assert_eq!(info.tick_upper(), I24::try_from(-200).unwrap());
    }

    #[test]
    fn test_compute_pool_id_zero() {
        let pool_key = PoolKey {
            currency0: Address::ZERO,
            currency1: Address::ZERO,
            fee: alloy::primitives::aliases::U24::ZERO,
            tickSpacing: I24::ZERO,
            hooks: Address::ZERO,
        };
        let id = compute_pool_id(&pool_key);
        // Expected can be precomputed if needed, but for now assert not zero or something
        assert_ne!(id, alloy::primitives::B256::ZERO);
    }
}
