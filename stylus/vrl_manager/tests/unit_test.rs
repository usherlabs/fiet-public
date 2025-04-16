#[cfg(test)]
mod test {
    use alloy_primitives::U256;
    use fiet_library::currency::Currency;
    use fiet_vrl_manager::VRLManager;
    use stylus_sdk::{crypto::keccak, testing::*};

    #[test]
    fn test_can_initialize_vrl_manager() {
        let vm = TestVM::default();
        let mut contract = VRLManager::from(&vm);

        // define and mock several variables
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();
        let delta_manager = sender_address.clone();
        let uniswap_hook = sender_address.clone();
        let decimals = U256::from(6);

        // initialize the contract
        contract
            .initialize(liquidity_verifier, delta_manager, uniswap_hook, decimals)
            .unwrap();

        let contract_decimals = contract.get_decimals();
        let contract_owner = contract.get_owner();

        assert_eq!(contract_decimals, decimals);
        assert_eq!(contract_owner, sender_address);
    }

    #[test]
    fn test_can_deposit_vrl() {
        let vm = TestVM::default();
        let mut contract = VRLManager::from(&vm);

        let sender_address = vm.msg_sender();
        let delta_manager = vm.msg_sender();
        let decimals = U256::from(6);

        // initialize contract
        // set peripheral contract address to the sender so that we can call the restricted functions
        contract
            .initialize(sender_address, delta_manager, sender_address, decimals)
            .unwrap();

        // Deposit some fiat into the contract
        let deposit_currency = Currency::NGN;
        let currency_hash = keccak(deposit_currency.to_string());
        let amount = U256::from(10).pow(decimals);
        let new_amount = U256::from(5).pow(decimals);

        contract
            .deposit_verified_fiat(sender_address, currency_hash, amount)
            .unwrap();

        // get the balance of this user and make sure it matches the initial deposit
        let user_balance = contract
            .get_user_currency_vrl(sender_address, currency_hash)
            .unwrap();
        assert!(user_balance >= amount);

        // make another deposit for the same currency and make sure it reflects
        contract
            .deposit_verified_fiat(sender_address, currency_hash, new_amount)
            .unwrap();
        // get the balance of this user and make sure it matches the deposit
        let user_balance = contract
            .get_user_currency_vrl(sender_address, currency_hash)
            .unwrap();
        assert!(user_balance >= amount + new_amount);

        // make a deposit for another currency and confirm
        let new_currency = Currency::AUD;
        let currency_hash = keccak(new_currency.to_string());
        contract
            .deposit_verified_fiat(sender_address, currency_hash, new_amount)
            .unwrap();

        // get the balance of this user and make sure it matches the initial deposit
        let user_balance = contract
            .get_user_currency_vrl(sender_address, currency_hash)
            .unwrap();
        assert!(user_balance >= new_amount);
    }

    #[test]
    fn test_can_lock_vrl() {
        let vm = TestVM::default();
        let mut contract = VRLManager::from(&vm);

        let sender_address = vm.msg_sender();
        let delta_manager = vm.msg_sender();

        let decimals = U256::from(6);

        // initialize contract
        // set peripheral contract address to the sender so that we can call the restricted functions
        contract
            .initialize(sender_address, delta_manager, sender_address, decimals)
            .unwrap();
        // make a deposit

        // Deposit some fiat into the contract
        let deposit_currency = Currency::NGN;
        let currency_hash = keccak(deposit_currency.to_string());
        let deposit_amount = U256::from(10).pow(decimals);
        let lock_amount = U256::from(5).pow(decimals);

        contract
            .deposit_verified_fiat(sender_address, currency_hash, deposit_amount)
            .unwrap();

        // lock VRL
        let locked_delta = contract
            .lock_vrl(sender_address, currency_hash, lock_amount)
            .unwrap();

        // valildate delta
        assert_eq!(locked_delta, lock_amount);

        // validate that locked VRL amount increases
        let total_locked_vrl = contract.get_locked_vrl();
        assert!(total_locked_vrl >= locked_delta);

        // validate user balance decreases
        let user_balance = contract
            .get_user_currency_vrl(sender_address, currency_hash)
            .unwrap();

        // check balance reduces by locked amount
        assert!(user_balance == deposit_amount - lock_amount);
    }

    #[test]
    fn test_can_unlock_vrl() {
        let vm = TestVM::default();
        let mut contract = VRLManager::from(&vm);

        let sender_address = vm.msg_sender();
        let delta_manager = vm.msg_sender();
        let decimals = U256::from(6);

        // initialize contract
        // set peripheral contract address to the sender so that we can call the restricted functions
        contract
            .initialize(sender_address, delta_manager, sender_address, decimals)
            .unwrap();
        // make a deposit

        // Deposit some fiat into the contract
        let deposit_currency = Currency::NGN;
        let currency_hash = keccak(deposit_currency.to_string());
        let deposit_amount = U256::from(10).pow(decimals);

        let lock_amount = U256::from(5).pow(decimals);
        let unlock_amount = U256::from(1).pow(decimals);

        contract
            .deposit_verified_fiat(sender_address, currency_hash, deposit_amount)
            .unwrap();

        // lock VRL
        let _ = contract
            .lock_vrl(sender_address, currency_hash, lock_amount)
            .unwrap();

        // unlock vrl
        let unlocked_vrl = contract
            .unlock_vrl(sender_address, currency_hash, unlock_amount)
            .unwrap();

        assert_eq!(unlocked_vrl, unlock_amount);

        // validate user balance decreases
        let user_balance = contract
            .get_user_currency_vrl(sender_address, currency_hash)
            .unwrap();

        // check balance reduces by locked amount
        assert!(user_balance == deposit_amount - lock_amount + unlock_amount);
    }
}
