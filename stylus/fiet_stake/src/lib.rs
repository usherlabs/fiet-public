#![cfg_attr(not(any(test, feature = "export-abi")), no_main)]
extern crate alloc;

use alloy_primitives::Address;
use stylus_sdk::{alloy_primitives::U256, prelude::*};

sol_storage! {
    #[entrypoint]
    pub struct FietStake {
        bool initialized;
        address owner;
        uint256 total_supply;
        mapping(address => uint256) balance_of;
        mapping(address => bool) is_admin;
        Contracts contracts;
    }

    pub struct Contracts{
        address stake_token;
    }
}

sol_interface! {
    interface IERC20 {
        function transferFrom(address from, address to, uint256 value) external returns (bool);
        function transfer(address to, uint256 value) external returns (bool);
    }
}

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
    pub fn initialize(&mut self, stake_token: Address) -> Result<(), Vec<u8>> {
        let sender = self.vm().msg_sender();
        // make sure the contract is not initialized yet
        if self.initialized.get() {
            return Err("NOT INITIALIZED".into());
        };

        // initialize important variables
        self.contracts.stake_token.set(stake_token);

        // set the initialized value to be true to prevent another reinitialization
        self.initialized.set(true);
        // set the owner of the contract
        self.owner.set(sender);
        // set the owner as an admin
        self.is_admin.setter(sender).set(true);

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

    /// Allows users to stake tokens into the contract.
    ///
    /// # Arguments
    /// * `amount` - The amount of tokens to stake.
    ///
    /// # Returns
    /// * `Ok(())` on success.
    /// * `Err(Vec<u8>)` if the amount is zero.
    pub fn stake(&mut self, amount: U256) -> Result<(), Vec<u8>> {
        // validate none zero input amount
        if amount < U256::from(0) {
            return Err("INVALID STAKE AMOUNT".into());
        }

        // get the variables required to perform a stake
        let sender = self.vm().msg_sender();
        let self_address = self.vm().contract_address();
        let stake_token_address = self.contracts.stake_token.get();

        // perform a transfer from
        let token = IERC20::new(stake_token_address);
        let response = token.transfer_from(&mut *self, sender, self_address, amount)?;

        assert!(response);

        // update the balance of the user in the contract
        let existing_balance = self.balance_of.get(sender);
        self.balance_of
            .setter(sender)
            .set(existing_balance + amount);

        return Ok(());
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
        if amount < U256::from(0) {
            return Err("INVALID STAKE AMOUNT".into());
        }

        // variables important to facilitate unstaking
        let sender = self.vm().msg_sender();
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
        if self.is_admin.get(sender) {
            return Err("CALLER IS NOT OWNER".into());
        }

        // get the user's total stake
        let user_stake = self.balance_of.get(owner);

        // get the amount from it to slash
        let amount_to_slash = (user_stake * bps) / U256::from(10_000);
        self.balance_of
            .setter(owner)
            .set(user_stake - amount_to_slash);

        // assign slashed amount to the contract
        let contract_balance = self.balance_of.get(contract_address);
        self.balance_of
            .setter(owner)
            .set(contract_balance + amount_to_slash);

        return Ok(());
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

        // can only be called by owner
        if sender != self.owner.get() {
            return Err("CALLER IS NOT OWNER".into());
        }

        // assert there is enough balance
        let contract_balance = self.balance_of.get(contract_address);
        if contract_balance < amount {
            return Err("INSUFFICIENT BALANCE".into());
        }

        // update user balance in storage
        self.balance_of
            .setter(contract_address)
            .set(contract_balance - amount);

        // perform transfer operation and send to specified address
        let valid = IERC20::new(stake_token_address).transfer(&mut *self, to, amount)?;
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
}

#[cfg(test)]
mod test {
    use super::*;
    use stylus_sdk::testing::*;

    #[test]
    fn test_can_initialize_staking_contract() {
        let vm = TestVM::default();
        let mut contract = FietStake::from(&vm);

        // define and mock several variables
        // set contracts to call as
        let sender_address = vm.msg_sender();
        let stake_token = sender_address.clone();

        // initialize the contract
        contract.initialize(stake_token).unwrap();

        let owner = contract.owner.get();
        let initialized = contract.initialized.get();

        assert!(initialized);
        assert_eq!(owner, sender_address);
    }
}
