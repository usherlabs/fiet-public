//! LiquidityManager - Signals Liquidity to VRLManager
//!
//! This contract signals verified liquidity to the `VRLManager` contract on Arbitrum Stylus.
//! It is designed to work with a trusted authority or future ZK-proof integration, initializing
//! with a `VRLManager` address and facilitating liquidity deposits.

// Use this contract to signal some liquidity to the VRL manager and some delta to the delta manager
// It is responsible for injecting verified liquidity into the protocol
// for every positive value added a negative value is assigned to maintain a zero sum
// i.e during a deposit a positive value(VRL) goes to the user and the negative(delta) goes to the custodian

#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, I256};
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
        address delta_manager;
    }
}

// Define an interface for external function calls
sol_interface! {
    interface IVRLManager  {
        function depositVerifiedFiat(address owner, bytes32 currency_hash, uint256 amount) external;
    }

    interface IDeltaManager {
        function signalDelta(address owner, bytes32 currency_hash, int256 delta) external returns (int256);
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
    pub fn initialize(
        &mut self,
        vrl_manager_address: Address,
        delta_manager_address: Address,
    ) -> Result<(), Vec<u8>> {
        // make sure the contract is initialized yet
        if self.initialized.get() {
            return Err("ALREADY_INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.vrl_manager.set(vrl_manager_address);
        self.contracts.delta_manager.set(delta_manager_address);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(self.vm().msg_sender());

        return Ok(());
    }

    /// Manually verifies a deposit  to the `VRLManager`.
    /// This method signals liquidity which is being held by a custodian
    ///
    /// Called by a trusted authority (future plans include ZK-proof support)
    /// to signal a deposit made to the custodian and a call is made to the
    /// `VRLManager` contract to record the deposit and to the deltamanager to record the deltas.
    ///
    /// # Arguments
    /// * `owner` - The recipient of the deposit.
    /// * `custodian` - The custodian this deposit should go through.
    /// * `currency` - A string representing the currency (e.g., "USD", "NGN").
    /// * `amount` - The amount of liquidity to signal, in `U256` units.
    ///
    /// # Returns
    /// * `Ok(())` if the deposit is successfully signaled.
    /// * `Err(Vec<u8>)` if the external call fails.
    ///
    /// # Notes
    /// - Currently relies on a trusted authority; future versions may use ZK-proofs.
    pub fn manual_signal_deposit(
        &mut self,
        owner: Address,
        custodian: Address,
        currency: String,
        amount: U256,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        // the net-delta has to be zero
        // so we increase the VRL record for the owner by the signaled amount
        // and we incur a negative delta for the Custodian to imply they 'owe' the protocol this amount signalled
        // and should have the corresponding liquidity
        // it is similar to lending them money at a 1:1 ratio
        // TODO: we might apply fees here
        let vrl_deposit_amount = amount;
        let custodian_delta = -I256::unchecked_from(amount);

        // can only be called by owner
        if sender != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        let vrl_manager = IVRLManager::new(self.contracts.vrl_manager.get());

        let currency_hash = keccak(currency.as_bytes().to_vec());
        // make a call to the vrl manager to update the balance of VRL owned by the user making the deposit
        vrl_manager.deposit_verified_fiat(
            &mut *self,
            owner,
            currency_hash,
            vrl_deposit_amount,
        )?;

        // notify the deltas contract by increasing the delta of the LP
        // there is no need to increase the delta of the custodian
        IDeltaManager::new(self.contracts.delta_manager.get()).signal_delta(
            &mut *self,
            custodian,
            currency_hash,
            custodian_delta,
        )?;
        Ok(())
    }

    /// Manually verifies liquidity reserves and signals liquidity.
    ///
    /// Called by a trusted authority (future plans include ZK-proof support)
    /// to signal liquidity which is being held by a third party.
    ///
    /// # Arguments
    /// * `lp_address` - The address of recipient of the liquidity signal.
    /// * `currency` - A string representing the currency (e.g., "USD", "NGN").
    /// * `amount` - The amount of liquidity to signal, in `U256` units.
    ///
    /// # Returns
    /// * `Ok(())` if the liquidity is successfully signaled.
    /// * `Err(Vec<u8>)`
    ///
    /// # Notes
    /// - The `currency` is hashed using `keccak256` to match the `bytes32` expected by `VRLManager`.
    /// - Currently relies on a trusted authority; future versions may use ZK-proofs.
    pub fn manual_signal_liquidity(
        &mut self,
        lp_address: Address,
        currency: String,
        amount: U256
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        // the net-delta has to be zero
        // so we increase the VRL record for the LP by the signaled amount
        // and we incur a negative delta for the LP to imply they 'owe' the protocol this amount signalled
        // it is similar to lending them money at a 1:1 ratio
        // TODO: we might apply fees here
        let vrl_deposit_amount = amount;
        let lp_delta_amount = -I256::unchecked_from(amount);

        // can only be called by owner
        if sender != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        let vrl_manager = IVRLManager::new(self.contracts.vrl_manager.get());

        let currency_hash = keccak(currency.as_bytes().to_vec());
        // make a call to the vrl manager to update the balance of VRL owned by the user making the deposit
        vrl_manager.deposit_verified_fiat(
            &mut *self,
            lp_address,
            currency_hash,
            vrl_deposit_amount,
        )?;

        // notify the deltas contract by increasing the delta of the LP
        // there is no need to increase the delta of the custodian
        IDeltaManager::new(self.contracts.delta_manager.get()).signal_delta(
            &mut *self,
            lp_address,
            currency_hash,
            lp_delta_amount,
        )?;
        Ok(())
    }
}
