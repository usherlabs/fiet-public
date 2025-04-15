// traits.rs
use alloy_primitives::FixedBytes;
use stylus_sdk::crypto::keccak;

pub trait Hashable {
    fn hash(&self) -> FixedBytes<32>;
}

impl<T: ToString> Hashable for T {
    fn hash(&self) -> FixedBytes<32> {
        let hash_string = self.to_string();
        keccak(hash_string.as_bytes())
    }
}