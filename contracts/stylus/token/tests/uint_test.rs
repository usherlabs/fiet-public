#[cfg(test)]
mod test {
    use alloy_primitives::U256;
    use fiet_token::FietToken;
    use stylus_sdk::testing::*;

    #[test]
    fn test_can_initialize_liquidity_manager() {
        let vm = TestVM::default();
        let mut contract = FietToken::from(&vm);

        // define and mock several variables
        // set contracts to call as
        let sender_address = vm.msg_sender();

        // initialize the contract
        contract.initialize().unwrap();

        let owner = contract.owner.get();
        let initialized = contract.initialized.get();

        assert!(initialized);
        assert_eq!(owner, sender_address);
    }

    #[test]
    fn test_can_mint_token() {
        let vm = TestVM::default();
        let sender_address = vm.msg_sender();
        let mut contract = FietToken::from(&vm);
        let mint_amount = U256::from(10).pow(U256::from(18));

        // initialize the contract
        contract.initialize().unwrap();

        let initial_total_supply = contract.erc20.total_supply();
        // mint some tokens
        let _ = contract.mint(mint_amount);

        let final_total_supply = contract.erc20.total_supply();
        let sender_balance = contract.erc20.balance_of(sender_address);

        assert_eq!(sender_balance, mint_amount);
        assert_eq!(mint_amount, final_total_supply - initial_total_supply);
    }

    #[test]
    fn test_can_burn_token() {
        let vm = TestVM::default();
        let sender_address = vm.msg_sender();
        let mut contract = FietToken::from(&vm);

        let mint_amount = U256::from(10).pow(U256::from(18));
        let zero_amount = U256::from(0);

        // initialize the contract
        contract.initialize().unwrap();

        // mint some tokens
        let _ = contract.mint(mint_amount);
        // burn some tokens
        let _ = contract.burn(mint_amount);

        let final_total_supply = contract.erc20.total_supply();
        let sender_balance = contract.erc20.balance_of(sender_address);

        assert_eq!(sender_balance, zero_amount);
        assert_eq!(final_total_supply, zero_amount);
    }
}
