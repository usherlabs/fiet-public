use alloy_primitives::{FixedBytes, U256};

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

/// Encode a policy intent envelope into bytes for use in the policy signature slice
/// (Kernel PermissionValidator will place this into `userOp.signature` when calling the policy).
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

    buf
}

