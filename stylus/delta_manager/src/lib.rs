//! DeltaManager - Tracks and Settles Participant Deltas in Fiet Protocol
//!
//! This contract manages LPs and custodians across currencies, tracking their settlement deltas
//! and ensuring obligations are recorded and settled accurately. It is deployed on Arbitrum Stylus
//! and integrates with external contracts like VRLManager and FietStake to verify stakes and burn VRL
//! for settlement.
//
// This contract is responsible for:
// - Registering LPs (requires staked FIET) and whitelisted custodians
// - Tracking each participant’s delta balance across currencies
// - Emitting and settling deltas using VRL tokens to maintain balance
// - Managing per-currency participant lists
// - Restricting access via roles and external contract checks
//
// All delta changes are zero-sum: a positive delta for one participant implies
// a negative delta for another, maintaining protocol balance.

// Allow `cargo stylus export-abi` to generate a main function.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, FixedBytes, U256};
use fiet_library::{core::Role, traits::Hashable};

/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::{alloy_primitives::I256, prelude::*};

sol_storage! {
    #[entrypoint]
    pub struct DeltaManager {
        bool initialized;
        address owner;
        // store all the RLP's who are active in a particular currency
        mapping(bytes32 => address[]) participants_of;
        /// Contains the details about a participant
        mapping(address => Participant) delta_of;
        /// @notice Tracks whitelisted custodians
        /// @dev It can only be modified by an admin i.e only an admin(deployer) can set custodians
        mapping(address => bool) is_custodian;
        Contracts contracts;
    }

    pub struct Contracts {
        address liquidity_verifier;
        address stake_contract;
        address vrl_manager;
        address settlement_manager;
    }

    // store details about a custodian or LP
    pub struct Participant {
        // a hash representing the role of this user
        bytes32 role_hash;
        // the currency this participaht deals in
        bytes32 currency_hash;
        // track if this LP is active
        bool is_active;
        /// @notice Tracks the settlement delta for each address in the protocol.
        /// @dev A negative delta indicates the address owes the protocol (e.g., -50 means they owe 50 units).
        ///      A positive delta indicates the protocol owes the address (e.g., +50 means they are owed 50 units).
        ///      Note: This mapping uses int256 as the key, which may be intended as a value in a reverse mapping.
        ///      Example: If delta_of[-50] = "0x01", address "0x01" owes 50 units.
        int256 delta;
    }
}

sol_interface! {
    interface IFietStake  {
        function isStaked(address owner) external returns (bool);
    }

    interface IVRLManager  {
        function burnVrlForDelta(address owner, bytes32 currency_hash, uint256 delta) external returns (uint256);
    }
}

impl DeltaManager {
    /// Registers a new participant (LP or custodian) in the protocol.
    ///
    /// Adds participant metadata including role and currency hash, and activates them.
    /// If the participant is already active, the function exits early with success.
    /// Also updates the per-currency participant list for future lookup.
    ///
    /// # Arguments
    /// * `address` - The address of the participant to register.
    /// * `currency_hash` - The hash of the currency this participant operates in.
    /// * `role_hash` - The hashed role (LP or Custodian) of the participant.
    ///
    /// # Returns
    /// * `Ok(())` if the participant is successfully registered or already active.
    /// * `Err(Vec<u8>)` is never returned from this function.
    fn _register_participant(
        &mut self,
        address: Address,
        currency_hash: FixedBytes<32>,
        role_hash: FixedBytes<32>,
    ) -> Result<(), Vec<u8>> {
        let existing_participant = self.delta_of.get(address);

        // validate that this address does not previously exist
        if existing_participant.is_active.get() {
            return Ok(());
        };

        let mut detail_setter = self.delta_of.setter(address);

        detail_setter.role_hash.set(role_hash);
        detail_setter.currency_hash.set(currency_hash);
        detail_setter.is_active.set(true);

        // add the address to the list of participants
        let mut existing_participants_for_currency = self.participants_of.setter(currency_hash);
        // push new participant to this array
        existing_participants_for_currency.push(address);
        Ok(())
    }

    /// Settles a user's delta by burning VRL and updating protocol state.
    ///
    /// Interacts with the `VRLManager` to burn the user's VRL balance for the specified currency and amount.
    /// The returned delta value is added to the user's protocol delta, indicating how much is settled.
    /// A positive delta reduces debt (user is owed less), while a negative delta increases debt.
    ///
    /// # Arguments
    /// * `amount` - The amount of VRL to burn for delta settlement.
    /// * `user` - The address of the user whose delta is being settled.
    ///
    /// # Returns
    /// * `Ok(())` on successful settlement and delta update.
    /// * `Err(Vec<u8>)` if VRLManager throws an error (e.g., insufficient VRL).
    fn _settle_delta(&mut self, amount: U256, user: Address) -> Result<(), Vec<u8>> {
        let currency_hash = self.delta_of.get(user).currency_hash.get();
        // burn vrl, error will be thrown if not enough vrl
        let delta = IVRLManager::new(self.contracts.vrl_manager.get())
            .burn_vrl_for_delta(&mut *self, user, currency_hash, amount)
            .unwrap();

        // take some vrl and convert it to delta
        let participant_getter = self.delta_of.get(user);
        let particpant_old_delta = participant_getter.delta.get();

        let mut participant_setter = self.delta_of.setter(user);
        participant_setter
            .delta
            .set(particpant_old_delta + I256::unchecked_from(delta));

        return Ok(());
    }
}

#[public]
impl DeltaManager {
    /// Initializes the contract with the liquidity verifier address.
    ///
    /// Sets up the contract by storing the `liquidity_verifier` address and marking the contract as initialized.
    /// Can only be called once, enforced by an assertion. The caller becomes the owner.
    ///
    /// # Arguments
    /// * `liquidity_verifier` - The address of the liquidity_verifier who can only call certain methods.
    ///
    /// # Returns
    /// * `Ok(())` on successful initialization.
    /// * `Err(Vec<u8>)` if the contract is already initialized.
    pub fn initialize(
        &mut self,
        liquidity_verifier: Address,
        stake_contract: Address,
        vrl_manager: Address,
        settlement_manager: Address,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        // make sure the contract is not initialized yet
        if self.initialized.get() {
            return Err("ALREADY INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.liquidity_verifier.set(liquidity_verifier);
        self.contracts.stake_contract.set(stake_contract);
        self.contracts.vrl_manager.set(vrl_manager);
        self.contracts.settlement_manager.set(settlement_manager);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(sender);

        return Ok(());
    }

    /// Whitelists or blacklists a custodian address.
    ///
    /// Allows the contract owner to update the `is_custodian` mapping, determining which addresses
    /// are permitted to register as custodians within the protocol.
    ///
    /// # Arguments
    /// * `custodian` - The address of the custodian to whitelist or blacklist.
    /// * `whitelist` - A boolean flag indicating whether to whitelist (`true`) or blacklist (`false`) the address.
    ///
    /// # Returns
    /// * `Ok(())` on successful update.
    /// * `Err(Vec<u8>)` if the caller is not the contract owner.
    pub fn whitelist_custodian(
        &mut self,
        custodian: Address,
        whitelist: bool,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        // ensure only the owner is calling this function
        if sender != self.owner.get() {
            return Err("NOT OWNER".into());
        }

        // set a boolean value for the 'allowed_custodians' mapping
        // to serve as a blacklist or whitelist
        self.is_custodian.setter(custodian).set(whitelist);

        return Ok(());
    }

    /// Registers the caller as a custodian participant.
    ///
    /// Validates that the caller is whitelisted as a custodian and registers them as an active
    /// participant for the specified currency. Assigns the `Custodian` role and stores metadata.
    ///
    /// # Arguments
    /// * `currency_hash` - A hashed identifier representing the currency the custodian supports.
    ///
    /// # Returns
    /// * `Ok(())` on successful registration.
    /// * `Err(Vec<u8>)` if the caller is not whitelisted as a custodian.
    pub fn register_as_custodian(&mut self, currency_hash: FixedBytes<32>) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        let role = Role::Custodian;

        // ensure that only a whitelisted custodian is allowed to be created
        if !self.is_custodian.get(sender) {
            return Err("CUSTODIAN NOT WHITELISTED".into());
        }
        // register the details as a participant
        let role_hash = role.to_string().hash();
        self._register_participant(sender, currency_hash, role_hash)
    }

    /// Registers the caller as a liquidity provider (LP) participant.
    ///
    /// Validates that the caller has sufficient stake in the staking contract and registers them
    /// as an active participant for the specified currency. Assigns the `LP` role and stores metadata.
    ///
    /// # Arguments
    /// * `currency_hash` - A hashed identifier representing the currency the LP supports.
    ///
    /// # Returns
    /// * `Ok(())` on successful registration.
    /// * `Err(Vec<u8>)` if the caller has insufficient stake or other validation fails.
    pub fn register_as_lp(&mut self, currency_hash: FixedBytes<32>) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        let role = Role::LP;

        // make sure they are staked already in the staking contract
        let is_sufficiently_staked =
            IFietStake::new(self.contracts.stake_contract.get()).is_staked(&mut *self, sender)?;

        if !is_sufficiently_staked {
            return Err("INSUFFICIENT STAKE".into());
        }

        // register the details as a participant
        let role_hash = role.to_string().hash();
        self._register_participant(sender, currency_hash, role_hash)
    }

    /// Unregisters the caller as a participant from the protocol.
    ///
    /// Validates that the participant's delta is settled (zero) before allowing unregistration.
    /// If active, the participant is removed from the list of participants for their associated currency.
    ///
    /// # Returns
    /// * `Ok(())` on successful unregistration.
    /// * `Err(Vec<u8>)` if the delta is not settled or the participant is not active.
    pub fn unregister_participant(&mut self) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        let sender_delta = self.delta_of.get(sender).delta.get();

        if sender_delta != I256::ZERO {
            return Err("DELTA NOT SETTLED".into());
        }

        let is_already_active = self.delta_of.get(sender).is_active.get();
        if !is_already_active {
            return Ok(());
        }

        // unregister the participant provided
        let mut participant_setter = self.delta_of.setter(sender);

        participant_setter.is_active.set(false);
        let currency_hash = participant_setter.currency_hash.get();

        // go through all the participants and remove the unregistering address from the list of addresses of participants
        let mut existing_participants_for_currency = self.participants_of.setter(currency_hash);
        let num_participants = existing_participants_for_currency.len();
        for index in 0..num_participants {
            let temp_address = existing_participants_for_currency
                .get(index)
                .unwrap_or_default();
            // if we have found the index of the address to remove, we swap the position with the last and pop the array
            if temp_address == sender {
                let last_participant_for_currency = existing_participants_for_currency
                    .get(num_participants - 1)
                    .unwrap();
                let mut index_setter = existing_participants_for_currency.setter(index).unwrap();
                index_setter.set(last_participant_for_currency);

                // now that we have moved the last item to the entry we want to delete, we can delete the last item as it has been duplicated
                existing_participants_for_currency.erase_last();

                // exit loop
                break;
            }
        }

        return Ok(());
    }

    /// Signals a delta change for a participant from the liquidity signal contract.
    ///
    /// Ensures the caller is the liquidity verifier contract and that the participant is active.
    /// Updates the participant's delta with the provided value, adjusting their balance accordingly.
    ///
    /// # Arguments
    /// * `owner` - The address of the participant whose delta is being updated.
    /// * `currency_hash` - The hash of the currency associated with the participant.
    /// * `delta` - The delta amount to be added or subtracted from the participant's current delta.
    ///
    /// # Returns
    /// * `Ok(delta)` on success, where `delta` is the updated amount.
    /// * `Err(Vec<u8>)` if the caller is unauthorized, participant is not active, or the currency hash is invalid.
    pub fn signal_delta(
        &mut self,
        owner: Address,
        currency_hash: FixedBytes<32>,
        delta: I256,
    ) -> Result<I256, Vec<u8>> {
        // make sure that the caller is the liquidity signal contract
        // as that is the only input through which liquidity enters the protocol
        let sender = self.vm().msg_sender();
        if sender != self.contracts.liquidity_verifier.get() {
            return Err("NOT AUTHORIZED".into());
        }

        // ensure the LP or custodian is active
        let participant_getter = self.delta_of.get(owner);
        if !participant_getter.is_active.get() {
            return Err("PARTICIPANT NOT ACTIVE".into());
        }
        if participant_getter.currency_hash.get() != currency_hash {
            return Err("INVALID CURRENCY HASH".into());
        }

        let particpant_old_delta = participant_getter.delta.get();
        let mut participant_setter = self.delta_of.setter(owner);
        participant_setter.delta.set(particpant_old_delta + delta);

        return Ok(delta);
    }

    /// Retrieves the current delta of a participant.
    ///
    /// Returns the delta value, which represents the participant's balance in the protocol.
    /// A positive delta means the participant is owed liquidity, while a negative delta indicates an amount they owe.
    ///
    /// # Arguments
    /// * `owner` - The address of the participant whose delta is to be retrieved.
    ///
    /// # Returns
    /// * The current delta of the participant as an `I256` value.
    pub fn delta_of_participant(&mut self, owner: Address) -> I256 {
        return self.delta_of.getter(owner).delta.get();
    }

    /// Retrieves the currency hash associated with a participant.
    ///
    /// This function returns the hash of the currency that the participant is involved with in the protocol.
    /// It is used to identify the specific currency or asset that the participant deals with.
    ///
    /// # Arguments
    /// * `owner` - The address of the participant whose currency hash is to be retrieved.
    ///
    /// # Returns
    /// * The currency hash associated with the participant as a `FixedBytes<32>` value.
    pub fn currency_hash_of_participant(&mut self, owner: Address) -> FixedBytes<32> {
        return self.delta_of.getter(owner).currency_hash.get();
    }

    /// Checks if a participant is active.
    ///
    /// This function returns a boolean value indicating whether the participant is currently active in the protocol.
    /// It checks the `is_active` status of the participant to determine their activity state.
    ///
    /// # Arguments
    /// * `owner` - The address of the participant whose activity status is to be checked.
    ///
    /// # Returns
    /// * `true` if the participant is active.
    /// * `false` if the participant is not active.
    pub fn is_active_participant(&mut self, owner: Address) -> bool {
        return self.delta_of.getter(owner).is_active.get();
    }

    /// Retrieves a list of participants associated with a specific currency.
    ///
    /// This function fetches all participants who are registered under the given `currency_hash`.
    /// It returns a vector of addresses of these participants.
    ///
    /// # Arguments
    /// * `currency_hash` - The hash of the currency for which participants are being queried.
    ///
    /// # Returns
    /// * A `Vec<Address>` containing the addresses of participants associated with the given `currency_hash`.
    pub fn get_currency_participants(&mut self, currency_hash: FixedBytes<32>) -> Vec<Address> {
        // settlement_requests
        let mut vector = vec![];
        let res = self.participants_of.get(currency_hash);
        for num in 0..res.len() {
            let addr = res.get(num).unwrap();
            vector.push(addr);
        }

        return vector;
    }

    /// Settles the delta for a user, callable only by the settlement manager.
    ///
    /// This function allows the settlement manager to settle the delta amount for a specific user.
    /// It ensures that only the authorized `settlement_manager` contract can invoke this function.
    ///
    /// # Arguments
    /// * `amount` - The amount to be settled, which will adjust the user's delta.
    /// * `user` - The address of the user whose delta is being settled.
    ///
    /// # Returns
    /// * `Ok(())` if the delta was successfully settled.
    /// * `Err(Vec<u8>)` if the caller is not the authorized settlement manager.
    pub fn admin_settle_delta(&mut self, amount: U256, user: Address) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();
        if caller != self.contracts.settlement_manager.get() {
            return Err("INVALID CALLER".into());
        }

        return self._settle_delta(amount, user);
    }

    /// Settles the delta for the caller (user).
    ///
    /// This function allows any user to settle their own delta amount. It adjusts the user's delta
    /// based on the provided `amount`. The caller's address is used to identify which user's delta to settle.
    ///
    /// # Arguments
    /// * `amount` - The amount to be settled, which will adjust the caller's delta.
    ///
    /// # Returns
    /// * `Ok(())` if the delta was successfully settled for the caller.
    /// * `Err(Vec<u8>)` if an error occurs while settling the delta.
    pub fn user_settle_delta(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();

        return self._settle_delta(amount, caller);
    }
}
