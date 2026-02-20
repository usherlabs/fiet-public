//! Shared types for intent envelope, opcodes, checks, and facts.

pub mod opcodes;
pub mod facts;

pub use opcodes::{Check, CompOp, Opcode};
pub use facts::{FactsProvider, Slot0};

