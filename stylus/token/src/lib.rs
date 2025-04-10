// Only run this as a WASM if the export-abi feature is not set.
#![cfg_attr(not(any(feature = "export-abi", test)), no_main)]
extern crate alloc;

// Modules and imports
mod erc20;

use crate::erc20::{Erc20, Erc20Error, Erc20Params};
use alloy_primitives::{Address, U256};
use stylus_sdk::prelude::*;

/// Immutable definitions
pub struct StylusTokenParams;
impl Erc20Params for StylusTokenParams {
    const NAME: &'static str = "Fiet Token";
    const SYMBOL: &'static str = "FIET";
    const DECIMALS: u8 = 18;
}

// Define the entrypoint as a Solidity storage object. The sol_storage! macro
// will generate Rust-equivalent structs with all fields mapped to Solidity-equivalent
// storage slots and types.
sol_storage! {
    #[entrypoint]
    pub struct FietToken {
        bool initialized;
        address owner;
        // Allows erc20 to access FietToken's storage and make calls
        #[borrow]
        Erc20<StylusTokenParams> erc20;
    }
}

#[public]
#[inherit(Erc20<StylusTokenParams>)]
impl FietToken {
    pub fn initialize(&mut self) -> Result<(), Vec<u8>> {
        // make sure the contract is not initialized yet
        if self.initialized.get() {
            return Err("NOT_INITIALIZED".into());
        };
        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(self.vm().msg_sender());

        return Ok(());
    }

    /// Mints tokens
    pub fn mint(&mut self, value: U256) -> Result<(), Erc20Error> {
        assert!(self.vm().msg_sender() == self.owner.get(), "NOT_OWNER");

        self.erc20.mint(self.vm().msg_sender(), value)?;
        Ok(())
    }

    /// Mints tokens to another address
    pub fn mint_to(&mut self, to: Address, value: U256) -> Result<(), Erc20Error> {
        assert!(self.vm().msg_sender() == self.owner.get(), "NOT_OWNER");

        self.erc20.mint(to, value)?;
        Ok(())
    }

    /// Burns tokens
    pub fn burn(&mut self, value: U256) -> Result<(), Erc20Error> {
        assert!(self.vm().msg_sender() == self.owner.get(), "NOT_OWNER");

        self.erc20.burn(self.vm().msg_sender(), value)?;
        Ok(())
    }
}
