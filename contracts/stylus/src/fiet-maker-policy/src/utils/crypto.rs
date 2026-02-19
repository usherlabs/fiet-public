//! Cryptographic helpers used by the policy.
//!
//! Purpose: verify that the policy payload (envelope) is authorised by a configured signer.
//! This prevents tampering with the policy-local signature slice in Kernel's permission pipeline.

use alloc::vec::Vec;

use stylus_sdk::{
    alloy_primitives::{Address, FixedBytes},
    call::RawCall,
};

/// Recover an EOA address from a 32-byte digest and an ECDSA signature.
///
/// Notes:
/// - We use the EVM `ecrecover` precompile at address `0x01`.
/// - We accept signatures with v in {0,1,27,28}. If v is not recognised, we try both 27 and 28.
pub fn ecrecover_address(digest: FixedBytes<32>, sig: &[u8; 65]) -> Result<Address, ()> {
    // Precompile address 0x01.
    let mut precompile = [0u8; 20];
    precompile[19] = 1;
    let to = Address::from_slice(&precompile);

    let r = &sig[0..32];
    let s = &sig[32..64];
    let v_raw = sig[64];

    let mut candidates: Vec<u8> = Vec::new();
    match v_raw {
        27 | 28 => candidates.extend_from_slice(&[v_raw]),
        0 | 1 => candidates.extend_from_slice(&[v_raw + 27]),
        _ => {}
    }
    // If v isn't provided/usable, try both.
    if candidates.is_empty() {
        candidates.extend_from_slice(&[27u8, 28u8]);
    }

    for v in candidates {
        let mut input = [0u8; 128];
        input[0..32].copy_from_slice(digest.as_slice());
        // v as 32-byte big-endian word.
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

