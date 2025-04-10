#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::{Address, I256};
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
    }
}

impl FietStake {
    /// Allows users to stake tokens into the contract.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to stake.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the amount is zero.
    pub fn _stake(&mut self, amount: U256, owner: Address) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        // validate none zero input amount
        if amount < U256::from(0) {
            return Err("INVALID STAKE AMOUNT".into());
        }

        let self_address = self.vm().contract_address();
        let stake_token_address = self.contracts.stake_token.get();

        // perform a transfer from
        // update the balance of the user in the contract
        let existing_balance = self.balance_of.get(owner);
        self.balance_of.setter(owner).set(existing_balance + amount);

        // make sure the sender of the tokens can be debitted while we give the balance to the specified address
        let token = IERC20::new(stake_token_address);
        let response = token.transfer_from(self, sender, self_address, amount)?;

        assert!(response);

        return Ok(());
    }
}

impl FietStake {}

#[public]
impl FietStake {
    /// Initializes the contract with the stake token address.
    ///
    /// Sets up the contract by storing the `stake_token` address and marking the contract as initialized.
    /// Can only be called once, enforced by an assertion. The caller becomes the owner.
    ///
    /// # Arguments
    /// * `stake_token` - The ERC20 token address to be used for staking.
    ///
    /// # Returns
    /// * `Ok(())` on successful initialization.
    /// * `Err(Vec<u8>)` if the contract is already initialized.
    pub fn initialize(
        &mut self,
        stake_token: Address,
        delta_manager: Address,
        settlement_manager: Address,
        min_stake: U256,
    ) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        // make sure the contract is not initialized yet
        if self.initialized.get() {
            return Err("NOT INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.stake_token.set(stake_token);
        self.contracts.delta_manager.set(delta_manager);
        self.contracts.settlement_manager.set(settlement_manager);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(sender);
        // set the owner as an admin
        self.is_admin.setter(sender).set(true);
        // set the settlement contract as an admin mainly so it can slash
        self.is_admin.setter(settlement_manager).set(true);
        // set the minimum stake required as an LP
        self.min_stake.set(min_stake);

        return Ok(());
    }

    /// Assigns or removes admin privileges for a given address.
    ///
    /// # Arguments
    /// * `new_admin_address` - The address to be granted or revoked admin rights.
    /// * `is_admin` - A boolean indicating whether the address should be an admin.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the caller is not the owner.
    pub fn set_admin(&mut self, new_admin_address: Address, is_admin: bool) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();

        // can only be called by owner
        if sender != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        self.is_admin.setter(new_admin_address).set(is_admin);

        return Ok(());
    }

    /// Getter for the is_admin variable. returns the boolean value indicating if the provided address is an admin.
    ///
    /// # Arguments
    /// * `admin_address` - The address we want to check the admin status of
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the caller is not the owner.
    pub fn get_admin(&mut self, admin_address: Address) -> bool {
        return self.is_admin.get(admin_address);
    }

    /// Allows users to stake tokens into the contract.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to stake.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the amount is zero.
    pub fn stake(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        // get the variables required to perform a stake
        let sender = self.vm().msg_sender();

        return self._stake(amount, sender);
    }

    /// Allows users to stake tokens into the contract on behalf of other users.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to stake.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the amount is zero.
    pub fn stake_for(&mut self, owner: Address, amount: U256) -> Result<(), Vec<u8>> {
        return self._stake(amount, owner);
    }

    /// Allows users to unstake their tokens.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to unstake.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the amount is zero or the user has insufficient balance.
    pub fn unstake(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        if amount == U256::ZERO {
            return Err("INVALID STAKE AMOUNT".into());
        }

        // can only unstake if participant is not active i.e if the delta is zero
        let delta_manager_address = self.contracts.delta_manager.get();
        let is_active =
            IDeltaManager::new(delta_manager_address).is_active_participant(&mut *self, sender)?;

        if is_active {
            return Err("PARTICIPANT STILL ACTIVE".into());
        }

        // variables important to facilitate unstaking
        let stake_token_address = self.contracts.stake_token.get();

        // get the balance and make sure there is enough user balance
        let user_balance = self.balance_of.get(sender);
        if user_balance < amount {
            return Err("INSUFFICIENT BALANCE".into());
        }

        // deduct from user balance
        self.balance_of.setter(sender).set(user_balance - amount);

        // perform transfer operation
        let valid = IERC20::new(stake_token_address).transfer(&mut *self, sender, amount)?;
        assert!(valid);

        return Ok(());
    }

    /// Slashes a percentage of a user's staked balance.
    ///
    /// This function allows an admin to penalize a user by reducing their staked balance
    /// based on the given `bps` (basis points). The slashed amount is added to the
    /// contract's balance.
    ///
    /// # Arguments
    /// * `owner` - The address of the user whose stake is being slashed.
    /// * `bps` - The percentage (in basis points) of the user's stake to slash (1 bps = 0.01%).
    ///
    /// # Returns
    /// * `Ok(())` if the slash is successful.
    /// * `Err(Vec<u8>)` if the caller is not an admin.
    pub fn slash(&mut self, owner: Address, bps: U256) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        let contract_address = self.vm().contract_address();

        // can only be called by admin
        if !self.is_admin.get(sender) {
            return Err("CALLER IS NOT ADMIN".into());
        }

        // get the user's total stake
        let user_stake = self.balance_of.get(owner);

        // get the amount from it to slash
        let amount_to_slash = self.get_slash_amount(bps);

        self.balance_of
            .setter(owner)
            .set(user_stake - amount_to_slash);

        // assign slashed amount to the contract
        let contract_balance = self.balance_of.get(contract_address);
        self.balance_of
            .setter(contract_address)
            .set(contract_balance + amount_to_slash);

        return Ok(());
    }

    /// Slashes a percentage of a user's staked balance.
    /// This method offloads the computation of the bps value from target and delta amount
    /// in order to reduce the size of the contract which calls it
    ///
    /// This function allows an admin to penalize a user by reducing their staked balance
    /// based on the given `bps` (basis points). The slashed amount is added to the
    /// contract's balance.
    ///
    /// # Arguments
    /// * `owner` - The address of the user whose stake is being slashed.
    /// * `bps` - The percentage (in basis points) of the user's stake to slash (1 bps = 0.01%).
    ///
    /// # Returns
    /// * `Ok(())` if the slash is successful.
    /// * `Err(Vec<u8>)` if the caller is not an admin.
    pub fn slash_by_amount(
        &mut self,
        owner: Address,
        target_amount: U256,
        delta_amount: I256,
    ) -> Result<(), Vec<u8>> {
        let bps = self.get_slash_bps(target_amount, delta_amount)?;
        return self.slash(owner, bps);
    }

    /// Withdraws slashed funds from the contract.
    ///
    /// This function allows the owner to withdraw a specified `amount` of slashed funds
    /// from the contract balance and send them to the specified `to` address.
    /// Ensures that only the owner can call this function and that there are
    /// sufficient funds in the contract.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to withdraw.
    /// * `to` - The address to send the withdrawn tokens to.
    ///
    /// # Returns
    /// * `Ok(())` on successful withdrawal.
    /// * `Err(Vec<u8>)` if the caller is not the owner.
    pub fn withdraw(&mut self, amount: U256, to: Address) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        let contract_address = self.vm().contract_address();
        let stake_token_address = self.contracts.stake_token.get();
        let token_contract = IERC20::new(stake_token_address);

        // can only be called by owner
        if sender != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        // assert there is enough balance
        let contract_balance = token_contract.balance_of(&mut *self, contract_address)?;
        if contract_balance < amount {
            return Err("INSUFFICIENT BALANCE".into());
        }

        // update user balance in storage
        self.balance_of
            .setter(contract_address)
            .set(contract_balance - amount);

        // perform transfer operation and send to specified address
        let valid = token_contract.transfer(&mut *self, to, amount)?;
        assert!(valid);

        return Ok(());
    }

    /// Returns the balance of a given user.
    ///
    /// # Arguments
    /// * `owner` - The address whose balance is being queried.
    ///
    /// # Returns
    /// * The user's staked balance as `U256`.
    pub fn get_balance(&mut self, owner: Address) -> U256 {
        return self.balance_of.get(owner);
    }

    /// Gets the staked token registered in this contract
    ///
    /// # Returns
    /// * The address of the staked token.
    pub fn get_staked_token(&mut self) -> Address {
        return self.contracts.stake_token.get();
    }

    /// Getter for the min stake amount
    ///
    /// # Returns
    /// * The minimum stake allowed in this contract.
    pub fn get_min_stake(&self) -> U256 {
        return self.min_stake.get();
    }

    /// Returns is a particular address is sufficiently staked.
    ///
    /// # Arguments
    /// * `owner` - The address whose balance is being queried.
    ///
    /// # Returns
    /// * A boolean indicating if this user is sufficiently staked.
    pub fn is_staked(&mut self, owner: Address) -> bool {
        return self.get_balance(owner) >= self.min_stake.get();
    }

    /// Calculates the BPS to be slashed, the higher the target amount.
    /// The higher the 'delta_amount(owed amount)' compared to the `target_amount(rfs_amount)` the higher the slash value.
    /// it is worth noting that the BPS is relative to the minimum staked amount not the user's balance/
    ///
    /// # Arguments
    /// * `owner` - The address whose balance is being queried.
    ///
    /// # Returns
    /// * A boolean indicating if this user is sufficiently staked.
    pub fn get_slash_bps(&self, target_amount: U256, delta_amount: I256) -> Result<U256, Vec<u8>> {
        // at delta_amount == target_amount
        // the stake is slashed by 50%
        // the smoothing factor can be used to decrease amount slashed
        // i.e smoothing factor of 0.5 makes slash 25% when delta_amount = target_amount
        let delta_amount: U256 = U256::try_from(delta_amount).unwrap();
        let one_bps_fraction = U256::from(5000);
        let slash_bps = (delta_amount / (delta_amount + target_amount)) * one_bps_fraction;

        return Ok(slash_bps);
    }

    pub fn get_slash_amount(&self, bps: U256) -> U256 {
        let min_stake = self.min_stake.get();

        // get the amount from it to slash
        let amount_to_slash = (min_stake * bps) / U256::from(10_000);

        return amount_to_slash;
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
