use std::fmt::Display;

use alloy_primitives::FixedBytes;
use stylus_sdk::{crypto::keccak, prelude::*};

pub enum Role {
    Custodian,
    LP,
}

impl Display for Role {
    /// Formats the `Currency` variant as a string.
    ///
    /// Maps each enum variant to its corresponding ISO 4217 currency code and writes
    /// it to the provided formatter.
    ///
    /// # Arguments
    /// * `f` - A mutable reference to a `Formatter` used to write the string output.
    ///
    /// # Returns
    /// A `Result` indicating success (`Ok(())`) or a formatting error (`Err`).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // Match the enum variant to its string representation.
        let str_repr = match self {
            Self::Custodian => "CUSTODIAN", // Nigerian Naira
            Self::LP => "LP",               // Australian Dollar
        };

        // Write the string representation to the formatter.
        f.write_str(str_repr)
    }
}

impl Role {
    pub fn hash(&self) -> FixedBytes<32> {
        let hash_string_bytes = self.to_string();

        return keccak(hash_string_bytes);
    }
}
