use alloc::vec::Vec;
use stylus_sdk::alloy_primitives::{Address, FixedBytes, U256};

/// Intent envelope that is signed off-chain and interpreted on-chain.
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
    /// Signature over the envelope (EIP-712 / typed data).
    pub signature: Vec<u8>,
    /// Signer domain separation parameters.
    pub domain_chain_id: u64,
    pub domain_verifying_contract: Address,
}

