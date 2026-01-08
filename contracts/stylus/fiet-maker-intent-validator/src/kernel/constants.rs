//! Kernel constants mirrored from `kernel/src/types/Constants.sol`.

use stylus_sdk::alloy_primitives::{FixedBytes, U256};

// ERC-4337 signature validation return codes.
pub const SIG_VALIDATION_SUCCESS_UINT: U256 = U256::ZERO;
pub const SIG_VALIDATION_FAILED_UINT: U256 = U256::from_limbs([1, 0, 0, 0]);

// ERC-1271 return codes.
pub const ERC1271_MAGICVALUE: FixedBytes<4> = FixedBytes([0x16, 0x26, 0xBA, 0x7E]);
pub const ERC1271_INVALID: FixedBytes<4> = FixedBytes([0xFF, 0xFF, 0xFF, 0xFF]);

// ERC-7579 module type IDs.
pub const MODULE_TYPE_VALIDATOR: U256 = U256::from_limbs([1, 0, 0, 0]);
pub const MODULE_TYPE_HOOK: U256 = U256::from_limbs([4, 0, 0, 0]);


