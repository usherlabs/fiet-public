//! Off-chain encoder for Fiet Maker Intent Policy.
//!
//! This crate provides utilities to encode intent policy envelopes and check programs
//! for use with the on-chain Stylus policy.

pub mod encoder;
pub mod facts;
pub mod opcodes;
pub mod types;

#[cfg(test)]
mod tests;

pub use encoder::{encode_envelope, encode_program};
pub use facts::{FactsError, FactsProvider, MockFactsProvider, Slot0};
pub use opcodes::{Check, CompOp, Opcode};
pub use types::IntentEnvelope;

