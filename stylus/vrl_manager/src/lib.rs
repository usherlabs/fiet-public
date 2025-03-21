// SPDX-License-Identifier: MIT
// Copyright (c) 2025, [Your Name or Organization]

//! VRLManager - Fiat Liquidity Management for Fiet Protocol
//!
//! This contract, written in Rust for Arbitrum's Stylus framework, manages locked fiat liquidity
//! in the Fiet Protocol. It interacts with the CSMM contract and other peripheral contracts
//! to facilitate fiat-to-crypto and crypto-to-fiat swaps, providing volatility fees and liquidity
//! locking/unlocking functionality. Deployed as WebAssembly (WASM), it leverages Stylus's
//! efficiency while maintaining EVM compatibility.
//!
//! Key Features:
//! - Locks and unlocks fiat liquidity for RLPs.
//! - Integrates with CSMM for Liquidity Delta (LD) token operations.

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, FixedBytes};
use alloy_sol_types::sol;
use stylus_sdk::{alloy_primitives::U256, prelude::*};

// Define some persistent storage using the Solidity ABI.
sol_storage! {
    #[entrypoint]
    pub struct VRLManager {
        bool initialized;
        address owner;
        uint256 decimals;
        uint256 locked_vrl;
        mapping(address => mapping(bytes32 => uint256)) balance_of;
        Contracts contracts;
    }

    pub struct Contracts{
        address liquidity_verifier;
        address uniswap_hook;
    }
}

// Declare events and Solidity error types
sol! {
    // define events to be emitted when funds are signalled into the protocol
    event Deposit(address indexed owner, bytes32 indexed currencyHash, uint256 value);
}

#[public]
impl VRLManager {
    // initialize the contract with the important parameters
    pub fn initialize(
        &mut self,
        liquidity_verifier: Address,
        uniswap_hook: Address,
        decimals: U256,
    ) -> Result<(), Vec<u8>> {
        // make sure the contract is not initialized yet
        assert!(!self.initialized.get(), "NOT_INITIALIZED");

        // set the addresses of the contracts to be called
        self.contracts.liquidity_verifier.set(liquidity_verifier);
        self.contracts.uniswap_hook.set(uniswap_hook);
        self.decimals.set(decimals);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(self.vm().msg_sender());

        return Ok(());
    }

    /// Deposits verified fiat into the user's balance.
    ///
    /// # Arguments
    /// * `owner` - The address of the user.
    /// * `currency_hash` - A 32-byte fixed hash representing the currency.
    /// * `amount` - The amount of fiat to deposit.
    ///
    /// # Returns
    /// * `Ok(())` - If the deposit is successful.
    /// * `Err(Vec<u8>)` - An error if the operation fails.
    ///
    /// # Requirements
    /// * Can only be called by the liquidity verifier.
    pub fn depost_verified_fiat(
        &mut self,
        owner: Address,
        currency_hash: FixedBytes<32>,
        amount: U256,
    ) -> Result<(), Vec<u8>> {
        // this function can only be called by the liquidity verifier
        if self.vm().msg_sender() == self.contracts.liquidity_verifier.get() {
            return Err("Only liquidity verifier can call".into());
        }
        let mut owner_balances = self.balance_of.setter(owner);
        let mut owner_currency_balance = owner_balances.setter(currency_hash);

        let existing_balance = owner_currency_balance.get();

        owner_currency_balance.set(existing_balance + amount);

        log(
            self.vm(),
            Deposit {
                owner,
                currencyHash: currency_hash,
                value: amount,
            },
        );

        return Ok(());
    }

    /// Retrieves the Verified Reserve Liquidity (VRL) balance for a specific user and currency.
    ///
    /// # Arguments
    /// * `owner` - The address of the user.
    /// * `currency_hash` - A 32-byte fixed hash representing the currency.
    ///
    /// # Returns
    /// * `Ok(U256)` - The VRL balance of the specified currency for the user.
    /// * `Err(Vec<u8>)` - An error if the retrieval fails.
    pub fn get_user_currency_vrl(
        &self,
        owner: Address,
        currency_hash: FixedBytes<32>,
    ) -> Result<U256, Vec<u8>> {
        return Ok(self.balance_of.get(owner).get(currency_hash));
    }

    /// Locks a specified amount of Verified Reserve Liquidity (VRL) for a user.
    ///
    /// # Arguments
    /// * `owner` - The address of the user.
    /// * `currency_hash` - A 32-byte fixed hash representing the currency.
    /// * `delta` - The amount of VRL to lock.
    ///
    /// # Returns
    /// * `Ok(U256)` - The amount of VRL locked.
    /// * `Err(Vec<u8>)` - An error if the operation fails.
    ///
    /// # Requirements
    /// * Can only be called by the Uniswap hook contract.
    /// * The user must have a sufficient VRL balance.
    pub fn lock_vrl(
        &mut self,
        owner: Address,
        currency_hash: FixedBytes<32>,
        delta: U256,
    ) -> Result<U256, Vec<u8>> {
        let amount_locked = delta;
        // this function can only be called by the uniswap hook contract
        if self.vm().msg_sender() == self.contracts.uniswap_hook.get() {
            return Err("Only liquidity verifier can call".into());
        }

        // This function should only be callable by the hook when locking VRL
        let user_currency_balance = self.balance_of.get(owner).get(currency_hash);

        assert!(user_currency_balance >= delta, "INSUFFICIENT_BALANCE");
        let new_user_currency_balance = user_currency_balance - delta;

        // update the locked VRL by delta
        self.locked_vrl.set(self.locked_vrl.get() + amount_locked);

        let mut user_balance_setter = self.balance_of.setter(owner);
        let mut user_balance_setter = user_balance_setter.setter(currency_hash);

        // update the balance of the owner
        user_balance_setter.set(new_user_currency_balance);

        // return the amount locked
        return Ok(amount_locked);
    }

    /// Unlocks a specified amount of Verified Reserve Liquidity (VRL) for a user.
    ///
    /// # Arguments
    /// * `owner` - The address of the user.
    /// * `currency_hash` - A 32-byte fixed hash representing the currency.
    /// * `delta` - The amount of VRL to unlock.
    ///
    /// # Returns
    /// * `Ok(U256)` - The amount of VRL unlocked.
    /// * `Err(Vec<u8>)` - An error if the operation fails.
    ///
    /// # Requirements
    /// * The locked VRL must be sufficient to unlock the requested amount.
    pub fn unlock_vrl(
        &mut self,
        owner: Address,
        currency_hash: FixedBytes<32>,
        delta: U256,
    ) -> Result<U256, Vec<u8>> {
        // This function should only be callable by the hook when locking VRL
        let amount_unlocked = delta;
        assert!(
            self.locked_vrl.get() >= amount_unlocked,
            "INSUFFICIENT_BALANCE"
        );

        // calculate the user's new balance
        let new_user_currency_balance =
            self.balance_of.get(owner).get(currency_hash) + amount_unlocked;

        // get the setter for the user's currency balance
        let mut user_balance_setter = self.balance_of.setter(owner);
        let mut user_balance_setter = user_balance_setter.setter(currency_hash);

        // update the locked VRL by delta
        self.locked_vrl.set(self.locked_vrl.get() - amount_unlocked);

        // update the balance of the owner
        user_balance_setter.set(new_user_currency_balance);

        // return the amount locked
        return Ok(amount_unlocked);
    }

    /// Getter for decimal
    pub fn get_decimals(&self) -> U256 {
        return self.decimals.get();
    }

    /// Getter for the owner
    pub fn get_owner(&self) -> Address {
        return self.owner.get();
    }

    /// Getter for the locked VRL amount
    pub fn get_locked_vrl(&self) -> U256 {
        return self.locked_vrl.get();
    }
}
