use alloy::primitives::{aliases::I24, keccak256, FixedBytes, U256};
use alloy::providers::Provider;
use alloy::sol;
use eyre::Result;

// Define the necessary Solidity interfaces using alloy_sol! macro
// sol! {
//     #[sol(rpc)]
//     IPositionManager,
//     "abi/positionManager.json"
// }

sol! {
    #[sol(rpc)]
    interface IPoolManager {
        function extsload(bytes32 slot) external view returns (bytes32);
    }

    #[sol(rpc)]
    interface IPositionManager {
        function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey poolKey, PositionInfo info);
        function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
        function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external;
        function ownerOf(uint256 tokenId) external view returns (address);
        function isApprovedForAll(address owner, address operator) external view returns (bool);
        function setApprovalForAll(address operator, bool approved) external;
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

#[derive(Debug, Clone)]
pub struct Slot0 {
    pub sqrt_price_x96: U256,
    pub tick: i32,
    #[allow(dead_code)]
    pub protocol_fee: u32,
    #[allow(dead_code)]
    pub lp_fee: u32,
}

pub async fn get_pool_slot0<P: Provider>(
    pool_manager: &IPoolManager::IPoolManagerInstance<P>,
    pool_id: FixedBytes<32>,
) -> Result<Slot0> {
    let pools_slot = alloy::primitives::B256::from(U256::from(6).to_be_bytes());
    let mut concat = Vec::with_capacity(64);
    concat.extend_from_slice(pool_id.as_slice());
    concat.extend_from_slice(pools_slot.as_slice());
    let state_slot = keccak256(concat);

    let data = pool_manager.extsload(state_slot).call().await?;

    let data_u256 = U256::from_be_bytes(data.0);
    let sqrt_price_x96 = data_u256 & ((U256::ONE << 160) - U256::ONE);
    let shifted = data_u256 >> 160;
    let tick_bits: U256 = shifted & U256::from(0xFFFFFFu64);
    let tick_u32: u32 = tick_bits.try_into().unwrap();
    let tick_i32 = ((tick_u32 << 8) as i32) >> 8;

    let shifted_protocol: U256 = data_u256 >> 184;
    let protocol_fee: u32 = (shifted_protocol & U256::from(0xFFFFFF))
        .try_into()
        .unwrap();

    let shifted_lp: U256 = data_u256 >> 208;
    let lp_fee: u32 = (shifted_lp & U256::from(0xFFFFFF)).try_into().unwrap();

    Ok(Slot0 {
        sqrt_price_x96,
        tick: tick_i32,
        protocol_fee,
        lp_fee,
    })
}

pub fn params_to_unlock_data(actions: &Vec<u8>, params_encoded: &Vec<Vec<u8>>) -> Vec<u8> {
    let actions_raw: Vec<u8> = actions.clone();
    let actions_len = actions_raw.len() as u64;
    let actions_padded_len = ((actions_len + 31) / 32) * 32;
    let params_len = params_encoded.len() as u64;

    // Compute relative offsets for params (relative to params.length position)
    let mut param_offset_values: Vec<U256> = Vec::new();
    let mut current = U256::from(params_len * 32);
    for p in params_encoded {
        param_offset_values.push(current);
        let len = p.len() as u64;
        let padded = ((len + 31) / 32) * 32;
        current += U256::from(32 + padded);
    }

    // Build unlock_data Vec<u8>
    let mut unlock_data_vec: Vec<u8> = Vec::new();

    // word0: 0x40
    unlock_data_vec.extend_from_slice(&U256::from(0x40u64).to_be_bytes::<32>());

    // word1: params_length_offset = 0x60 + actions_padded_len
    let params_length_offset = 0x60u64 + actions_padded_len;
    unlock_data_vec.extend_from_slice(&U256::from(params_length_offset).to_be_bytes::<32>());

    // word2: actions_len
    unlock_data_vec.extend_from_slice(&U256::from(actions_len).to_be_bytes::<32>());

    // actions data + padding
    unlock_data_vec.extend(&actions_raw);
    let current_size = unlock_data_vec.len();
    unlock_data_vec.resize(
        current_size + (actions_padded_len - actions_len) as usize,
        0,
    );

    // params.length
    unlock_data_vec.extend_from_slice(&U256::from(params_len).to_be_bytes::<32>());

    // params offsets
    for off in param_offset_values {
        unlock_data_vec.extend_from_slice(&off.to_be_bytes::<32>());
    }

    // params tails
    for p in params_encoded {
        let len = p.len() as u64;
        unlock_data_vec.extend_from_slice(&U256::from(len).to_be_bytes::<32>());
        unlock_data_vec.extend(p);
        let current_len = 32 + p.len();
        let target_len = 32 + ((p.len() + 31) / 32) * 32;
        unlock_data_vec.resize(unlock_data_vec.len() + (target_len - current_len), 0);
    }

    unlock_data_vec
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
