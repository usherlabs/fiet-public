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
    kernel::types::PackedUserOperation,
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
    /// - `bytes20 stateView`
    /// - `bytes20 vtsOrchestrator`
    /// - `bytes20 liquidityHub`
    #[payable]
    pub fn on_install(&mut self, data: Vec<u8>) -> Result<(), ModuleError> {
        let wallet = self.vm().msg_sender();
        let (permission_id, init_data) = split_policy_install_data(&data).map_err(|_| {
            // Keep revert semantics deterministic; use a panic for malformed init data
            // consistent with the existing scaffold.
            panic!("Invalid init data")
        })?;

        let key = composite_key(wallet, permission_id);
        if self._is_installed_key(key) {
            return Err(ModuleError::AlreadyInitialized(AlreadyInitialized {
                smartAccount: wallet,
            }));
        }

        if init_data.len() != 1 + 20 + 20 + 20 {
            panic!("Invalid init data length");
        }
        let version = init_data[0];
        if version != 1 {
            panic!("Unsupported init version");
        }

        let state_view = Address::from_slice(&init_data[1..21]);
        let vts_orchestrator = Address::from_slice(&init_data[21..41]);
        let liquidity_hub = Address::from_slice(&init_data[41..61]);

        if state_view == Address::ZERO || vts_orchestrator == Address::ZERO || liquidity_hub == Address::ZERO {
            panic!("Invalid fact sources");
        }

        self.nonce_of.insert(key, U256::ZERO);
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
        let (permission_id, _init_data) = split_policy_install_data(&data).map_err(|_| {
            panic!("Invalid uninstall data")
        })?;

        let key = composite_key(wallet, permission_id);
        if !self._is_installed_key(key) {
            return Err(ModuleError::NotInitialized(NotInitialized {
                smartAccount: wallet,
            }));
        }

        self.nonce_of.insert(key, U256::ZERO);
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
        user_op: PackedUserOperation,
    ) -> U256 {
        let wallet = self.vm().msg_sender();
        let key = composite_key(wallet, permission_id);
        if !self._is_installed_key(key) {
            return POLICY_FAILED_UINT;
        }

        let env = match parse_policy_envelope(&user_op.signature) {
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
        let computed_bundle_hash: FixedBytes<32> = keccak256(user_op.callData.as_ref());
        if computed_bundle_hash != env.call_bundle_hash {
            return POLICY_FAILED_UINT;
        }

        // Replay protection (permission-scoped nonce).
        let expected_nonce = self.nonce_of.get(key);
        if env.nonce != expected_nonce {
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

/// Composite storage key = keccak256(wallet || permissionId).
fn composite_key(wallet: Address, permission_id: FixedBytes<32>) -> FixedBytes<32> {
    let mut buf = Vec::with_capacity(20 + 32);
    buf.extend_from_slice(wallet.as_slice());
    buf.extend_from_slice(permission_id.as_slice());
    keccak256(buf)
}

fn split_policy_install_data(data: &[u8]) -> Result<(FixedBytes<32>, &[u8]), ()> {
    if data.len() < 32 {
        return Err(());
    }
    let mut id_buf = [0u8; 32];
    id_buf.copy_from_slice(&data[0..32]);
    Ok((FixedBytes(id_buf), &data[32..]))
}

/// Parsed policy envelope (v1).
struct ParsedPolicyIntent {
    version: u16,
    nonce: U256,
    deadline: u64,
    call_bundle_hash: FixedBytes<32>,
    program_bytes: Vec<u8>,
}

/// Parse the policy-specific `userOp.signature` slice into an intent envelope.
///
/// Layout (big-endian for integer fields):
/// - u16 version
/// - bytes32 nonce (u256)
/// - u64 deadline
/// - bytes32 call_bundle_hash
/// - u32 program_len
/// - bytes program_bytes
fn parse_policy_envelope(sig: &[u8]) -> Result<ParsedPolicyIntent, ()> {
    let mut i = 0usize;
    if sig.len() < 2 + 32 + 8 + 32 + 4 {
        return Err(());
    }

    let version = read_u16(sig, &mut i)?;
    let nonce = read_u256(sig, &mut i)?;
    let deadline = read_u64(sig, &mut i)?;
    let call_bundle_hash = read_b32(sig, &mut i)?;
    let program_len = read_u32(sig, &mut i)? as usize;
    let program_bytes = read_vec(sig, &mut i, program_len)?;
    if i != sig.len() {
        // reject trailing bytes for determinism
        return Err(());
    }

    Ok(ParsedPolicyIntent {
        version,
        nonce,
        deadline,
        call_bundle_hash,
        program_bytes,
    })
}

fn read_vec(bytes: &[u8], i: &mut usize, len: usize) -> Result<Vec<u8>, ()> {
    if bytes.len() < *i + len {
        return Err(());
    }
    let out = bytes[*i..*i + len].to_vec();
    *i += len;
    Ok(out)
}

fn read_u16(bytes: &[u8], i: &mut usize) -> Result<u16, ()> {
    if bytes.len() < *i + 2 {
        return Err(());
    }
    let mut buf = [0u8; 2];
    buf.copy_from_slice(&bytes[*i..*i + 2]);
    *i += 2;
    Ok(u16::from_be_bytes(buf))
}

fn read_u32(bytes: &[u8], i: &mut usize) -> Result<u32, ()> {
    if bytes.len() < *i + 4 {
        return Err(());
    }
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&bytes[*i..*i + 4]);
    *i += 4;
    Ok(u32::from_be_bytes(buf))
}

fn read_u64(bytes: &[u8], i: &mut usize) -> Result<u64, ()> {
    if bytes.len() < *i + 8 {
        return Err(());
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&bytes[*i..*i + 8]);
    *i += 8;
    Ok(u64::from_be_bytes(buf))
}

fn read_u256(bytes: &[u8], i: &mut usize) -> Result<U256, ()> {
    if bytes.len() < *i + 32 {
        return Err(());
    }
    let out = U256::from_be_slice(&bytes[*i..*i + 32]);
    *i += 32;
    Ok(out)
}

fn read_b32(bytes: &[u8], i: &mut usize) -> Result<FixedBytes<32>, ()> {
    if bytes.len() < *i + 32 {
        return Err(());
    }
    let mut buf = [0u8; 32];
    buf.copy_from_slice(&bytes[*i..*i + 32]);
    *i += 32;
    Ok(FixedBytes(buf))
}


