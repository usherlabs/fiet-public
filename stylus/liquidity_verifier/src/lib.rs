// SPDX-License-Identifier: MIT
// Copyright (c) 2025, [Your Name or Organization]

//! LiquidityManager - Signals Liquidity to VRLManager
//!
//! This contract signals verified liquidity to the `VRLManager` contract on Arbitrum Stylus.
//! It is designed to work with a trusted authority or future ZK-proof integration, initializing
//! with a `VRLManager` address and facilitating liquidity deposits.

// Use this contract to signal some liquidity to the VRL manager

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::Address;
/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::{alloy_primitives::U256, crypto::keccak, prelude::*};

// Define some persistent storage using the Solidity ABI.
sol_storage! {
    #[entrypoint]
    pub struct LiquidityManager {
        bool initialized;
        address owner;
        Contracts contracts;
    }

    pub struct Contracts{
        address vrl_manager;
    }
}

// Define an interface for external function calls
sol_interface! {
    interface IVRLManager  {
        function depostVerifiedFiat(address owner, bytes32 currency_hash, uint256 amount) external;
    }
}

#[public]
impl LiquidityManager {
    /// Initializes the contract with essential parameters.
    ///
    /// Sets up the contract by storing the `VRLManager` address and marking the contract as initialized.
    /// Can only be called once, enforced by an assertion. The caller becomes the owner.
    ///
    /// # Arguments
    /// * `vrl_manager_address` - The address of the `VRLManager` contract to interact with.
    ///
    /// # Returns
    /// * `Ok(())` on successful initialization.
    /// * `Err(Vec<u8>)` if the contract is already initialized (assertion failure).
    pub fn initialize(&mut self, vrl_manager_address: Address) -> Result<(), Vec<u8>> {
        // make sure the contract is initialized yet
        if self.initialized.get() {
            return Err("NOT_INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.vrl_manager.set(vrl_manager_address);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(self.vm().msg_sender());

        return Ok(());
    }

    /// Manually verifies and signals liquidity to the `VRLManager`.
    ///
    /// Called by a trusted authority (future plans include ZK-proof support) to signal verified
    /// liquidity. Hashes the provided currency string and calls `depostVerifiedFiat` on the
    /// `VRLManager` contract to record the deposit.
    ///
    /// # Arguments
    /// * `owner` - The address of the liquidity owner.
    /// * `currency` - A string representing the currency (e.g., "USD"), hashed to `bytes32`.
    /// * `amount` - The amount of liquidity to signal, in `U256` units.
    ///
    /// # Returns
    /// * `Ok(())` if the liquidity is successfully signaled.
    /// * `Err(Vec<u8>)` if the external call to `VRLManager` fails.
    ///
    /// # Notes
    /// - The `currency` is hashed using `keccak256` to match the `bytes32` expected by `VRLManager`.
    /// - Currently relies on a trusted authority; future versions may use ZK-proofs.
    pub fn manual_verify_and_signal_liquidity(
        &mut self,
        owner: Address,
        currency: String,
        amount: U256,
    ) -> Result<(), Vec<u8>> {
        let vrl_manager = IVRLManager::new(self.contracts.vrl_manager.get());

        let currency_hash = keccak(currency.as_bytes().to_vec());
        // make a call to the vrl manager
        vrl_manager.depost_verified_fiat(self, owner, currency_hash, amount)?;
        return Ok(());
    }
}
