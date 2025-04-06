#[cfg(test)]
mod test {
    use alloy_primitives::address;
    use fiet_delta_manager::DeltaManager;
    use fiet_library::{core::Role, currency::Currency, traits::Hashable};
    use stylus_sdk::testing::*;

    #[test]
    fn test_can_initiate_delta_manager() {
        let vm = TestVM::default();
        let mut contract = DeltaManager::from(&vm);

        // define and mock several variables
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();

        // initialize the contract
        contract
            .initialize(
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
            )
            .unwrap();

        let contract_owner = contract.owner.get();
        let is_initialized = contract.initialized.get();

        assert_eq!(contract_owner, sender_address);
        assert_eq!(is_initialized, true);
    }

    #[test]
    fn admin_can_whitelist_custodian() {
        let vm = TestVM::default();
        let mut contract = DeltaManager::from(&vm);

        // define and mock several variables for initialization
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();

        let custodian = address!("0xd8da6bf26964af9d7eed9e03e53415d37aa96045");
        contract
            .initialize(
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
            )
            .unwrap();

        // whitelist certain custodians
        contract.whitelist_custodian(custodian, true).unwrap();

        // validate that the custodian is whitelisted
        let custodian_is_whitelisted = contract.is_custodian.get(custodian);
        assert!(custodian_is_whitelisted);

        // blacklist the custodian and validate
        contract.whitelist_custodian(custodian, false).unwrap();
        // validate that the custodian is not whitelisted
        let custodian_is_whitelisted = contract.is_custodian.get(custodian);
        assert!(!custodian_is_whitelisted);
    }

    #[test]
    fn whitelisted_custodian_can_be_created() {
        let block_number = 15_000;
        let vm = TestVM::default();
        vm.set_block_number(block_number);
        let mut contract = DeltaManager::from(&vm);

        // define and mock several variables for initialization
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();
        let custodian = address!("0xd8da6bf26964af9d7eed9e03e53415d37aa96045");
        let expected_currency_hash = Currency::NGN.to_string().hash();
        let expected_role_hash = Role::Custodian.to_string().hash();

        contract
            .initialize(
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
            )
            .unwrap();
        // whitelist certain custodians
        contract.whitelist_custodian(custodian, true).unwrap();

        // create a custodian by acting as the custodian
        vm.set_sender(custodian); // act as the custodian making this call
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();

        // validate that the participant exists
        let participant = contract.delta_of.getter(custodian);
        let role_hash = participant.role_hash.get();
        let currency_hash = participant.currency_hash.get();

        assert_eq!(role_hash, expected_role_hash);
        assert_eq!(currency_hash, expected_currency_hash);
    }

    #[test]
    fn blacklisted_custodian_cannot_be_created() {
        let block_number = 15_000;
        let vm = TestVM::default();
        vm.set_block_number(block_number);
        let mut contract = DeltaManager::from(&vm);

        // define and mock several variables for initialization
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();
        let custodian = address!("0xd8da6bf26964af9d7eed9e03e53415d37aa96045");
        let expected_currency_hash = Currency::NGN.to_string().hash();

        contract
            .initialize(
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
            )
            .unwrap();
        // whitelist certain custodians
        contract.whitelist_custodian(custodian, false).unwrap();

        // create a custodian by acting as the custodian
        vm.set_sender(custodian); // act as the custodian making this call
        assert!(contract
            .register_as_custodian(expected_currency_hash)
            .is_err());
    }

    #[test]
    fn whitelisted_custodian_can_be_created_and_removed() {
        let block_number = 15_000;
        let vm = TestVM::default();
        vm.set_block_number(block_number);
        let mut contract = DeltaManager::from(&vm);

        // define and mock several variables for initialization
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();

        let custodian = address!("0xd8da6bf26964af9d7eed9e03e53415d37aa96045");
        let second_custodian = address!("0xd8da6bf26964af9d7eed9e03e53415d37aa96046");
        let third_custodian = address!("0xd8da6bf26964af9d7eed9e03e53415d37aa96041");

        let expected_currency_hash = Currency::NGN.to_string().hash();

        contract
            .initialize(
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
                liquidity_verifier,
            )
            .unwrap();
        // whitelist certain custodians
        contract.whitelist_custodian(custodian, true).unwrap();
        contract
            .whitelist_custodian(second_custodian, true)
            .unwrap();
        contract.whitelist_custodian(third_custodian, true).unwrap();

        // create a custodian by acting as the custodian
        vm.set_sender(custodian); // act as the custodian making this call
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();

        // get the participant details for this currency hash
        let participants_for_currency = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants_for_currency.len(), 1);
        assert_eq!(participants_for_currency.get(0).unwrap(), custodian);

        // mock another custodian being created
        vm.set_sender(second_custodian);
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();
        // get the participant details for this currency hash
        let participants_for_currency = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants_for_currency.len(), 2);
        assert_eq!(participants_for_currency.get(1).unwrap(), second_custodian);

        // mock another custodian being created
        vm.set_sender(third_custodian);
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();
        // get the participant details for this currency hash
        let participants_for_currency = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants_for_currency.len(), 3);
        assert_eq!(participants_for_currency.get(2).unwrap(), third_custodian);

        // remove the first custodian and watch the participants list shrink
        vm.set_sender(custodian);
        contract.unregister_participant().unwrap();
        // get the participant details for this currency hash
        let participants_for_currency = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants_for_currency.len(), 2);

        // remove the last custodian and empty participants list
        vm.set_sender(second_custodian);
        contract.unregister_participant().unwrap();
        // get the participant details for this currency hash
        let participants_for_currency = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants_for_currency.len(), 1);

        // remove the last custodian and empty participants list
        vm.set_sender(third_custodian);
        contract.unregister_participant().unwrap();
        // get the participant details for this currency hash
        let participants_for_currency = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants_for_currency.len(), 0);
    }
}
