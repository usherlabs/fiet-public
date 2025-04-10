#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;
pub mod utils;

/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::prelude::*;

// Define some persistent storage using the Solidity ABI.
// This struct will be the entrypoint.
sol_storage! {
    #[entrypoint]
    pub struct Counter {
    }
}

/// Declare the following external methods.
#[public]
impl Counter {}
