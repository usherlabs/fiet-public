//! Shared types for the Fiet Maker policy.
//!
//! This crate is intentionally `no_std` so it can be reused both:
//! - on-chain (Stylus WASM), and
//! - off-chain tooling (encoders, deployers, test harnesses).

#![no_std]

extern crate alloc;

pub mod facts;
pub mod opcodes;

pub use facts::{FactsError, FactsProvider, Slot0};
pub use opcodes::{Check, CompOp, Opcode};

