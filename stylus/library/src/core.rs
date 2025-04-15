// SPDX-License-Identifier: MIT
// Copyright (c) 2025, [Your Name or Organization]

//! Role and RFSStage Enum Module
//!
//! This module defines core enums used within the Fiet Protocol, including:
//! - `Role`: Represents whether a participant is a Custodian or LP.
//! - `RFSStage`: Represents the current lifecycle stage of a Request for Settlement (RFS).
//!
//! Each enum includes utility implementations for display formatting and serialization.

use std::fmt::Display;
use alloy_primitives::FixedBytes;
use stylus_sdk::crypto::keccak;

/// Represents the participant's role in the protocol.
///
/// Either a `Custodian`, responsible for fiat settlement,
/// or an `LP` (Liquidity Provider), who supplies liquidity.
pub enum Role {
    Custodian,
    LP,
}

/// Implements the `Display` trait for `Role` to enable string formatting.
impl Display for Role {
    /// Formats the `Role` variant as a string.
    ///
    /// Maps each enum variant to a descriptive label and writes
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
            Self::Custodian => "CUSTODIAN",
            Self::LP => "LP",
        };

        // Write the string representation to the formatter.
        f.write_str(str_repr)
    }
}

impl Role {
    /// Returns a 32-byte keccak hash of the role's string representation.
    ///
    /// Useful for role-based access control or on-chain identifiers.
    pub fn hash(&self) -> FixedBytes<32> {
        let hash_string_bytes = self.to_string();
        return keccak(hash_string_bytes);
    }
}

/// Represents the current stage of a Request for Settlement (RFS).
///
/// The lifecycle includes initialization, bidding by LPs, settlement,
/// closure (fulfilled), or expiry (unfulfilled).
#[derive(Copy, Clone)]
pub enum RFSStage {
    INITIALIZED = 0,
    BIDDING = 1,
    SETTLEMENT = 2,
    CLOSED = 3,
    EXPIRED = 4,
}

impl RFSStage {
    /// Returns the numeric representation of the RFS stage.
    ///
    /// # Returns
    /// * `u8` corresponding to the variant's ordinal value.
    pub fn as_u8(&self) -> u8 {
        self.clone() as u8
    }
}
