//! Policy-local envelope parsing and EIP-712 digest computation.
//!
//! The policy receives its payload in `userOp.signature` **as sliced by Kernel's permission pipeline**.
//! This payload must be authenticated (signed) to prevent tampering.

use alloc::vec::Vec;

use stylus_sdk::alloy_primitives::{keccak256, Address, FixedBytes, U256};

use crate::utils::bytes::{read_b32, read_u16_be, read_u32_be, read_u64_be, read_u256_be, read_vec};

/// Parsed policy envelope (v1).
pub struct ParsedPolicyIntent {
    pub version: u16,
    pub nonce: U256,
    pub deadline: u64,
    pub call_bundle_hash: FixedBytes<32>,
    pub program_bytes: Vec<u8>,
    pub signature: [u8; 65],
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
/// - u16 sig_len (must be 65)
/// - bytes signature (r||s||v)
pub fn parse_policy_envelope(sig: &[u8]) -> Result<ParsedPolicyIntent, ()> {
    let mut i = 0usize;
    if sig.len() < 2 + 32 + 8 + 32 + 4 + 2 {
        return Err(());
    }

    let version = read_u16_be(sig, &mut i)?;
    let nonce = read_u256_be(sig, &mut i)?;
    let deadline = read_u64_be(sig, &mut i)?;
    let call_bundle_hash = read_b32(sig, &mut i)?;
    let program_len = read_u32_be(sig, &mut i)? as usize;
    let program_bytes = read_vec(sig, &mut i, program_len)?;
    let sig_len = read_u16_be(sig, &mut i)? as usize;
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

    Ok(ParsedPolicyIntent {
        version,
        nonce,
        deadline,
        call_bundle_hash,
        program_bytes,
        signature,
    })
}

/// Compute the EIP-712 digest that must be signed by the configured policy signer.
///
/// Purpose: authenticate the policy envelope payload (nonce/deadline/bundle binding/program hash)
/// so it cannot be replaced inside the permission pipeline.
pub fn policy_intent_digest(
    chain_id: u64,
    verifying_contract: Address,
    wallet: Address,
    permission_id: FixedBytes<32>,
    nonce: U256,
    deadline: u64,
    call_bundle_hash: FixedBytes<32>,
    program_bytes: &[u8],
) -> FixedBytes<32> {
    // Hash the program bytes so the typed message stays fixed-size and unambiguous.
    let program_hash: FixedBytes<32> = keccak256(program_bytes);

    // Domain type hash: keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    let domain_type_hash = keccak256(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );
    let domain_name_hash = keccak256(b"Fiet Maker Intent Policy");
    let domain_version_hash = keccak256(b"1");

    // Domain separator encoding
    let mut domain_buf = Vec::with_capacity(32 * 5);
    domain_buf.extend_from_slice(domain_type_hash.as_slice());
    domain_buf.extend_from_slice(domain_name_hash.as_slice());
    domain_buf.extend_from_slice(domain_version_hash.as_slice());
    domain_buf.extend_from_slice(&U256::from(chain_id).to_be_bytes::<32>());
    let mut vc_padded = [0u8; 32];
    vc_padded[12..32].copy_from_slice(verifying_contract.as_slice());
    domain_buf.extend_from_slice(&vc_padded);
    let domain_separator = keccak256(domain_buf);

    // Message type hash:
    // keccak256("IntentPolicyEnvelope(address wallet,bytes32 permissionId,uint256 nonce,uint64 deadline,bytes32 callBundleHash,bytes32 programHash)")
    let msg_type_hash = keccak256(
        b"IntentPolicyEnvelope(address wallet,bytes32 permissionId,uint256 nonce,uint64 deadline,bytes32 callBundleHash,bytes32 programHash)",
    );

    // Struct hash
    let mut struct_buf = Vec::with_capacity(32 * 7);
    struct_buf.extend_from_slice(msg_type_hash.as_slice());
    let mut wallet_padded = [0u8; 32];
    wallet_padded[12..32].copy_from_slice(wallet.as_slice());
    struct_buf.extend_from_slice(&wallet_padded);
    struct_buf.extend_from_slice(permission_id.as_slice());
    struct_buf.extend_from_slice(&nonce.to_be_bytes::<32>());
    let mut deadline_padded = [0u8; 32];
    deadline_padded[24..32].copy_from_slice(&deadline.to_be_bytes());
    struct_buf.extend_from_slice(&deadline_padded);
    struct_buf.extend_from_slice(call_bundle_hash.as_slice());
    struct_buf.extend_from_slice(program_hash.as_slice());
    let struct_hash = keccak256(struct_buf);

    // Final digest: keccak256("\x19\x01" || domainSeparator || structHash)
    let mut final_buf = Vec::with_capacity(2 + 32 + 32);
    final_buf.extend_from_slice(b"\x19\x01");
    final_buf.extend_from_slice(domain_separator.as_slice());
    final_buf.extend_from_slice(struct_hash.as_slice());
    keccak256(final_buf)
}

