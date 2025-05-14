// SPDX-License-Identifier: MIT
// Copyright (c) 2025, Usher Labs
//
// This module contains integration tests for the Fiet Protocol's staking functionality,
// specifically interacting with an ERC-20 token contract and a staking contract deployed
// on an Arbitrum Stylus-compatible environment. The tests verify core user flows:
// staking tokens, unstaking tokens, and admin withdrawal of slashed tokens.
//
// Tests included:
// 1. `test_user_can_stake_fiet`: Verifies a user can stake FIET tokens, including minting,
//    approving the staking contract, staking half the minted amount, and checking balances.
// 2. `test_user_can_unstake_fiet`: Ensures a user can unstake FIET tokens, testing the full
//    cycle of minting, staking, unstaking a portion, and validating balance updates.
// 3. `test_admin_can_withdraw_slashed_tokens`: Confirms an admin can slash a user's staked
//    tokens (10% via BPS) and withdraw the slashed amount to a recipient address.
// 4. `test_user_can_delegate_fiet`: Delegate and undelegate fiet to a third party user
//
// The tests use the `ethers` crate for Ethereum interactions, `tokio` for async operations,
// and a custom `stylus_integration_test::utils` module for configuration and contract helpers.
// Each test follows a similar pattern:
// 1. Load configuration from environment variables (e.g., deployer address, contract addresses).
// 2. Initialize contract instances (token and staking contracts).
// 3. Perform actions (mint, approve, stake, unstake, slash, withdraw).
// 4. Verify state changes via assertions on balances and allowances.
//
// Key dependencies:
// - `ethers::types::U256` for large integer handling (e.g., token amounts).
// - `stylus_integration_test::utils` for test utilities (Config, ContractsHelper).
//
// Note: These tests assume a deployed environment with pre-configured contract addresses
// and a deployer account with sufficient privileges.

#[cfg(test)]
mod test {

    use ethers::types::U256;
    use stylus_integration_test::utils::{
        config::Config,
        contracts::ContractsHelper,
        helpers::{hex_to_address, value_in_wei},
    };

    #[tokio::test]
    async fn test_user_can_stake_fiet() {
        let config = Config::from_env();
        let sender = config.public_key;

        // get the token contracts
        let contracts = ContractsHelper::new(&config);
        let token_contract = contracts.get_erc20token_contract().await;
        let stake_contract = contracts.get_stake_contract().await;

        let fiet_stake_contract_address = hex_to_address(&config.deployed_contracts.fiet_stake);

        //  verify the decimals
        let token_decimals: u8 = token_contract.decimals().call().await.unwrap();
        let expected_token_decimals = 18;
        assert_eq!(token_decimals, expected_token_decimals);

        let mint_amount = value_in_wei(10);
        let old_balance = token_contract.balance_of(sender).call().await.unwrap();
        // --------------------- mint some tokens for some users
        let pending = token_contract.mint(mint_amount);
        pending.send().await.unwrap().await.unwrap().unwrap();
        // have user stake said token

        // ---------------------- amount has been minted
        let new_balance = token_contract.balance_of(sender).call().await.unwrap();
        assert_eq!(mint_amount, new_balance - old_balance);

        // ---------------------- approve staking contract
        token_contract
            .approve(fiet_stake_contract_address, U256::MAX)
            .send()
            .await
            .unwrap()
            .await
            .unwrap();
        let new_allowance = token_contract
            .allowance(sender, fiet_stake_contract_address)
            .call()
            .await
            .unwrap();
        assert_eq!(new_allowance, U256::MAX);

        // ---------------------- stake on the staking contract
        let stake_contract_fiet_balance = token_contract
            .balance_of(fiet_stake_contract_address)
            .call()
            .await
            .unwrap();
        let user_stake = stake_contract.get_balance(sender).call().await.unwrap();
        let stake_amount = mint_amount / 2;
        stake_contract.stake(stake_amount).send().await.unwrap();

        // --------------------- verify the stake was successfull by checking token balance of user and contract  to verify token was succesfully transferred
        let balance_post_stake = token_contract.balance_of(sender).call().await.unwrap();
        let stake_contract_fiet_balance_post_stake = token_contract
            .balance_of(fiet_stake_contract_address)
            .call()
            .await
            .unwrap();
        let user_stake_post_stake = stake_contract.get_balance(sender).call().await.unwrap();

        // verify balances on staking contract and of token contract
        assert_eq!(stake_amount, new_balance - balance_post_stake);
        assert_eq!(
            stake_amount,
            stake_contract_fiet_balance_post_stake - stake_contract_fiet_balance
        );
        assert_eq!(stake_amount, user_stake_post_stake - user_stake);
    }

    #[tokio::test]
    async fn test_user_can_unstake_fiet() {
        // get the config object
        let config = Config::from_env();
        let sender = config.public_key;

        // get the contracts
        let contracts = ContractsHelper::new(&config);
        let token_contract = contracts.get_erc20token_contract().await;
        let stake_contract = contracts.get_stake_contract().await;

        let fiet_stake_contract_address = hex_to_address(&config.deployed_contracts.fiet_stake);

        // --------------------- Mint tokens
        let mint_amount = value_in_wei(10);
        let stake_amount = mint_amount / 2;

        let pending = token_contract.mint(mint_amount);
        pending.send().await.unwrap().await.unwrap().unwrap();

        // ---------------------- Approve staking contract
        token_contract
            .approve(fiet_stake_contract_address, U256::MAX)
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // ----------------------- Stake on contract
        stake_contract.stake(stake_amount).send().await.unwrap();

        // ----------------------- Unstake on contract
        let unstake_amount = stake_amount / 2;

        // token balance pre and post stake
        let sender_token_balance = token_contract.balance_of(sender).call().await.unwrap();
        let contract_token_balance = token_contract
            .balance_of(fiet_stake_contract_address)
            .call()
            .await
            .unwrap();

        let sender_stake_balance = stake_contract.get_balance(sender).call().await.unwrap();

        stake_contract
            .unstake(unstake_amount)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();

        // token balance pre and post stake
        let sender_token_balance_post = token_contract.balance_of(sender).call().await.unwrap();
        let contract_token_balance_post = token_contract
            .balance_of(fiet_stake_contract_address)
            .call()
            .await
            .unwrap();

        let sender_stake_balance_post = stake_contract.get_balance(sender).call().await.unwrap();

        // confirm that the user balance increased by token amount post stake
        assert_eq!(
            sender_token_balance + unstake_amount,
            sender_token_balance_post
        );
        assert_eq!(
            contract_token_balance - unstake_amount,
            contract_token_balance_post
        );
        assert_eq!(
            sender_stake_balance - unstake_amount,
            sender_stake_balance_post
        );
    }

    #[tokio::test]
    async fn test_admin_can_withdraw_slashed_tokens() {
        let config = Config::from_env();
        let sender = config.public_key;
        let recipient = hex_to_address(&"0x60500535A90b3E2F459A66591DAab0bAC86ee515".to_string());

        // get the token contracts
        let contracts = ContractsHelper::new(&config);
        let token_contract = contracts.get_erc20token_contract().await;
        let stake_contract = contracts.get_stake_contract().await;
        let fiet_stake_contract_address = hex_to_address(&config.deployed_contracts.fiet_stake);

        let mint_amount = value_in_wei(10);
        // --------------------- mint some tokens for some users
        let pending = token_contract.mint(mint_amount);
        pending.send().await.unwrap().await.unwrap().unwrap();
        // ---------------------- approve staking contract
        token_contract
            .approve(fiet_stake_contract_address, U256::MAX)
            .send()
            .await
            .unwrap()
            .await
            .unwrap();
        // ---------------------- stake on the staking contract
        let stake_amount = mint_amount / 2;
        stake_contract.stake(stake_amount).send().await.unwrap();

        // ---------------------- slash some of the staked tokens
        let bps = U256::from(1000); //10% == 1000BPS
        let expected_slash_amount = stake_contract.get_slash_amount(bps).call().await.unwrap();

        // let expected_slash_amount = stake_contract.get_slash_amount();
        stake_contract
            .slash(sender, bps)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();

        // ---------------------- verify the slash of the tokens as belonging to the contract
        let recipient_balance_pre = token_contract.balance_of(recipient).call().await.unwrap();

        // withdraw the slashed amount that should belong to the contract
        stake_contract
            .withdraw(expected_slash_amount, recipient)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();

        let recipient_balance_post = token_contract.balance_of(recipient).call().await.unwrap();

        // validate that the token balance of the user has increased by the slash amount that was withdrawn to the address
        assert_eq!(
            recipient_balance_pre + expected_slash_amount,
            recipient_balance_post
        );
    }

    #[tokio::test]
    async fn test_user_can_delegate_fiet() {
        let config = Config::from_env();
        let sender = config.public_key;

        // get the token contracts
        let contracts = ContractsHelper::new(&config);
        let token_contract = contracts.get_erc20token_contract().await;
        let stake_contract = contracts.get_stake_contract().await;

        let fiet_stake_contract_address = hex_to_address(&config.deployed_contracts.fiet_stake);

        //  verify the decimals
        let token_decimals: u8 = token_contract.decimals().call().await.unwrap();
        let expected_token_decimals = 18;
        assert_eq!(token_decimals, expected_token_decimals);

        let mint_amount = value_in_wei(10);
        let old_balance = token_contract.balance_of(sender).call().await.unwrap();
        // --------------------- mint some tokens for some users
        let pending = token_contract.mint(mint_amount);
        pending.send().await.unwrap().await.unwrap().unwrap();
        // have user stake said token

        // ---------------------- amount has been minted
        let new_balance = token_contract.balance_of(sender).call().await.unwrap();
        assert_eq!(mint_amount, new_balance - old_balance);

        // ---------------------- approve staking contract
        token_contract
            .approve(fiet_stake_contract_address, U256::MAX)
            .send()
            .await
            .unwrap()
            .await
            .unwrap();
        let new_allowance = token_contract
            .allowance(sender, fiet_stake_contract_address)
            .call()
            .await
            .unwrap();
        assert_eq!(new_allowance, U256::MAX);

        // ---------------------- stake on the staking contract
        let stake_amount = mint_amount / 2;
        stake_contract.stake(stake_amount).send().await.unwrap();

        // ----------------------- delegate stake to another user
        let delegatee_user = contracts.generate_funded_keypair(Some(2223)).await;
        stake_contract
            .delegate_stake(delegatee_user.public_key)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        // ----------------------- validate this new user is staked by way of delegation
        let is_staked = stake_contract
            .is_staked(delegatee_user.public_key)
            .call()
            .await
            .unwrap();
        assert!(is_staked);

        // ----------------------- undelegate the user
        stake_contract
            .remove_stake_delegate()
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();

        // ----------------------- validate this new user is staked by way of delegation
        let is_staked = stake_contract
            .is_staked(delegatee_user.public_key)
            .call()
            .await
            .unwrap();
        assert!(!is_staked);
    }
}
