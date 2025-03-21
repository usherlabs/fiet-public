#[cfg(test)]
mod test {
    use fiet_liquidity_verifier::LiquidityManager;
    use stylus_sdk::testing::*;

    #[test]
    fn test_can_initialize_liquidity_manager() {
        let vm = TestVM::default();
        let mut contract = LiquidityManager::from(&vm);

        // define and mock several variables
        // set contracts to call as
        let sender_address = vm.msg_sender();
        let vrl_manager_address = sender_address.clone();

        // initialize the contract
        contract.initialize(vrl_manager_address).unwrap();

        let owner = contract.owner.get();
        let initialized = contract.initialized.get();

        assert!(initialized);
        assert_eq!(owner, sender_address);
    }
}
