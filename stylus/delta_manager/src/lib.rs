// Allow `cargo stylus export-abi` to generate a main function.
#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, FixedBytes, I128, U128, U256, U64};
use fiet_library::{core::Role, traits::Hashable};

/// Import items from the SDK. The prelude contains common traits and macros.
use stylus_sdk::{alloy_primitives::I256, prelude::*, storage::StorageVec};

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
    // utility private helper function to register a particpant
    fn _register_participant(
        &mut self,
        address: Address,
        currency_hash: FixedBytes<32>,
        role_hash: FixedBytes<32>,
    ) -> Result<(), Vec<u8>> {
        let existing_participant = self.delta_of.get(address);

        // validate that this address does not previously exist
        if existing_participant.is_active.get() {
            return Err("PARTICIPANT ALREADY ACTIVE".into());
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
            return Err("NOT INITIALIZED".into());
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

    // custodians can only be called by whitelisted custodians
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

    // register the LP, can
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

    pub fn unregister_participant(&mut self) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        let sender_delta = self.delta_of.get(sender).delta.get();

        if sender_delta != I256::ZERO {
            return Err("DELTA NOT SETTLED".into());
        }

        let is_already_active = self.delta_of.get(sender).is_active.get();
        if !is_already_active {
            return Err("USER ALREADY INACTIVE".into());
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

    pub fn delta_of_participant(&mut self, owner: Address) -> I256 {
        return self.delta_of.getter(owner).delta.get();
    }

    pub fn currency_hash_of_participant(&mut self, owner: Address) -> FixedBytes<32> {
        return self.delta_of.getter(owner).currency_hash.get();
    }

    pub fn is_active_participant(&mut self, owner: Address) -> bool {
        return self.delta_of.getter(owner).is_active.get();
    }

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

    pub fn admin_settle_delta(&mut self, amount: U256, user: Address) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();
        if caller != self.contracts.settlement_manager.get() {
            return Err("INVALID CALLER".into());
        }

        return self._settle_delta(amount, user);
    }

    pub fn settle_settle_delta(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        let caller = self.vm().msg_sender();

        return self._settle_delta(amount, caller);
    }
}
