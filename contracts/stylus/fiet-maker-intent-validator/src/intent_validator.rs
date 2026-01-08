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
    ERC1271_INVALID, ERC1271_MAGICVALUE, MODULE_TYPE_VALIDATOR, SIG_VALIDATION_FAILED_UINT,
    SIG_VALIDATION_SUCCESS_UINT,
};

use crate::{
    decoder::decode_program,
    evaluator::evaluate_program,
    facts::onchain::{FactSources, OnchainFactsProvider},
};

use crate::kernel::types::PackedUserOperation;

use alloy_sol_types::SolType;
use stylus_sdk::stylus_proc::SolidityError;

use alloy_sol_types::sol;

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
    }
}

#[public]
impl IntentValidator {
    /// Kernel module install hook.
    ///
    /// Expected `_data` layout:
    /// - `uint8 version = 1`
    /// - `bytes20 signer`
    /// - `bytes20 stateView`
    /// - `bytes20 vtsOrchestrator`
    /// - `bytes20 liquidityHub`
    ///
    #[payable]
    pub fn on_install(&mut self, data: Vec<u8>) -> Result<(), ModuleError> {
        let smart_account = self.vm().msg_sender();
        if self._is_initialized(smart_account) {
            return Err(ModuleError::AlreadyInitialized(AlreadyInitialized {
                smartAccount: smart_account,
            }));
        }

        if data.len() < 1 + 20 + 20 + 20 + 20 {
            panic!("Invalid init data");
        }
        let version = data[0];
        if version != 1 {
            panic!("Unsupported init version");
        }
        let signer = Address::from_slice(&data[1..21]);
        let state_view = Address::from_slice(&data[21..41]);
        let vts_orchestrator = Address::from_slice(&data[41..61]);
        let liquidity_hub = Address::from_slice(&data[61..81]);

        if signer == Address::ZERO {
            panic!("Invalid signer");
        }
        if state_view == Address::ZERO
            || vts_orchestrator == Address::ZERO
            || liquidity_hub == Address::ZERO
        {
            panic!("Invalid fact sources");
        }
        if data.len() != 81 {
            panic!("Invalid init data length");
        }

        self.signer_of.insert(smart_account, signer);
        self.nonce_of.insert(smart_account, U256::ZERO);
        self.state_view_of.insert(smart_account, state_view);
        self.vts_orchestrator_of
            .insert(smart_account, vts_orchestrator);
        self.liquidity_hub_of.insert(smart_account, liquidity_hub);
        Ok(())
    }

    /// Kernel module uninstall hook.
    #[payable]
    pub fn on_uninstall(&mut self, _data: Vec<u8>) -> Result<(), ModuleError> {
        let smart_account = self.vm().msg_sender();
        if !self._is_initialized(smart_account) {
            return Err(ModuleError::NotInitialized(NotInitialized {
                smartAccount: smart_account,
            }));
        }
        self.signer_of.insert(smart_account, Address::ZERO);
        self.nonce_of.insert(smart_account, U256::ZERO);
        self.state_view_of.insert(smart_account, Address::ZERO);
        self.vts_orchestrator_of
            .insert(smart_account, Address::ZERO);
        self.liquidity_hub_of.insert(smart_account, Address::ZERO);
        Ok(())
    }

    /// ERC-7579 module-type detection.
    pub fn is_module_type(&self, module_type_id: U256) -> bool {
        module_type_id == MODULE_TYPE_VALIDATOR
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

        let facts = OnchainFactsProvider::new(sources, 200_000, self.vm().block_timestamp());
        let ok = evaluate_program(&checks, &facts);
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
        _sender: Address,
        hash: FixedBytes<32>,
        data: Vec<u8>,
    ) -> FixedBytes<4> {
        let smart_account = self.vm().msg_sender();
        if !self._is_initialized(smart_account) {
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
    // EIP-712: keccak256("\x19\x01" || domainSeparator || hashStruct(message))
    let program_hash: FixedBytes<32> = keccak256(program_bytes);

    // Domain type hash: keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );

    // Domain name and version hashes
    let domain_name_hash = keccak256(b"Fiet Intent Validator");
    let domain_version_hash = keccak256(b"1");

    // Domain separator struct encoding
    let mut domain_buf = Vec::with_capacity(32 * 5);
    domain_buf.extend_from_slice(domain_type_hash.as_slice());
    domain_buf.extend_from_slice(domain_name_hash.as_slice());
    domain_buf.extend_from_slice(domain_version_hash.as_slice());
    domain_buf.extend_from_slice(&U256::from(chain_id).to_be_bytes::<32>());
    // Address padded to 32 bytes (left-padded)
    let mut validator_padded = [0u8; 32];
    validator_padded[12..32].copy_from_slice(validator.as_slice());
    domain_buf.extend_from_slice(&validator_padded);

    let domain_separator = keccak256(domain_buf);

    // IntentEnvelope type hash:
    // keccak256("IntentEnvelope(address smartAccount,uint256 nonce,uint64 deadline,bytes32 callBundleHash,bytes32 programHash)")
    let intent_type_hash = keccak256(
        b"IntentEnvelope(address smartAccount,uint256 nonce,uint64 deadline,bytes32 callBundleHash,bytes32 programHash)",
    );

    // IntentEnvelope struct hash
    let mut struct_buf = Vec::with_capacity(32 * 6);
    struct_buf.extend_from_slice(intent_type_hash.as_slice());
    // smartAccount as address, padded to 32 bytes (left-padded)
    let mut smart_account_padded = [0u8; 32];
    smart_account_padded[12..32].copy_from_slice(smart_account.as_slice());
    struct_buf.extend_from_slice(&smart_account_padded);
    struct_buf.extend_from_slice(&nonce.to_be_bytes::<32>());
    // deadline as uint64, padded to 32 bytes (left-padded)
    let mut deadline_padded = [0u8; 32];
    deadline_padded[24..32].copy_from_slice(&deadline.to_be_bytes());
    struct_buf.extend_from_slice(&deadline_padded);
    struct_buf.extend_from_slice(call_bundle_hash.as_slice());
    struct_buf.extend_from_slice(program_hash.as_slice());
    let struct_hash = keccak256(struct_buf);

    // Final EIP-712 digest: keccak256("\x19\x01" || domainSeparator || structHash)
    let mut final_buf = Vec::with_capacity(2 + 32 + 32);
    final_buf.extend_from_slice(b"\x19\x01");
    final_buf.extend_from_slice(domain_separator.as_slice());
    final_buf.extend_from_slice(struct_hash.as_slice());
    keccak256(final_buf)
}

fn ecrecover_address(msg_hash: FixedBytes<32>, sig: &[u8; 65]) -> Result<Address, ()> {
    // EVM ecrecover precompile at address 0x01.
    let mut precompile = [0u8; 20];
    precompile[19] = 1;
    let to = Address::from_slice(&precompile);

    let r = &sig[0..32];
    let s = &sig[32..64];

    // Try both recovery IDs (v=27 and v=28). This avoids requiring the off-chain
    // encoder to compute the exact recovery ID.
    for v in [27u8, 28u8] {
        let mut input = [0u8; 128];
        input[0..32].copy_from_slice(msg_hash.as_slice());
        // v as 32-byte big-endian
        input[63] = v;
        input[64..96].copy_from_slice(r);
        input[96..128].copy_from_slice(s);

        let out = unsafe { RawCall::new_static().gas(50_000).call(to, &input) }.map_err(|_| ())?;
        if out.len() < 32 {
            continue;
        }
        // precompile returns 32-byte word with address in the low 20 bytes.
        let recovered = Address::from_slice(&out[12..32]);
        if recovered != Address::ZERO {
            return Ok(recovered);
        }
    }

    Err(())
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
