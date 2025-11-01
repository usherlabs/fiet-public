#[cfg(test)]
mod test {
    use alloy_primitives::U256;
    use fiet_stake::FietStake;
    use stylus_sdk::testing::*;

    #[test]
    fn test_can_initialize_fiet_stake_contract() {
        let vm = TestVM::default();
        let mut contract = FietStake::from(&vm);
        let sender = vm.msg_sender();

        // define and mock several variables
        let stake_token = sender.clone();
        let delta_manager = sender.clone();
        let settlement_manager = sender.clone();
        let min_stake = U256::from(1e18);

        contract
            .initialize(stake_token, delta_manager, settlement_manager, min_stake)
            .unwrap();

        let contract_min_stake = contract.min_stake.get();
        assert_eq!(contract_min_stake, min_stake);

        let contract_owner = contract.owner.get();
        assert_eq!(contract_owner, sender);

        let is_init = contract.initialized.get();
        assert_eq!(is_init, true);
    }

    #[test]
    fn test_can_set_admin() {
        let vm = TestVM::default();
        let mut contract = FietStake::from(&vm);
        let sender = vm.msg_sender();

        let user = vm.contract_address();

        // define and mock several variables
        let stake_token = sender.clone();
        let delta_manager = sender.clone();
        let settlement_manager = sender.clone();
        let min_stake = U256::from(1e18);

        contract
            .initialize(stake_token, delta_manager, settlement_manager, min_stake)
            .unwrap();

        // set user as admin
        contract.set_admin(user, true).unwrap();

        // confirm user is admin truly
        let is_admin = contract.get_admin(user);
        assert!(is_admin);

        // remove user as admin
        contract.set_admin(user, false).unwrap();

        // confirm user is admin truly
        let is_admin = contract.get_admin(user);
        assert!(!is_admin);
    }

    #[test]
    fn test_can_slash_users_stake() {
        let vm = TestVM::default();
        let mut contract = FietStake::from(&vm);
        let sender = vm.msg_sender();
        let contract_address = vm.contract_address();

        // define and mock several variables
        let stake_token = sender.clone();
        let delta_manager = sender.clone();
        let settlement_manager = sender.clone();
        let min_stake = U256::from(1e18);
        let faux_user_balance = min_stake + min_stake;

        contract
            .initialize(stake_token, delta_manager, settlement_manager, min_stake)
            .unwrap();

        // set the stake of a particular user, then slash it and check the outcome
        contract.balance_of.setter(sender).set(faux_user_balance);

        // get the balance of a user
        let balance = contract.get_balance(sender);
        assert_eq!(balance, faux_user_balance);

        // slash 10% off the balance of this user 10% == 1000bps

        let slash_bps = 1000;
        contract.slash(sender, U256::from(slash_bps)).unwrap();

        // check the balance of the user if it has reduced by 10%
        let expected_slash_amount = min_stake / U256::from(10);

        // make sure the contract's balance has increased by that factor
        let contract_balance = contract.get_balance(contract_address);
        assert_eq!(contract_balance, expected_slash_amount);

        // check user's new balance to have reduced by slash amount
        let user_balance_post_slash = contract.get_balance(sender);
        assert_eq!(user_balance_post_slash, faux_user_balance - expected_slash_amount);
    }
}
