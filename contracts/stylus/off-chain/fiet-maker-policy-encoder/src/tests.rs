#[cfg(test)]
mod tests {
    use crate::encoder::{encode_envelope, encode_program};
    use crate::opcodes::Check;
    use crate::types::IntentEnvelope;
    use alloy_primitives::{Address, FixedBytes, U256};

    #[test]
    fn test_encode_program() {
        let checks = vec![
            Check::Deadline { deadline: 1234567890 },
            Check::RfsClosed { position_id: FixedBytes::ZERO },
            Check::Slot0TickBounds {
                pool_id: FixedBytes::ZERO,
                min: -100,
                max: 100,
            },
        ];

        let encoded = encode_program(&checks);
        assert!(!encoded.is_empty());
        // Basic sanity check: should start with opcode bytes
        assert_eq!(encoded[0], 0x01); // CheckDeadline
        assert_eq!(encoded[1 + 8], 0x30); // CheckRfsClosed (after deadline u64)
    }

    #[test]
    fn test_encode_envelope() {
        let envelope = IntentEnvelope {
            version: 1,
            nonce: U256::from(42u64),
            deadline: 1234567890u64,
            call_bundle_hash: FixedBytes::ZERO,
            program_bytes: vec![0x01, 0x02, 0x03],
            signature: vec![0u8; 65],
            domain_chain_id: 1,
            domain_verifying_contract: Address::ZERO,
            wallet: Address::ZERO,
            permission_id: FixedBytes::ZERO,
        };

        let encoded = encode_envelope(&envelope);
        
        // Should contain version (2) + nonce (32) + deadline (8) + hash (32) + program_len (4) + program (3) + sig_len (2) + sig (65)
        let expected_len = 2 + 32 + 8 + 32 + 4 + 3 + 2 + 65;
        assert_eq!(encoded.len(), expected_len);
    }
}

