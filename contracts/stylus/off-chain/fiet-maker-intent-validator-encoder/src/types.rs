use alloy_primitives::{FixedBytes, U256};

/// Intent policy envelope that is interpreted on-chain (policy-local signature slice).
#[derive(Clone, Debug)]
pub struct IntentEnvelope {
    /// Protocol version for forwards compatibility.
    pub version: u16,
    /// Wallet-scoped replay nonce.
    pub nonce: U256,
    /// Unix timestamp deadline.
    pub deadline: u64,
    /// Keccak256 of the call bundle (targets + selectors + calldata hashes + values).
    pub call_bundle_hash: FixedBytes<32>,
    /// Encoded check program (opcode + operands).
    pub program_bytes: Vec<u8>,
}

