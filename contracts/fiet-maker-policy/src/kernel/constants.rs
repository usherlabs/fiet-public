//! Kernel constants mirrored from Kernel (ERC-7579 / Kernel v3).

use stylus_sdk::alloy_primitives::U256;

// ERC-7579 module type IDs (Kernel v3 uses Policy = 5).
pub const MODULE_TYPE_POLICY: U256 = U256::from_limbs([5, 0, 0, 0]);

// Policy return codes (Kernel treats non-zero validation data as failure).
pub const POLICY_SUCCESS_UINT: U256 = U256::ZERO;
pub const POLICY_FAILED_UINT: U256 = U256::from_limbs([1, 0, 0, 0]);


