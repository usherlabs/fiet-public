//! Stylus-based “Atomic Revalidation” intent validator (Option B scaffold).
//!
//! This contract is intended to be *Kernel-compatible* by implementing the same external ABI
//! surface as `IValidator` and (optionally) `IHook`.
//!
//! Important: the intent envelope / check-program interpreter is **not implemented** here yet.
//! This file provides the scaffolding and storage layout to plug in:
//! - signature verification,
//! - call-bundle binding,
//! - deadline + nonce replay protection,
//! - and atomic fact reads + opcode evaluation.

use alloc::vec::Vec;

use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes, U256},
    prelude::*,
};

use crate::kernel::constants::{
    ERC1271_INVALID, MODULE_TYPE_HOOK, MODULE_TYPE_VALIDATOR, SIG_VALIDATION_FAILED_UINT,
};

sol_storage! {
    /// Kernel-compatible validator storage.
    ///
    /// We keep this intentionally simple (separate mappings) to reduce risk around layout and
    /// make it easy to migrate later.
    #[entrypoint]
    pub struct IntentValidator {
        /// Authorised signer for a given Kernel smart account (keyed by smart account address).
        mapping(address => address) signer_of;
        /// Wallet-scoped replay nonce for intents (keyed by smart account address).
        mapping(address => uint256) nonce_of;
    }
}

#[public]
impl IntentValidator {
    /// Kernel module install hook.
    ///
    /// Expected `_data` layout (v0 scaffold):
    /// - `bytes20 signer` (first 20 bytes)
    ///
    /// TODO: Version and support more structured init data (e.g., initial nonce, allowlists).
    #[payable]
    pub fn on_install(&mut self, data: Vec<u8>) {
        let smart_account = self.vm().msg_sender();
        if self._is_initialized(smart_account) {
            // TODO: Revert with Kernel's `AlreadyInitialized(address)` custom error.
            panic!("Already initialised");
        }
        if data.len() < 20 {
            // TODO: Replace with a custom error.
            panic!("Invalid init data");
        }
        let signer = Address::from_slice(&data[0..20]);
        self.signer_of.insert(smart_account, signer);
        self.nonce_of.insert(smart_account, U256::ZERO);
    }

    /// Kernel module uninstall hook.
    #[payable]
    pub fn on_uninstall(&mut self, _data: Vec<u8>) {
        let smart_account = self.vm().msg_sender();
        if !self._is_initialized(smart_account) {
            // TODO: Revert with Kernel's `NotInitialized(address)` custom error.
            panic!("Not initialised");
        }
        self.signer_of.insert(smart_account, Address::ZERO);
        self.nonce_of.insert(smart_account, U256::ZERO);
    }

    /// ERC-7579 module-type detection.
    pub fn is_module_type(&self, module_type_id: U256) -> bool {
        module_type_id == MODULE_TYPE_VALIDATOR || module_type_id == MODULE_TYPE_HOOK
    }

    /// ERC-7579 initialisation check.
    pub fn is_initialized(&self, smart_account: Address) -> bool {
        self._is_initialized(smart_account)
    }

    /// Kernel `IValidator.validateUserOp`.
    ///
    /// NOTE: Kernel expects the smart account to call the validator during its validation flow,
    /// so `msg.sender` here is the *smart account*.
    #[payable]
    pub fn validate_user_op(
        &mut self,
        _packed_user_op: Vec<u8>,
        _user_op_hash: FixedBytes<32>,
    ) -> U256 {
        let smart_account = self.vm().msg_sender();
        if !self._is_initialized(smart_account) {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // TODO (Option B):
        // - Parse intent envelope from `_user_op.signature` (or a dedicated field).
        // - Verify signature (EIP-712 / typed data) against `signer_of[smart_account]`.
        // - Enforce deadline and wallet-scoped nonce (using `nonce_of` or a bitmap).
        // - Bind intent to execution payload (derive and compare `call_bundle_hash`).
        // - Acquire atomic facts via allowlisted `staticcall`s (gas-capped).
        // - Evaluate the check program (bounded interpreter).
        //
        // For now, fail closed.
        SIG_VALIDATION_FAILED_UINT
    }

    /// Kernel `IValidator.isValidSignatureWithSender` (ERC-1271).
    pub fn is_valid_signature_with_sender(
        &self,
        _sender: Address,
        _hash: FixedBytes<32>,
        _data: Vec<u8>,
    ) -> FixedBytes<4> {
        // TODO: Implement ERC-1271 to mirror the same intent-signature validity checks.
        // For now, fail closed.
        ERC1271_INVALID
    }

    /// Kernel `IHook.preCheck`.
    ///
    /// This hook runs before the smart account executes a call.
    /// For intent validation, this is a good place to enforce call allowlists / selectors as
    /// an additional belt-and-braces guard (and to bind to `msg.data`).
    #[payable]
    pub fn pre_check(&self, _msg_sender: Address, _msg_value: U256, _msg_data: Vec<u8>) -> Vec<u8> {
        // TODO: Enforce any runtime preconditions and return context for post_check.
        Vec::new()
    }

    /// Kernel `IHook.postCheck`.
    #[payable]
    pub fn post_check(&self, _hook_data: Vec<u8>) {
        // TODO: Optional post-exec invariants / accounting.
    }
}

impl IntentValidator {
    fn _is_initialized(&self, smart_account: Address) -> bool {
        self.signer_of.get(smart_account) != Address::ZERO
    }

    #[allow(dead_code)]
    fn _nonce(&self, smart_account: Address) -> U256 {
        self.nonce_of.get(smart_account)
    }
}
