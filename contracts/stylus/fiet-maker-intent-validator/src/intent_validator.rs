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
    alloy_primitives::{keccak256, Address, FixedBytes, U256},
    call::RawCall,
    prelude::*,
};

use crate::kernel::constants::{
    ERC1271_INVALID, ERC1271_MAGICVALUE, MODULE_TYPE_HOOK, MODULE_TYPE_VALIDATOR,
    SIG_VALIDATION_FAILED_UINT, SIG_VALIDATION_SUCCESS_UINT,
};

use crate::{
    decoder::decode_program,
    evaluator::evaluate_program,
    facts::onchain::{FactSources, OnchainFactsProvider},
};

use crate::kernel::types::PackedUserOperation;

use alloy_sol_types::SolType;

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

        /// Canonical fact sources (per smart account).
        mapping(address => address) state_view_of;
        mapping(address => address) vts_orchestrator_of;
        mapping(address => address) liquidity_hub_of;

        /// Per smart account token allowlist. // TODO: Remove this.
        mapping(address => mapping(address => bool)) token_allowed;
    }
}

#[public]
impl IntentValidator {
    /// Kernel module install hook.
    ///
    /// Expected `_data` layout (v0 scaffold):
    /// - `bytes20 signer` (first 20 bytes)
    /// - `bytes20 stateView` (next 20 bytes)
    /// - `bytes20 vtsOrchestrator` (next 20 bytes)
    /// - `bytes20 liquidityHub` (next 20 bytes)
    /// - `uint8 tokenCount` (optional)
    /// - `tokenCount * bytes20` tokens (optional)
    ///
    /// TODO: Version and support more structured init data (e.g., initial nonce, allowlists).
    #[payable]
    pub fn on_install(&mut self, data: Vec<u8>) {
        let smart_account = self.vm().msg_sender();
        if self._is_initialized(smart_account) {
            // TODO: Revert with Kernel's `AlreadyInitialized(address)` custom error.
            panic!("Already initialised");
        }
        if data.len() < 80 {
            // TODO: Replace with a custom error.
            panic!("Invalid init data");
        }
        let signer = Address::from_slice(&data[0..20]);
        let state_view = Address::from_slice(&data[20..40]);
        let vts_orchestrator = Address::from_slice(&data[40..60]);
        let liquidity_hub = Address::from_slice(&data[60..80]);

        self.signer_of.insert(smart_account, signer);
        self.nonce_of.insert(smart_account, U256::ZERO);

        self.state_view_of.insert(smart_account, state_view);
        self.vts_orchestrator_of
            .insert(smart_account, vts_orchestrator);
        self.liquidity_hub_of.insert(smart_account, liquidity_hub);

        // Optional token allowlist.
        if data.len() > 80 {
            let token_count = data[80] as usize;
            let mut off = 81usize;
            for _ in 0..token_count {
                if data.len() < off + 20 {
                    panic!("Invalid token list");
                }
                let token = Address::from_slice(&data[off..off + 20]);
                off += 20;
                self.token_allowed.setter(smart_account).insert(token, true);
            }
        }
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
        self.state_view_of.insert(smart_account, Address::ZERO);
        self.vts_orchestrator_of
            .insert(smart_account, Address::ZERO);
        self.liquidity_hub_of.insert(smart_account, Address::ZERO);
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
        packed_user_op: Vec<u8>,
        _user_op_hash: FixedBytes<32>,
    ) -> U256 {
        let smart_account = self.vm().msg_sender();
        if !self._is_initialized(smart_account) {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // Decode PackedUserOperation for access to callData + signature payload.
        let user_op = match PackedUserOperation::abi_decode(&packed_user_op, true) {
            Ok(u) => u,
            Err(_) => return SIG_VALIDATION_FAILED_UINT,
        };

        // Parse intent envelope from userOp.signature.
        let env = match parse_intent_envelope(&user_op.signature) {
            Ok(e) => e,
            Err(_) => return SIG_VALIDATION_FAILED_UINT,
        };

        // Version pinning.
        if env.version != 1u16 {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // Envelope deadline (fail closed).
        if self.vm().block_timestamp() > env.deadline {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // Bind to execution payload (v0: keccak256(callData)).
        let computed_bundle_hash: FixedBytes<32> = keccak256(user_op.callData.as_ref());
        if computed_bundle_hash != env.call_bundle_hash {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // Replay protection (wallet-scoped nonce).
        let expected_nonce = self.nonce_of.get(smart_account);
        if env.nonce != expected_nonce {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // Verify intent signature (fail closed).
        let expected_signer = self.signer_of.get(smart_account);
        let digest = intent_digest(
            self.vm().chain_id(),
            self.vm().contract_address(),
            smart_account,
            env.nonce,
            env.deadline,
            env.call_bundle_hash,
            &env.program_bytes,
        );
        let recovered = match ecrecover_address(digest, &env.signature) {
            Ok(a) => a,
            Err(_) => return SIG_VALIDATION_FAILED_UINT,
        };
        if recovered != expected_signer {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // Decode + evaluate program against atomic facts.
        let checks = match decode_program(&env.program_bytes) {
            Ok(c) => c,
            Err(_) => return SIG_VALIDATION_FAILED_UINT,
        };

        let sources = FactSources {
            state_view: self.state_view_of.get(smart_account),
            vts_orchestrator: self.vts_orchestrator_of.get(smart_account),
            liquidity_hub: self.liquidity_hub_of.get(smart_account),
        };
        if sources.state_view == Address::ZERO
            || sources.vts_orchestrator == Address::ZERO
            || sources.liquidity_hub == Address::ZERO
        {
            return SIG_VALIDATION_FAILED_UINT;
        }

        let facts = OnchainFactsProvider::new(sources, 200_000);
        let ok = evaluate_program(&checks, &facts, |token| {
            self.token_allowed.get(smart_account).get(token)
        });
        if ok.is_err() {
            return SIG_VALIDATION_FAILED_UINT;
        }

        // All checks passed; consume nonce.
        self.nonce_of.insert(
            smart_account,
            expected_nonce.saturating_add(U256::from(1u64)),
        );

        SIG_VALIDATION_SUCCESS_UINT
    }

    /// Kernel `IValidator.isValidSignatureWithSender` (ERC-1271).
    pub fn is_valid_signature_with_sender(
        &self,
        sender: Address,
        hash: FixedBytes<32>,
        data: Vec<u8>,
    ) -> FixedBytes<4> {
        let smart_account = self.vm().msg_sender();
        if !self._is_initialized(smart_account) {
            return ERC1271_INVALID;
        }
        // Enforce the sender matches the Kernel account invoking this validator.
        if sender != smart_account {
            return ERC1271_INVALID;
        }

        let env = match parse_intent_envelope(&data) {
            Ok(e) => e,
            Err(_) => return ERC1271_INVALID,
        };
        if env.version != 1u16 {
            return ERC1271_INVALID;
        }
        if self.vm().block_timestamp() > env.deadline {
            return ERC1271_INVALID;
        }
        let expected_nonce = self.nonce_of.get(smart_account);
        if env.nonce != expected_nonce {
            return ERC1271_INVALID;
        }

        let digest = intent_digest(
            self.vm().chain_id(),
            self.vm().contract_address(),
            smart_account,
            env.nonce,
            env.deadline,
            env.call_bundle_hash,
            &env.program_bytes,
        );

        // Optional binding: require caller-supplied `hash` to match the computed digest.
        if hash != digest {
            return ERC1271_INVALID;
        }

        let recovered = match ecrecover_address(digest, &env.signature) {
            Ok(a) => a,
            Err(_) => return ERC1271_INVALID,
        };
        if recovered != self.signer_of.get(smart_account) {
            return ERC1271_INVALID;
        }

        ERC1271_MAGICVALUE
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

// TODO: Move these to independent utils

/// Parsed intent envelope (v1).
struct ParsedIntent {
    version: u16,
    nonce: U256,
    deadline: u64,
    call_bundle_hash: FixedBytes<32>,
    program_bytes: Vec<u8>,
    signature: [u8; 65],
}

/// Parse `userOp.signature` bytes into an intent envelope.
///
/// Layout (big-endian for integer fields):
/// - u16 version
/// - bytes32 nonce (u256)
/// - u64 deadline
/// - bytes32 call_bundle_hash
/// - u32 program_len
/// - bytes program_bytes
/// - u16 sig_len (must be 65)
/// - bytes signature (r||s||v)
fn parse_intent_envelope(sig: &[u8]) -> Result<ParsedIntent, ()> {
    let mut i = 0usize;
    if sig.len() < 2 + 32 + 8 + 32 + 4 + 2 {
        return Err(());
    }

    let version = read_u16(sig, &mut i)?;
    let nonce = read_u256(sig, &mut i)?;
    let deadline = read_u64(sig, &mut i)?;
    let call_bundle_hash = read_b32(sig, &mut i)?;
    let program_len = read_u32(sig, &mut i)? as usize;
    let program_bytes = read_vec(sig, &mut i, program_len)?;
    let sig_len = read_u16(sig, &mut i)? as usize;
    if sig_len != 65 {
        return Err(());
    }
    let sig_bytes = read_vec(sig, &mut i, sig_len)?;
    if i != sig.len() {
        // reject trailing bytes for determinism
        return Err(());
    }
    let mut signature = [0u8; 65];
    signature.copy_from_slice(&sig_bytes);

    Ok(ParsedIntent {
        version,
        nonce,
        deadline,
        call_bundle_hash,
        program_bytes,
        signature,
    })
}

fn intent_digest(
    chain_id: u64,
    validator: Address,
    smart_account: Address,
    nonce: U256,
    deadline: u64,
    call_bundle_hash: FixedBytes<32>,
    program_bytes: &[u8],
) -> FixedBytes<32> {
    // Minimal deterministic domain separation for v1 (not full EIP-712 yet):
    // keccak256("FIET_INTENT_V1" || chainId || validator || smartAccount || nonce || deadline || callBundleHash || keccak(program))
    let program_hash: FixedBytes<32> = keccak256(program_bytes);
    let mut buf = Vec::with_capacity(12 + 8 + 20 + 20 + 32 + 8 + 32 + 32);
    buf.extend_from_slice(b"FIET_INTENT_V1");
    buf.extend_from_slice(&chain_id.to_be_bytes());
    buf.extend_from_slice(validator.as_slice());
    buf.extend_from_slice(smart_account.as_slice());
    buf.extend_from_slice(&nonce.to_be_bytes::<32>());
    buf.extend_from_slice(&deadline.to_be_bytes());
    buf.extend_from_slice(call_bundle_hash.as_slice());
    buf.extend_from_slice(program_hash.as_slice());
    keccak256(buf)
}

fn ecrecover_address(msg_hash: FixedBytes<32>, sig: &[u8; 65]) -> Result<Address, ()> {
    // EVM ecrecover precompile at address 0x01.
    let mut precompile = [0u8; 20];
    precompile[19] = 1;
    let to = Address::from_slice(&precompile);

    let r = &sig[0..32];
    let s = &sig[32..64];
    let mut v = sig[64];
    if v == 0 || v == 1 {
        v += 27;
    }
    if v != 27 && v != 28 {
        return Err(());
    }

    let mut input = [0u8; 128];
    input[0..32].copy_from_slice(msg_hash.as_slice());
    // v as 32-byte big-endian
    input[63] = v;
    input[64..96].copy_from_slice(r);
    input[96..128].copy_from_slice(s);

    let out = unsafe { RawCall::new_static().gas(50_000).call(to, &input) }.map_err(|_| ())?;
    if out.len() < 32 {
        return Err(());
    }
    // precompile returns 32-byte word with address in the low 20 bytes.
    Ok(Address::from_slice(&out[12..32]))
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
