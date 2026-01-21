//! Kernel / ERC-7579 related helpers.

use alloc::vec::Vec;

use stylus_sdk::alloy_primitives::{keccak256, Address, FixedBytes};

/// Composite storage key = keccak256(wallet || permissionId).
///
/// Purpose: policy configuration is scoped by both the wallet and permission id (Kernel permission config).
pub fn composite_key(wallet: Address, permission_id: FixedBytes<32>) -> FixedBytes<32> {
    let mut buf = Vec::with_capacity(20 + 32);
    buf.extend_from_slice(wallet.as_slice());
    buf.extend_from_slice(permission_id.as_slice());
    keccak256(buf)
}

/// Split Kernel policy install bytes into `(permissionId, initData)`.
///
/// Kernel `PolicyBase` uses `bytes data = bytes32 id || _data`.
pub fn split_policy_install_data(data: &[u8]) -> Result<(FixedBytes<32>, &[u8]), ()> {
    if data.len() < 32 {
        return Err(());
    }
    let mut id_buf = [0u8; 32];
    id_buf.copy_from_slice(&data[0..32]);
    Ok((FixedBytes(id_buf), &data[32..]))
}

