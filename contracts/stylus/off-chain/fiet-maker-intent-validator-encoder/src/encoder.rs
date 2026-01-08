use alloy_primitives::{Address, FixedBytes, U256};
use k256::ecdsa::{SigningKey, signature::Signer};
use sha3::{Digest, Keccak256};

use crate::opcodes::{Check, CompOp, Opcode};
use crate::types::IntentEnvelope;

/// Encode a check program from a list of checks.
pub fn encode_program(checks: &[Check]) -> Vec<u8> {
    let mut buf = Vec::new();
    for check in checks {
        match check {
            Check::Deadline { deadline } => {
                buf.push(Opcode::CheckDeadline as u8);
                buf.extend_from_slice(&deadline.to_be_bytes());
            }
            Check::Nonce { expected } => {
                buf.push(Opcode::CheckNonce as u8);
                buf.extend_from_slice(&expected.to_be_bytes::<32>());
            }
            Check::CallBundleHash { hash } => {
                buf.push(Opcode::CheckCallBundleHash as u8);
                buf.extend_from_slice(hash.as_slice());
            }
            Check::TokenAmountLte { token, max } => {
                buf.push(Opcode::CheckTokenAmountLte as u8);
                buf.extend_from_slice(token.as_slice());
                buf.extend_from_slice(&max.to_be_bytes::<32>());
            }
            Check::NativeValueLte { max } => {
                buf.push(Opcode::CheckNativeValueLte as u8);
                buf.extend_from_slice(&max.to_be_bytes::<32>());
            }
            Check::LiquidityDeltaLte { max } => {
                buf.push(Opcode::CheckLiquidityDeltaLte as u8);
                buf.extend_from_slice(&max.to_be_bytes());
            }
            Check::Slot0TickBounds { pool_id, min, max } => {
                buf.push(Opcode::CheckSlot0TickBounds as u8);
                buf.extend_from_slice(pool_id.as_slice());
                buf.extend_from_slice(&min.to_be_bytes());
                buf.extend_from_slice(&max.to_be_bytes());
            }
            Check::Slot0SqrtPriceBounds { pool_id, min, max } => {
                buf.push(Opcode::CheckSlot0SqrtPriceBounds as u8);
                buf.extend_from_slice(pool_id.as_slice());
                buf.extend_from_slice(&min.to_be_bytes::<32>());
                buf.extend_from_slice(&max.to_be_bytes::<32>());
            }
            Check::RfsClosed { position_id } => {
                buf.push(Opcode::CheckRfsClosed as u8);
                buf.extend_from_slice(position_id.as_slice());
            }
            Check::QueueLte { lcc, owner, max } => {
                buf.push(Opcode::CheckQueueLte as u8);
                buf.extend_from_slice(lcc.as_slice());
                buf.extend_from_slice(owner.as_slice());
                buf.extend_from_slice(&max.to_be_bytes::<32>());
            }
            Check::ReserveGte { lcc, min } => {
                buf.push(Opcode::CheckReserveGte as u8);
                buf.extend_from_slice(lcc.as_slice());
                buf.extend_from_slice(&min.to_be_bytes::<32>());
            }
            Check::SettledGte { position_id, min_amount0, min_amount1 } => {
                buf.push(Opcode::CheckSettledGte as u8);
                buf.extend_from_slice(position_id.as_slice());
                buf.extend_from_slice(&min_amount0.to_be_bytes::<32>());
                buf.extend_from_slice(&min_amount1.to_be_bytes::<32>());
            }
            Check::CommitmentDeficitLte { position_id, max_deficit0, max_deficit1 } => {
                buf.push(Opcode::CheckCommitmentDeficitLte as u8);
                buf.extend_from_slice(position_id.as_slice());
                buf.extend_from_slice(&max_deficit0.to_be_bytes::<32>());
                buf.extend_from_slice(&max_deficit1.to_be_bytes::<32>());
            }
            Check::GracePeriodGte { position_id, min_seconds } => {
                buf.push(Opcode::CheckGracePeriodGte as u8);
                buf.extend_from_slice(position_id.as_slice());
                buf.extend_from_slice(&min_seconds.to_be_bytes());
            }
            Check::StaticCallU256 { target, selector, args, op, rhs } => {
                buf.push(Opcode::CheckStaticCallU256 as u8);
                buf.extend_from_slice(target.as_slice());
                buf.extend_from_slice(selector);
                buf.extend_from_slice(&(args.len() as u16).to_be_bytes());
                buf.extend_from_slice(args);
                buf.push(comp_op_to_u8(*op));
                buf.extend_from_slice(&rhs.to_be_bytes::<32>());
            }
        }
    }
    buf
}

fn comp_op_to_u8(op: CompOp) -> u8 {
    match op {
        CompOp::Lt => 0,
        CompOp::Lte => 1,
        CompOp::Gt => 2,
        CompOp::Gte => 3,
        CompOp::Eq => 4,
        CompOp::Neq => 5,
    }
}

fn keccak256_bytes(bytes: &[u8]) -> FixedBytes<32> {
    let mut h = Keccak256::new();
    h.update(bytes);
    let out = h.finalize();
    let mut b = [0u8; 32];
    b.copy_from_slice(out.as_slice());
    FixedBytes(b)
}

/// Compute EIP-712 intent digest for signing.
pub fn intent_digest(
    chain_id: u64,
    validator: Address,
    smart_account: Address,
    nonce: U256,
    deadline: u64,
    call_bundle_hash: FixedBytes<32>,
    program_bytes: &[u8],
) -> FixedBytes<32> {
    // EIP-712: keccak256("\x19\x01" || domainSeparator || hashStruct(message))
    let program_hash: FixedBytes<32> = keccak256_bytes(program_bytes);

    // Domain type hash: keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)")
    let domain_type_hash = keccak256_bytes(
        b"EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)",
    );

    // Domain name and version hashes
    let domain_name_hash = keccak256_bytes(b"Fiet Intent Validator");
    let domain_version_hash = keccak256_bytes(b"1");

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

    let domain_separator = keccak256_bytes(&domain_buf);

    // IntentEnvelope type hash:
    // keccak256("IntentEnvelope(address smartAccount,uint256 nonce,uint64 deadline,bytes32 callBundleHash,bytes32 programHash)")
    let intent_type_hash = keccak256_bytes(
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
    let struct_hash = keccak256_bytes(&struct_buf);

    // Final EIP-712 digest: keccak256("\x19\x01" || domainSeparator || structHash)
    let mut final_buf = Vec::with_capacity(2 + 32 + 32);
    final_buf.extend_from_slice(b"\x19\x01");
    final_buf.extend_from_slice(domain_separator.as_slice());
    final_buf.extend_from_slice(struct_hash.as_slice());
    keccak256_bytes(&final_buf)
}

/// Sign an intent envelope using EIP-712.
/// 
/// Note: smart_account is required for domain separation in the digest.
pub fn sign_envelope(
    envelope: &IntentEnvelope,
    signing_key: &SigningKey,
    smart_account: Address,
) -> Result<Vec<u8>, k256::ecdsa::Error> {
    let digest = intent_digest(
        envelope.domain_chain_id,
        envelope.domain_verifying_contract,
        smart_account,
        envelope.nonce,
        envelope.deadline,
        envelope.call_bundle_hash,
        &envelope.program_bytes,
    );

    // Sign the digest
    let signature: k256::ecdsa::Signature = signing_key.sign(&digest.as_slice());
    let (r, s) = signature.split_bytes();
    
    // Convert to 65-byte format: r (32) || s (32) || v (1)
    let mut sig_bytes = Vec::with_capacity(65);
    sig_bytes.extend_from_slice(r.as_slice());
    sig_bytes.extend_from_slice(s.as_slice());
    
    // For EIP-712, v is typically 27 or 28
    // We'll use 27 as default; the on-chain validator will try both if needed
    sig_bytes.push(27);
    
    Ok(sig_bytes)
}

/// Encode an intent envelope into bytes for use in userOp.signature.
pub fn encode_envelope(envelope: &IntentEnvelope) -> Vec<u8> {
    let mut buf = Vec::new();
    
    // u16 version
    buf.extend_from_slice(&envelope.version.to_be_bytes());
    
    // bytes32 nonce (u256)
    buf.extend_from_slice(&envelope.nonce.to_be_bytes::<32>());
    
    // u64 deadline
    buf.extend_from_slice(&envelope.deadline.to_be_bytes());
    
    // bytes32 call_bundle_hash
    buf.extend_from_slice(envelope.call_bundle_hash.as_slice());
    
    // u32 program_len
    buf.extend_from_slice(&(envelope.program_bytes.len() as u32).to_be_bytes());
    
    // bytes program_bytes
    buf.extend_from_slice(&envelope.program_bytes);
    
    // u16 sig_len (must be 65)
    buf.extend_from_slice(&65u16.to_be_bytes());
    
    // bytes signature (r||s||v)
    buf.extend_from_slice(&envelope.signature);
    
    buf
}

