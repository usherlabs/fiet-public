//! Minimal big-endian parsing helpers.
//!
//! These helpers are used for parsing the policy install data and policy-local envelope bytes.

use alloc::vec::Vec;

use stylus_sdk::alloy_primitives::{FixedBytes, U256};

pub fn read_vec(bytes: &[u8], i: &mut usize, len: usize) -> Result<Vec<u8>, ()> {
    if bytes.len() < *i + len {
        return Err(());
    }
    let out = bytes[*i..*i + len].to_vec();
    *i += len;
    Ok(out)
}

pub fn read_u16_be(bytes: &[u8], i: &mut usize) -> Result<u16, ()> {
    if bytes.len() < *i + 2 {
        return Err(());
    }
    let mut buf = [0u8; 2];
    buf.copy_from_slice(&bytes[*i..*i + 2]);
    *i += 2;
    Ok(u16::from_be_bytes(buf))
}

pub fn read_u32_be(bytes: &[u8], i: &mut usize) -> Result<u32, ()> {
    if bytes.len() < *i + 4 {
        return Err(());
    }
    let mut buf = [0u8; 4];
    buf.copy_from_slice(&bytes[*i..*i + 4]);
    *i += 4;
    Ok(u32::from_be_bytes(buf))
}

pub fn read_u64_be(bytes: &[u8], i: &mut usize) -> Result<u64, ()> {
    if bytes.len() < *i + 8 {
        return Err(());
    }
    let mut buf = [0u8; 8];
    buf.copy_from_slice(&bytes[*i..*i + 8]);
    *i += 8;
    Ok(u64::from_be_bytes(buf))
}

pub fn read_u256_be(bytes: &[u8], i: &mut usize) -> Result<U256, ()> {
    if bytes.len() < *i + 32 {
        return Err(());
    }
    let out = U256::from_be_slice(&bytes[*i..*i + 32]);
    *i += 32;
    Ok(out)
}

pub fn read_b32(bytes: &[u8], i: &mut usize) -> Result<FixedBytes<32>, ()> {
    if bytes.len() < *i + 32 {
        return Err(());
    }
    let mut buf = [0u8; 32];
    buf.copy_from_slice(&bytes[*i..*i + 32]);
    *i += 32;
    Ok(FixedBytes(buf))
}

