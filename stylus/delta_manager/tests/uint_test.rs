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

        // Mock initialization variables
        let sender_address = vm.msg_sender();
        let liquidity_verifier = sender_address.clone();

        // Initialize the contract
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

        // Mock initialization variables
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

        // Whitelist custodian
        contract.whitelist_custodian(custodian, true).unwrap();
        let custodian_is_whitelisted = contract.is_custodian.get(custodian);
        assert!(custodian_is_whitelisted);

        // Blacklist the custodian
        contract.whitelist_custodian(custodian, false).unwrap();
        let custodian_is_whitelisted = contract.is_custodian.get(custodian);
        assert!(!custodian_is_whitelisted);
    }

    #[test]
    fn whitelisted_custodian_can_be_created() {
        let block_number = 15_000;
        let vm = TestVM::default();
        vm.set_block_number(block_number);
        let mut contract = DeltaManager::from(&vm);

        // Mock initialization variables
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

        // Whitelist custodian
        contract.whitelist_custodian(custodian, true).unwrap();

        // Register as a custodian (call made from custodian address)
        vm.set_sender(custodian);
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();

        // Verify participant was registered
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

        // Mock initialization variables
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

        // Ensure custodian is blacklisted
        contract.whitelist_custodian(custodian, false).unwrap();

        // Attempt to register as a custodian from a blacklisted address
        vm.set_sender(custodian);
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

        // Mock initialization variables
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

        // Whitelist all custodians
        contract.whitelist_custodian(custodian, true).unwrap();
        contract.whitelist_custodian(second_custodian, true).unwrap();
        contract.whitelist_custodian(third_custodian, true).unwrap();

        // Register first custodian
        vm.set_sender(custodian);
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();
        let mut participants = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants.len(), 1);
        assert_eq!(participants.get(0).unwrap(), custodian);

        // Register second custodian
        vm.set_sender(second_custodian);
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();
        participants = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants.len(), 2);
        assert_eq!(participants.get(1).unwrap(), second_custodian);

        // Register third custodian
        vm.set_sender(third_custodian);
        contract
            .register_as_custodian(expected_currency_hash)
            .unwrap();
        participants = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants.len(), 3);
        assert_eq!(participants.get(2).unwrap(), third_custodian);

        // Remove first custodian
        vm.set_sender(custodian);
        contract.unregister_participant().unwrap();
        participants = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants.len(), 2);

        // Remove second custodian
        vm.set_sender(second_custodian);
        contract.unregister_participant().unwrap();
        participants = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants.len(), 1);

        // Remove last custodian, leaving the list empty
        vm.set_sender(third_custodian);
        contract.unregister_participant().unwrap();
        participants = contract.participants_of.get(expected_currency_hash);
        assert_eq!(participants.len(), 0);
    }
}
