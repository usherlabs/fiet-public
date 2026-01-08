//!
//! Stylus intent validator (Option B scaffold).
//!
//! This crate hosts the on-chain “Atomic Revalidation” intent validator described in
//! `PROPOSAL.md`, exposed as a Kernel-compatible `IValidator`/`IHook` module.
//!
//! The program is ABI-equivalent with Solidity; run `cargo stylus export-abi` to generate an ABI.
//!
// Allow `cargo stylus export-abi` to generate a main function.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
#![cfg_attr(not(any(test, feature = "export-abi")), no_std)]

#[macro_use]
extern crate alloc;

pub mod kernel;
mod intent_validator;
pub mod types;
pub mod decoder;
pub mod evaluator;
pub mod errors;
pub mod facts;

pub use intent_validator::IntentValidator;


