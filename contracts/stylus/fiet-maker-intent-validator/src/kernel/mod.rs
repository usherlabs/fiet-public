//! Kernel (ERC-7579 / Kernel v3) compatibility shims.
//!
//! This module exists to keep the Stylus policy ABI-aligned with Kernel's `IPolicy` expectations
//! while keeping the actual intent logic isolated elsewhere.

pub mod constants;
pub mod interfaces;
pub mod types;


