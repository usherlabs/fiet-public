//! Stylus-based “Atomic Revalidation” intent **policy** for Kernel permissions.
//!
//! This module is intended to be ERC-7579 / Kernel-compatible by implementing the same external
//! ABI surface as `IPolicy` (module type 5).
//!
//! Design notes:
//! - The PermissionValidator’s signer remains the sole “who” (authorisation).
//! - This policy is purely “when”: it enforces an intent envelope over the UserOp’s call bundle
//!   and evaluates a check-program over on-chain facts.
//! - Kernel slices a per-policy signature blob into `userOp.signature` before calling
//!   `checkUserOpPolicy`; this policy treats `userOp.signature` as its envelope payload.

use alloc::vec::Vec;

use stylus_sdk::{
    alloy_primitives::{keccak256, Address, FixedBytes, U256},
    prelude::*,
};

use alloy_sol_types::sol;
use stylus_sdk::stylus_proc::SolidityError;

use crate::{
    decoder::decode_program,
    evaluator::evaluate_program,
    facts::onchain::{FactSources, OnchainFactsProvider},
    kernel::constants::{MODULE_TYPE_POLICY, POLICY_FAILED_UINT, POLICY_SUCCESS_UINT},
    utils::{
        crypto::ecrecover_address,
        kernel::{composite_key, split_policy_install_data},
        policy_envelope::{parse_policy_envelope, policy_intent_digest},
    },
};

sol! {
    error AlreadyInitialized(address smartAccount);
    error NotInitialized(address smartAccount);
}

#[derive(SolidityError)]
pub enum ModuleError {
    AlreadyInitialized(AlreadyInitialized),
    NotInitialized(NotInitialized),
}

sol_storage! {
    /// Kernel-compatible policy storage (scoped by wallet + permissionId).
    #[entrypoint]
    pub struct IntentPolicy {
        /// Number of installed permission ids for a wallet (for `isInitialized`).
        mapping(address => uint256) used_ids;

        /// Replay nonce for (wallet, permissionId).
        mapping(bytes32 => uint256) nonce_of;

        /// Authorised signer for (wallet, permissionId).
        ///
        /// Purpose: authenticate the policy envelope payload. Without this, an attacker who can
        /// produce a valid UserOp under the permission signer could tamper with the policy-local
        /// signature slice (e.g. weaken `program_bytes`) without changing `callData`.
        mapping(bytes32 => address) signer_of;

        /// Canonical fact sources for (wallet, permissionId).
        mapping(bytes32 => address) state_view_of;
        mapping(bytes32 => address) vts_orchestrator_of;
        mapping(bytes32 => address) liquidity_hub_of;
    }
}

#[public]
impl IntentPolicy {
    /// ERC-7579 install hook.
    ///
    /// Mirrors Kernel `PolicyBase` packing: `bytes data = bytes32 permissionId || initData`.
    ///
    /// `initData` layout:
    /// - `uint8 version = 1`
    /// - `bytes20 signer` (authorised envelope signer)
    /// - `bytes20 stateView`
    /// - `bytes20 vtsOrchestrator`
    /// - `bytes20 liquidityHub`
    #[payable]
    pub fn on_install(&mut self, data: Vec<u8>) -> Result<(), ModuleError> {
        let wallet = self.vm().msg_sender();
        // Keep revert semantics deterministic; panic on malformed init data.
        let (permission_id, init_data) =
            split_policy_install_data(&data).unwrap_or_else(|_| panic!("Invalid init data"));

        let key = composite_key(wallet, permission_id);
        if self._is_installed_key(key) {
            return Err(ModuleError::AlreadyInitialized(AlreadyInitialized {
                smartAccount: wallet,
            }));
        }

        if init_data.len() != 1 + 20 + 20 + 20 + 20 {
            panic!("Invalid init data length");
        }
        let version = init_data[0];
        if version != 1 {
            panic!("Unsupported init version");
        }

        let signer = Address::from_slice(&init_data[1..21]);
        let state_view = Address::from_slice(&init_data[21..41]);
        let vts_orchestrator = Address::from_slice(&init_data[41..61]);
        let liquidity_hub = Address::from_slice(&init_data[61..81]);

        if signer == Address::ZERO {
            panic!("Invalid signer");
        }
        if state_view == Address::ZERO || vts_orchestrator == Address::ZERO || liquidity_hub == Address::ZERO {
            panic!("Invalid fact sources");
        }

        self.nonce_of.insert(key, U256::ZERO);
        self.signer_of.insert(key, signer);
        self.state_view_of.insert(key, state_view);
        self.vts_orchestrator_of.insert(key, vts_orchestrator);
        self.liquidity_hub_of.insert(key, liquidity_hub);
        self.used_ids.insert(wallet, self.used_ids.get(wallet).saturating_add(U256::from(1u64)));
        Ok(())
    }

    /// ERC-7579 uninstall hook.
    #[payable]
    pub fn on_uninstall(&mut self, data: Vec<u8>) -> Result<(), ModuleError> {
        let wallet = self.vm().msg_sender();
        // Keep revert semantics deterministic; panic on malformed uninstall data.
        let (permission_id, _init_data) =
            split_policy_install_data(&data).unwrap_or_else(|_| panic!("Invalid uninstall data"));

        let key = composite_key(wallet, permission_id);
        if !self._is_installed_key(key) {
            return Err(ModuleError::NotInitialized(NotInitialized {
                smartAccount: wallet,
            }));
        }

        self.nonce_of.insert(key, U256::ZERO);
        self.signer_of.insert(key, Address::ZERO);
        self.state_view_of.insert(key, Address::ZERO);
        self.vts_orchestrator_of.insert(key, Address::ZERO);
        self.liquidity_hub_of.insert(key, Address::ZERO);
        self.used_ids.insert(wallet, self.used_ids.get(wallet).saturating_sub(U256::from(1u64)));
        Ok(())
    }

    /// ERC-7579 module-type detection.
    pub fn is_module_type(&self, module_type_id: U256) -> bool {
        module_type_id == MODULE_TYPE_POLICY
    }

    /// ERC-7579 initialisation check (wallet-level).
    pub fn is_initialized(&self, wallet: Address) -> bool {
        self.used_ids.get(wallet) != U256::ZERO
    }

    /// Kernel `IPolicy.checkUserOpPolicy`.
    ///
    /// `user_op.signature` here is the policy-specific signature slice provided by Kernel’s
    /// PermissionValidator pipeline.
    #[payable]
    pub fn check_user_op_policy(
        &mut self,
        permission_id: FixedBytes<32>,
        // NOTE: we take this as a tuple (instead of a `sol!` struct) because Stylus' `#[public]`
        // ABI glue supports tuples via `AbiType`, and a Solidity `struct` is ABI-equivalent to a tuple.
        //
        // PackedUserOperation fields (ERC-4337 / Kernel):
        // (sender, nonce, initCode, callData, accountGasLimits, preVerificationGas, gasFees, paymasterAndData, signature)
        user_op: (
            Address,
            U256,
            Vec<u8>,
            Vec<u8>,
            FixedBytes<32>,
            U256,
            FixedBytes<32>,
            Vec<u8>,
            Vec<u8>,
        ),
    ) -> U256 {
        let wallet = self.vm().msg_sender();
        let key = composite_key(wallet, permission_id);
        if !self._is_installed_key(key) {
            return POLICY_FAILED_UINT;
        }

        let (
            _sender,
            _nonce,
            _init_code,
            call_data,
            _account_gas_limits,
            _pre_verification_gas,
            _gas_fees,
            _paymaster_and_data,
            policy_sig_bytes,
        ) = user_op;

        let env = match parse_policy_envelope(&policy_sig_bytes) {
            Ok(e) => e,
            Err(_) => return POLICY_FAILED_UINT,
        };

        if env.version != 1u16 {
            return POLICY_FAILED_UINT;
        }
        if self.vm().block_timestamp() > env.deadline {
            return POLICY_FAILED_UINT;
        }

        // Bind to execution payload: keccak256(callData).
        let computed_bundle_hash: FixedBytes<32> = keccak256(call_data.as_slice());
        if computed_bundle_hash != env.call_bundle_hash {
            return POLICY_FAILED_UINT;
        }

        // Replay protection (permission-scoped nonce).
        let expected_nonce = self.nonce_of.get(key);
        if env.nonce != expected_nonce {
            return POLICY_FAILED_UINT;
        }

        // Authenticate the envelope payload.
        //
        // Purpose: Kernel's permission pipeline passes each policy a policy-local signature slice.
        // Without an explicit signature over the envelope fields, an attacker could tamper with
        // `program_bytes` while keeping `callData` constant, effectively bypassing validation.
        let expected_signer = self.signer_of.get(key);
        if expected_signer == Address::ZERO {
            return POLICY_FAILED_UINT;
        }
        let digest = policy_intent_digest(
            self.vm().chain_id(),
            self.vm().contract_address(),
            wallet,
            permission_id,
            env.nonce,
            env.deadline,
            env.call_bundle_hash,
            &env.program_bytes,
        );
        let recovered = match ecrecover_address(digest, &env.signature) {
            Ok(a) => a,
            Err(_) => return POLICY_FAILED_UINT,
        };
        if recovered != expected_signer {
            return POLICY_FAILED_UINT;
        }

        // Decode + evaluate program against atomic facts.
        let checks = match decode_program(&env.program_bytes) {
            Ok(c) => c,
            Err(_) => return POLICY_FAILED_UINT,
        };

        let sources = FactSources {
            state_view: self.state_view_of.get(key),
            vts_orchestrator: self.vts_orchestrator_of.get(key),
            liquidity_hub: self.liquidity_hub_of.get(key),
        };
        if sources.state_view == Address::ZERO
            || sources.vts_orchestrator == Address::ZERO
            || sources.liquidity_hub == Address::ZERO
        {
            return POLICY_FAILED_UINT;
        }

        let facts = OnchainFactsProvider::new(sources, 200_000, self.vm().block_timestamp());
        let ok = evaluate_program(&checks, &facts);
        if ok.is_err() {
            return POLICY_FAILED_UINT;
        }

        // All checks passed; consume nonce.
        self.nonce_of
            .insert(key, expected_nonce.saturating_add(U256::from(1u64)));

        POLICY_SUCCESS_UINT
    }

    /// Kernel `IPolicy.checkSignaturePolicy`.
    ///
    /// This policy is UserOp-only (returns pass).
    pub fn check_signature_policy(
        &self,
        _permission_id: FixedBytes<32>,
        _sender: Address,
        _hash: FixedBytes<32>,
        _sig: Vec<u8>,
    ) -> U256 {
        POLICY_SUCCESS_UINT
    }
}

impl IntentPolicy {
    fn _is_installed_key(&self, key: FixedBytes<32>) -> bool {
        self.state_view_of.get(key) != Address::ZERO
    }
}


