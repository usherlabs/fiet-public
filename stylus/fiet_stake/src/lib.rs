#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, U64};
use stylus_sdk::{alloy_primitives::U256, prelude::*};

sol_storage! {
    #[entrypoint]
    pub struct FietStake {
        bool initialized;
        address owner;
        uint256 total_supply;
        uint256 min_stake;
        mapping(address => uint256) balance_of;
        mapping(address => bool) is_admin;
        Contracts contracts;
    }

    pub struct Contracts{
        address stake_token;
        address delta_manager;
        address settlement_manager;
    }
}

sol_interface! {
    interface IERC20 {
        function transferFrom(address from, address to, uint256 value) external returns (bool);
        function transfer(address to, uint256 value) external returns (bool);
        function balanceOf(address owner) external view returns (uint256);
    }

    interface IDeltaManager{
        function isActiveParticipant(address owner) external returns (bool);
        function deltaOfParticipant(address owner) external returns (int256);
    }
}

impl FietStake {
    /// Allows users to stake tokens into the contract.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to stake.
    /// * `owner` - The account to credit the staked tokens to.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the amount is zero.
    pub fn _stake(&mut self, amount: U256, owner: Address) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        // Validate non-zero input amount
        if amount == U256::from(0) {
            return Err("INVALID STAKE AMOUNT".into());
        }

        let self_address = self.vm().contract_address();
        let stake_token_address = self.contracts.stake_token.get();

        // Update internal balance
        let existing_balance = self.balance_of.get(owner);
        self.balance_of.setter(owner).set(existing_balance + amount);

        // Transfer tokens from the sender to this contract
        let token = IERC20::new(stake_token_address);
        let response = token.transfer_from(self, sender, self_address, amount)?;

        assert!(response);

        Ok(())
    }
}


#[public]
impl FietStake {
    /// Initializes the contract with staking parameters.
    ///
    /// Sets up the contract with the staking token and managers. Can only be called once.
    /// The caller becomes the owner and is granted admin rights, along with the settlement manager.
    pub fn initialize(
        &mut self,
        stake_token: Address,
        delta_manager: Address,
        settlement_manager: Address,
        min_stake: U256,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        if self.initialized.get() {
            return Err("ALREADY INITIALIZED".into());
        }

        self.contracts.stake_token.set(stake_token);
        self.contracts.delta_manager.set(delta_manager);
        self.contracts.settlement_manager.set(settlement_manager);
        self.min_stake.set(min_stake);

        self.owner.set(sender);
        self.is_admin.setter(sender).set(true);
        self.is_admin.setter(settlement_manager).set(true);

        self.initialized.set(true);

        Ok(())
    }

    /// Grants or revokes admin access to an address. Only callable by owner.
    pub fn set_admin(&mut self, new_admin_address: Address, is_admin: bool) -> Result<(), Vec<u8>> {
        if self.vm().msg_sender() != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        self.is_admin.setter(new_admin_address).set(is_admin);
        Ok(())
    }

    /// Checks if an address is an admin.
    pub fn get_admin(&mut self, admin_address: Address) -> bool {
        self.is_admin.get(admin_address)
    }

    /// Allows users to stake tokens.
    pub fn stake(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        self._stake(amount, sender)
    }

    /// Stakes tokens on behalf of another address.
    pub fn stake_for(&mut self, owner: Address, amount: U256) -> Result<(), Vec<u8>> {
        self._stake(amount, owner)
    }

    /// Allows users to unstake tokens, only if they are inactive.
    pub fn unstake(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        if amount == U256::ZERO {
            return Err("INVALID STAKE AMOUNT".into());
        }

        let delta_manager = IDeltaManager::new(self.contracts.delta_manager.get());
        if delta_manager.is_active_participant(&mut *self, sender)? {
            return Err("PARTICIPANT STILL ACTIVE".into());
        }

        let user_balance = self.balance_of.get(sender);
        if user_balance < amount {
            return Err("INSUFFICIENT BALANCE".into());
        }

        self.balance_of.setter(sender).set(user_balance - amount);

        let token = IERC20::new(self.contracts.stake_token.get());
        let success = token.transfer(&mut *self, sender, amount)?;
        assert!(success);

        Ok(())
    }

    /// Slashes a percentage of a user’s stake (in bps). Only callable by admins.
    pub fn slash(&mut self, owner: Address, bps: U256) -> Result<(), Vec<u8>> {
        if !self.is_admin.get(self.vm().msg_sender()) {
            return Err("CALLER IS NOT ADMIN".into());
        }

        let user_stake = self.balance_of.get(owner);
        let slash_amount = self.get_slash_amount(bps);

        self.balance_of.setter(owner).set(user_stake - slash_amount);

        let contract_address = self.vm().contract_address();
        let contract_balance = self.balance_of.get(contract_address);
        self.balance_of
            .setter(contract_address)
            .set(contract_balance + slash_amount);

        Ok(())
    }

    /// Slashes a user’s stake by computing bps from a target amount and factor.
    pub fn slash_by_amount(
        &mut self,
        owner: Address,
        target_amount: U256,
        slash_factor: U64,
    ) -> Result<(), Vec<u8>> {
        let bps = self.get_slash_bps(owner, target_amount, slash_factor)?;
        self.slash(owner, bps)
    }

    /// Withdraws slashed tokens to a given address. Only callable by the owner.
    pub fn withdraw(&mut self, amount: U256, to: Address) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        if sender != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        let token = IERC20::new(self.contracts.stake_token.get());
        let contract_address = self.vm().contract_address();
        let contract_balance = token.balance_of(&mut *self, contract_address)?;

        if contract_balance < amount {
            return Err("INSUFFICIENT BALANCE".into());
        }

        self.balance_of
            .setter(contract_address)
            .set(contract_balance - amount);

        let success = token.transfer(&mut *self, to, amount)?;
        assert!(success);

        Ok(())
    }

    /// Returns the staked balance of a user.
    pub fn get_balance(&mut self, owner: Address) -> U256 {
        self.balance_of.get(owner)
    }

    /// Returns the address of the staking token.
    pub fn get_staked_token(&mut self) -> Address {
        self.contracts.stake_token.get()
    }

    /// Returns the minimum required stake.
    pub fn get_min_stake(&self) -> U256 {
        self.min_stake.get()
    }

    /// Returns true if the user meets or exceeds the min stake requirement.
    pub fn is_staked(&mut self, owner: Address) -> bool {
        self.get_balance(owner) >= self.min_stake.get()
    }

    /// Calculates slash bps from delta and target amounts.
    pub fn get_slash_bps(
        &mut self,
        owner: Address,
        target_amount: U256,
        slash_factor: U64,
    ) -> Result<U256, Vec<u8>> {
        let delta = IDeltaManager::new(self.contracts.delta_manager.get())
            .delta_of_participant(&mut *self, owner)?;

        let delta_abs = U256::try_from(delta.abs()).expect("INVALID_DELTA");

        let smoothing = U256::from(4);
        let max_bps = U256::from(10_000) / smoothing;
        let base_bps = (delta_abs * max_bps) / (delta_abs + target_amount);

        let extra_bps = U256::from(slash_factor) * U256::from(100);

        Ok(base_bps + extra_bps)
    }

    /// Computes the slash amount from a bps value.
    pub fn get_slash_amount(&self, bps: U256) -> U256 {
        (self.min_stake.get() * bps) / U256::from(10_000)
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn test_can_initialize_staking_contract() {
        let vm = TestVM::default();
        let mut stake_contract = FietStake::from(&vm);

        // define and mock several variables
        // set contracts to call as
        let sender_address = vm.msg_sender();
        let stake_token = sender_address.clone();
        let delta_manager = sender_address.clone();
        let settlement_manager = sender_address.clone();
        let min_stake_amount = U256::from(18e18);

        // initialize the contract
        stake_contract
            .initialize(
                stake_token,
                delta_manager,
                settlement_manager,
                min_stake_amount,
            )
            .unwrap();

        let owner = stake_contract.owner.get();
        let initialized = stake_contract.initialized.get();
        let contract_min_stake = stake_contract.min_stake.get();

        assert!(initialized);
        assert_eq!(owner, sender_address);
        assert_eq!(min_stake_amount, contract_min_stake);
    }
}
