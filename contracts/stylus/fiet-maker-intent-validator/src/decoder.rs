use alloc::vec::Vec;
use stylus_sdk::alloy_primitives::{Address, FixedBytes, U256};

use crate::{
    errors::DecodeError,
    types::opcodes::{Check, CompOp, Opcode},
};

const MAX_CHECKS_DEFAULT: usize = 64;

/// Decode program bytes into bounded checks.
pub fn decode_program(bytes: &[u8]) -> Result<Vec<Check>, DecodeError> {
    decode_program_with_limit(bytes, MAX_CHECKS_DEFAULT)
}

pub fn decode_program_with_limit(bytes: &[u8], max_checks: usize) -> Result<Vec<Check>, DecodeError> {
    let mut checks = Vec::new();
    let mut i = 0usize;

    while i < bytes.len() {
        if checks.len() >= max_checks {
            return Err(DecodeError::TooManyChecks);
        }
        let opcode = Opcode::try_from(bytes[i]).map_err(|_| DecodeError::UnknownOpcode(bytes[i]))?;
        i += 1;

        let check = match opcode {
            Opcode::CheckDeadline => {
                let deadline = read_u64(bytes, &mut i)?;
                Check::Deadline { deadline }
            },
            Opcode::CheckNonce => {
                let nonce = read_u256(bytes, &mut i)?;
                Check::Nonce { expected: nonce }
            },
            Opcode::CheckCallBundleHash => {
                let hash = read_b32(bytes, &mut i)?;
                Check::CallBundleHash { hash }
            },
            Opcode::CheckTokenAmountLte => {
                let token = read_address(bytes, &mut i)?;
                let max = read_u256(bytes, &mut i)?;
                Check::TokenAmountLte { token, max }
            },
            Opcode::CheckNativeValueLte => {
                let max = read_u256(bytes, &mut i)?;
                Check::NativeValueLte { max }
            },
            Opcode::CheckLiquidityDeltaLte => {
                let max = read_u128(bytes, &mut i)?;
                Check::LiquidityDeltaLte { max }
            },
            Opcode::CheckSlot0TickBounds => {
                let pool_id = read_b32(bytes, &mut i)?;
                let min = read_i32(bytes, &mut i)?;
                let max = read_i32(bytes, &mut i)?;
                Check::Slot0TickBounds { pool_id, min, max }
            },
            Opcode::CheckSlot0SqrtPriceBounds => {
                let pool_id = read_b32(bytes, &mut i)?;
                let min = read_u256(bytes, &mut i)?;
                let max = read_u256(bytes, &mut i)?;
                Check::Slot0SqrtPriceBounds { pool_id, min, max }
            },
            Opcode::CheckRfsClosed => {
                let position_id = read_b32(bytes, &mut i)?;
                Check::RfsClosed { position_id }
            },
            Opcode::CheckQueueLte => {
                let lcc = read_address(bytes, &mut i)?;
                let owner = read_address(bytes, &mut i)?;
                let max = read_u256(bytes, &mut i)?;
                Check::QueueLte { lcc, owner, max }
            },
            Opcode::CheckReserveGte => {
                let lcc = read_address(bytes, &mut i)?;
                let min = read_u256(bytes, &mut i)?;
                Check::ReserveGte { lcc, min }
            },
            Opcode::CheckSettledGte => {
                let position_id = read_b32(bytes, &mut i)?;
                let min_amount0 = read_u256(bytes, &mut i)?;
                let min_amount1 = read_u256(bytes, &mut i)?;
                Check::SettledGte { position_id, min_amount0, min_amount1 }
            },
            Opcode::CheckCommitmentDeficitLte => {
                let position_id = read_b32(bytes, &mut i)?;
                let max_deficit0 = read_u256(bytes, &mut i)?;
                let max_deficit1 = read_u256(bytes, &mut i)?;
                Check::CommitmentDeficitLte { position_id, max_deficit0, max_deficit1 }
            },
            Opcode::CheckGracePeriodGte => {
                let position_id = read_b32(bytes, &mut i)?;
                let min_seconds = read_u64(bytes, &mut i)?;
                Check::GracePeriodGte { position_id, min_seconds }
            },
            Opcode::CheckStaticCallU256 => {
                let target = read_address(bytes, &mut i)?;
                let selector = read_selector(bytes, &mut i)?;
                let args_len = read_u16(bytes, &mut i)? as usize;
                let args = read_vec(bytes, &mut i, args_len)?;
                let op = read_comp_op(bytes, &mut i)?;
                let rhs = read_u256(bytes, &mut i)?;
                Check::StaticCallU256 { target, selector, args, op, rhs }
            },
        };

        checks.push(check);
    }

    Ok(checks)
}

fn read_vec(bytes: &[u8], i: &mut usize, len: usize) -> Result<Vec<u8>, DecodeError> {
    if bytes.len() < *i + len {
        return Err(DecodeError::Truncated);
    }
    let out = bytes[*i..*i + len].to_vec();
    *i += len;
    Ok(out)
}

fn read_u16(bytes: &[u8], i: &mut usize) -> Result<u16, DecodeError> {
    if bytes.len() < *i + 2 {
        return Err(DecodeError::Truncated);
    }
    let mut buf = [0u8; 2];
    buf.copy_from_slice(&bytes[*i..*i + 2]);
    *i += 2;
    Ok(u16::from_be_bytes(buf))
}

fn read_u64(bytes: &[u8], i: &mut usize) -> Result<u64, DecodeError> {
    if bytes.len() < *i + 8 {
        return Err(DecodeError::Truncated);
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&bytes[*i..*i + 8]);
    *i += 8;
    Ok(u64::from_be_bytes(buf))
}

fn read_i32(bytes: &[u8], i: &mut usize) -> Result<i32, DecodeError> {
    if bytes.len() < *i + 4 {
        return Err(DecodeError::Truncated);
    }
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&bytes[*i..*i + 4]);
    *i += 4;
    Ok(i32::from_be_bytes(buf))
}

fn read_u128(bytes: &[u8], i: &mut usize) -> Result<u128, DecodeError> {
    if bytes.len() < *i + 16 {
        return Err(DecodeError::Truncated);
    }
    let mut buf = [0u8; 16];
    buf.copy_from_slice(&bytes[*i..*i + 16]);
    *i += 16;
    Ok(u128::from_be_bytes(buf))
}

fn read_u256(bytes: &[u8], i: &mut usize) -> Result<U256, DecodeError> {
    if bytes.len() < *i + 32 {
        return Err(DecodeError::Truncated);
    }
    let word = &bytes[*i..*i + 32];
    *i += 32;
    Ok(U256::from_be_slice(word))
}

fn read_b32(bytes: &[u8], i: &mut usize) -> Result<FixedBytes<32>, DecodeError> {
    if bytes.len() < *i + 32 {
        return Err(DecodeError::Truncated);
    }
    let mut buf = [0u8; 32];
    buf.copy_from_slice(&bytes[*i..*i + 32]);
    *i += 32;
    Ok(FixedBytes(buf))
}

fn read_address(bytes: &[u8], i: &mut usize) -> Result<Address, DecodeError> {
    if bytes.len() < *i + 20 {
        return Err(DecodeError::Truncated);
    }
    let addr = Address::from_slice(&bytes[*i..*i + 20]);
    *i += 20;
    Ok(addr)
}

fn read_selector(bytes: &[u8], i: &mut usize) -> Result<[u8; 4], DecodeError> {
    if bytes.len() < *i + 4 {
        return Err(DecodeError::Truncated);
    }
    let mut sel = [0u8; 4];
    sel.copy_from_slice(&bytes[*i..*i + 4]);
    *i += 4;
    Ok(sel)
}

fn read_comp_op(bytes: &[u8], i: &mut usize) -> Result<CompOp, DecodeError> {
    if bytes.len() <= *i {
        return Err(DecodeError::Truncated);
    }
    let b = bytes[*i];
    *i += 1;
    let op = match b {
        0 => CompOp::Lt,
        1 => CompOp::Lte,
        2 => CompOp::Gt,
        3 => CompOp::Gte,
        4 => CompOp::Eq,
        5 => CompOp::Neq,
        _ => return Err(DecodeError::UnknownOpcode(b)),
    };
    Ok(op)
}

