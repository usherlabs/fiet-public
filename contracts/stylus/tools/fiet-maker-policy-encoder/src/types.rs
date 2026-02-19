use alloy_primitives::{Address, FixedBytes, U256};

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

    /// ECDSA signature (r||s||v) over the EIP-712 digest of the envelope (policy-specific).
    pub signature: Vec<u8>,

    /// Domain separation parameters (used for digest construction).
    pub domain_chain_id: u64,
    pub domain_verifying_contract: Address,

    /// Message scoping fields.
    pub wallet: Address,
    pub permission_id: FixedBytes<32>,
}

