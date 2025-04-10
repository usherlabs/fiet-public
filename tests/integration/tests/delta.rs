// SPDX-License-Identifier: MIT
// Copyright (c) 2025, Usher Labs
//
// This module contains integration tests for the Fiet Protocol's participant and delta
// management system, focusing on the creation and behavior of custodians, liquidity
// providers (LPs), and user VRL balances within an Arbitrum Stylus-compatible environment.
//
// Tests included:
// 1. `test_can_create_custodian_participant`: Ensures a custodian can be created and
//    registered as an active participant in the DeltaManager.
// 2. `test_can_create_lp_participant`: Verifies LP registration and active status
//    after meeting the minimum stake requirement.
// 3. `test_custodian_delta_can_increase`: Confirms a custodian's delta becomes more
//    negative when a user signals a deposit, and that the user receives the correct VRL.
// 4. `test_lp_delta_can_increase`: Checks that an LP’s delta is updated correctly when
//    signaling liquidity and that the LP receives matching VRL.
// 5. `test_lp_can_settle_delta_with_vrl`: Validates that LPs can settle negative delta
//    values using their VRL balance by burning VRL through the protocol.
// 6. `test_participants_can_unregister`: Verifies that both custodians and LPs can
//    successfully unregister and are marked as inactive participants.
//
// The tests use deterministic keypair generation with fixed seeds to ensure consistent
// addresses across runs. Core interactions include participant registration, signaling
// deposits, updating deltas, issuing VRL, settling with VRL, and unregistering.
//
// Key dependencies:
// - `ethers` crate for Ethereum contract calls and wallet generation.
// - `stylus_integration_test::utils` for contract helpers, transaction utilities,
//   configuration loading, and seeded wallet generation.
//
// Note: These tests assume a deployed contract environment with properly configured
// contract addresses and a funding mechanism for generated wallets.

#[cfg(test)]
mod test {
    use ethers::types::I256;
    use fiet_library::currency::Currency;
    use stylus_integration_test::utils::{
        config::Config,
        contracts::{ContractsHelper, KeyPair},
        helpers::value_in_wei,
        transactions::{create_custodian, create_lp},
    };

    // seeds to make sure the same custodian, lp and user addresses are generated for testing
    // to ensure deterministic generation of wallets
    const CUSTODIAN_SEED: Option<u64> = Some(1234567890);
    const LP_NGN_ONE_SEED: Option<u64> = Some(0987654321);
    const USER_NGN_ONE_SEED: Option<u64> = Some(1029384756);

    #[tokio::test]
    async fn test_can_create_custodian_participant() {
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper = ContractsHelper::new(&config);
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;

        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();

        // validate the custodian is a valid participant
        let delta_manager_contract = helper.get_delta_manager().await;
        let response = delta_manager_contract
            .is_active_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();

        assert!(response);
    }

    #[tokio::test]
    async fn test_can_create_lp_participant() {
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper = ContractsHelper::new(&config);
        let lp_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        create_lp(
            &mut helper,
            &lp_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        // validate this lp is active
        // validate the custodian is a valid participant
        let delta_manager_contract = helper.get_delta_manager().await;
        let response = delta_manager_contract
            .is_active_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();

        assert!(response);
    }

    #[tokio::test]
    async fn test_custodian_delta_can_increase() {
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let lp_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;
        let user_key_pair: KeyPair = helper.generate_funded_keypair(USER_NGN_ONE_SEED).await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        // create a custodian
        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();

        // create an lp
        create_lp(
            &mut helper,
            &lp_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        let liquidity_signal_verifier = helper.get_liquidity_verifier().await;
        let vrl_manager_contract = helper.get_vrl_manager().await;
        let delta_contract = helper.get_delta_manager().await;

        let custodian_delta_before_deposit = delta_contract
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let vrl_balance_before_deposit = vrl_manager_contract
            .get_user_currency_vrl(user_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();

        // make a deposit using the liquidity verifier
        let deposit_amount = value_in_wei(100);
        let expected_custodian_delta = -I256::try_from(deposit_amount).unwrap();

        liquidity_signal_verifier
            .manual_signal_deposit(
                user_key_pair.public_key,
                custodian_key_pair.public_key,
                Currency::NGN.to_string(),
                deposit_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // validate the deltas of the custodian increases accordingly
        let custodian_delta_after_deposit = delta_contract
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let vrl_balance_after_deposit = vrl_manager_contract
            .get_user_currency_vrl(user_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();

        assert_eq!(
            custodian_delta_after_deposit - custodian_delta_before_deposit,
            expected_custodian_delta
        );

        assert_eq!(
            vrl_balance_after_deposit - vrl_balance_before_deposit,
            deposit_amount
        );
        // validate that the VRL balance increases accordingly
    }

    #[tokio::test]
    async fn test_lp_delta_can_increase() {
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let lp_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        // create a custodian
        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();

        // create an lp
        create_lp(
            &mut helper,
            &lp_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        let liquidity_signal_verifier = helper.get_liquidity_verifier().await;
        let vrl_manager_contract = helper.get_vrl_manager().await;
        let delta_contract = helper.get_delta_manager().await;

        let lp_delta_before_deposit = delta_contract
            .delta_of_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();

        let vrl_balance_before_deposit = vrl_manager_contract
            .get_user_currency_vrl(lp_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();

        // make a deposit using the liquidity verifier
        let signal_amount = value_in_wei(100);
        let expected_lp_delta = -I256::try_from(signal_amount).unwrap();

        liquidity_signal_verifier
            .manual_signal_liquidity(
                lp_key_pair.public_key,
                Currency::NGN.to_string(),
                signal_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // validate the deltas of the custodian increases accordingly
        let lp_delta_after_deposit = delta_contract
            .delta_of_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let vrl_balance_after_deposit = vrl_manager_contract
            .get_user_currency_vrl(lp_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();

        assert_eq!(
            lp_delta_after_deposit - lp_delta_before_deposit,
            expected_lp_delta
        );

        assert_eq!(
            vrl_balance_after_deposit - vrl_balance_before_deposit,
            signal_amount
        );
    }

    #[tokio::test]
    async fn test_lp_can_settle_delta_with_vrl() {
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let lp_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        // create a custodian
        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();

        // create an lp
        create_lp(
            &mut helper,
            &lp_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        // get the relevant contracts from the helper function
        let liquidity_signal_verifier = helper.get_liquidity_verifier().await;
        let vrl_manager_contract = helper.get_vrl_manager().await;
        let delta_contract = helper.get_delta_manager().await;

        let lp_delta_before_deposit = delta_contract
            .delta_of_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();

        let vrl_balance_before_deposit = vrl_manager_contract
            .get_user_currency_vrl(lp_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();

        // signal a deposit using the liquidity verifier
        let signal_amount = value_in_wei(100);
        let expected_lp_delta = -I256::try_from(signal_amount).unwrap();

        liquidity_signal_verifier
            .manual_signal_liquidity(
                lp_key_pair.public_key,
                Currency::NGN.to_string(),
                signal_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // validate the deltas of the custodian increases accordingly
        let lp_delta_after_deposit = delta_contract
            .delta_of_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let vrl_balance_after_deposit = vrl_manager_contract
            .get_user_currency_vrl(lp_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();

        assert_eq!(
            lp_delta_after_deposit - lp_delta_before_deposit,
            expected_lp_delta
        );

        assert_eq!(
            vrl_balance_after_deposit - vrl_balance_before_deposit,
            signal_amount
        );

        // get delta before settlement
        let lp_delta_before_settlement = delta_contract
            .delta_of_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();

        // burn vrl for delta
        // can only be called by the LP so mock it using 'prank'
        helper.start_prank(&lp_key_pair.private_key);
        helper
            .get_delta_manager()
            .await
            .user_settle_delta(signal_amount)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();
        // can only be called by the LP so mock it using 'prank'

        let lp_delta_after_settlement = delta_contract
            .delta_of_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();

        assert_eq!(
            lp_delta_after_settlement - lp_delta_before_settlement,
            I256::try_from(signal_amount).unwrap()
        );

        println!("{}", lp_delta_before_settlement);
        println!("{}", lp_delta_after_settlement);
        // validate that delta has been settled
    }

    #[tokio::test]
    async fn test_participants_can_unregister() {
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let lp_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        // create a custodian
        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();

        // create an lp
        create_lp(
            &mut helper,
            &lp_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        // unregister custodian
        helper.start_prank(&custodian_key_pair.private_key);
        helper
            .get_delta_manager()
            .await
            .unregister_participant()
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        let custodian_is_active = helper
            .get_delta_manager()
            .await
            .is_active_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();

        assert!(!custodian_is_active);

        // unregister LP
        helper.start_prank(&lp_key_pair.private_key);
        helper
            .get_delta_manager()
            .await
            .unregister_participant()
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        let lp_is_active = helper
            .get_delta_manager()
            .await
            .is_active_participant(lp_key_pair.public_key)
            .call()
            .await
            .unwrap();

        assert!(!lp_is_active);
    }
}
