#[cfg(test)]
mod tests {
    use crate::encoder::{encode_envelope, encode_program, intent_digest};
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
    fn test_intent_digest() {
        let chain_id = 1u64;
        let validator = Address::ZERO;
        let smart_account = Address::ZERO;
        let nonce = U256::from(42u64);
        let deadline = 1234567890u64;
        let call_bundle_hash = FixedBytes::ZERO;
        let program_bytes = b"test program";

        let digest = intent_digest(
            chain_id,
            validator,
            smart_account,
            nonce,
            deadline,
            call_bundle_hash,
            program_bytes,
        );

        // Digest should be 32 bytes (FixedBytes<32>)
        assert_eq!(digest.len(), 32);
        // Should not be all zeros (very unlikely)
        assert_ne!(digest, FixedBytes::ZERO);
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
        };

        let encoded = encode_envelope(&envelope);
        
        // Should contain version (2 bytes) + nonce (32) + deadline (8) + hash (32) + program_len (4) + program + sig_len (2) + sig (65)
        let expected_min_len = 2 + 32 + 8 + 32 + 4 + 3 + 2 + 65;
        assert!(encoded.len() >= expected_min_len);
    }
}

