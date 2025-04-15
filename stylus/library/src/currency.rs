// SPDX-License-Identifier: MIT
// Copyright (c) 2025, [Your Name or Organization]

//! Currency Enum Module
//!
//! This module defines a simple `Currency` enum representing a set of hardcoded currencies.
//! It includes an implementation of the `Display` trait to provide string representations
//! of each currency variant, suitable for formatting and display purposes.

use std::fmt::Display;
use alloy_primitives::FixedBytes;
use stylus_sdk::crypto::keccak;


/// An enum representing supported currencies.
///
/// Each variant corresponds to a specific currency, identified by its ISO 4217 code.
/// The enum is designed to be lightweight, with string representations provided via
/// the `Display` trait implementation.
#[derive(Debug, PartialEq)]
pub enum Currency {
    NGN,
    AUD,
}

/// Implements the `Display` trait for `Currency` to enable string formatting..
impl Display for Currency {
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
            Self::NGN => "NGN", // Nigerian Naira
            Self::AUD => "AUD"  // Australian Dollar
        };

        // Write the string representation to the formatter.
        f.write_str(str_repr)
    }
}

impl Currency {
    pub fn hash(&self) -> FixedBytes<32> {
        let hash_string_bytes = self.to_string();

        return keccak(hash_string_bytes);
    }
}