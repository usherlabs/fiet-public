// SPDX-License-Identifier: MIT
// Copyright (c) 2025, Usher Labs
//
// This module contains integration tests for the Fiet Protocol's RFS mechanism
//
// Tests included:
// 1. `test_can_create_and_completely_fill_rfs`: Ensures an RFS can be succesfully created and completely filled.
// 2. `test_can_create_and_partially_fill_rfs`: Verifies a custodian with a positive delta can open and partially fill an RFS.
// 3. `test_can_close_existing_rfs_for_custodian`: Confirms that any pending RFS for a custodian can be closed.
//
// The tests use deterministic keypair generation with fixed seeds to ensure consistent
// addresses across runs. Core interactions include creating an RFS, bidding in one
// and closing one.
//
// Key dependencies:
// - `ethers` crate for Ethereum contract calls and wallet generation.
// - `stylus_integration_test::utils` for contract helpers, transaction utilities,
//   configuration loading, and seeded wallet generation.

#[cfg(test)]
mod test {
    use ethers::types::{I256, U256};
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
    const LP_NGN_TWO_SEED: Option<u64> = Some(0987654322);
    const USER_NGN_ONE_SEED: Option<u64> = Some(1029384756);
    const UNISWAP_CONTRACT_MOCK_SEED: Option<u64> = Some(1114157749);

    #[tokio::test]
    async fn test_can_create_and_completely_fill_rfs() {
        //  get two LPS for the NGN currency pair
        //  get a custodian for the NGN currency pair
        //  get a random user who would want to withdraw some vrl

        //  signal some liquidity for both LP's
        //  find a way to get some vrl tokens to the user
        //  user withdraws to custodian
        //  custodian creates an RFS
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let lp_one_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;
        let lp_two_key_pair = helper.generate_funded_keypair(LP_NGN_TWO_SEED).await;
        let user_key_pair = helper.generate_funded_keypair(USER_NGN_ONE_SEED).await;
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;
        let uniswap_key_pair: KeyPair = helper
            .generate_funded_keypair(UNISWAP_CONTRACT_MOCK_SEED)
            .await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        // -------------------- Create custodians and LP
        // create a custodian
        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();
        // create an lp
        create_lp(
            &mut helper,
            &lp_one_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();
        // create another lp
        create_lp(
            &mut helper,
            &lp_two_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        // --------------------- Signal some liquidity as both LP1 and LP2
        // make a deposit using the liquidity verifier
        let lp_one_signal_amount = value_in_wei(100);

        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_liquidity(
                lp_one_key_pair.public_key,
                Currency::NGN.to_string(),
                lp_one_signal_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // make a deposit using the liquidity verifier
        let lp_two_signal_amount = value_in_wei(50);

        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_liquidity(
                lp_two_key_pair.public_key,
                Currency::NGN.to_string(),
                lp_two_signal_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // --------------------- Signal some liquidity as both LP1 and LP2

        // --------------------- lock and unlock VRL mocking uni hook contract
        // when a liquidity is signalled, some VRL is assigned to the signaller
        // the uniswap hook contract can lock and unlock some VRL to the user
        // mock the uniswap hook contract and call for the locking and unlocking
        let unlock_lock_delta = value_in_wei(20);
        helper.start_prank(&uniswap_key_pair.private_key);
        let user_vrl_before = helper
            .get_vrl_manager()
            .await
            .get_user_currency_vrl(user_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();
        // lock some vrl from LP one
        helper
            .get_vrl_manager()
            .await
            .lock_vrl(lp_one_key_pair.public_key, currency_hash, unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        // lock some vrl from one LP
        helper
            .get_vrl_manager()
            .await
            .lock_vrl(lp_two_key_pair.public_key, currency_hash, unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        // unlock some vrl to the user
        helper
            .get_vrl_manager()
            .await
            .unlock_vrl(user_key_pair.public_key, currency_hash, unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();
        // --------------------- lock and unlock VRL mocking uni hook contract
        // validate user VRL
        let user_vrl_after = helper
            .get_vrl_manager()
            .await
            .get_user_currency_vrl(user_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();
        assert_eq!(user_vrl_after - user_vrl_before, unlock_lock_delta);

        // ---------------------- user withdraws VRL by sending delta to custodian and burning vrl and emitting event
        let custodian_delta_before = helper
            .get_delta_manager()
            .await
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        helper.start_prank(&user_key_pair.private_key);
        let vrl_manager = helper.get_vrl_manager().await;
        vrl_manager
            .offramp(
                custodian_key_pair.public_key,
                currency_hash,
                unlock_lock_delta,
            )
            .send()
            .await
            .unwrap();
        helper.stop_prank();
        let custodian_delta_after = helper
            .get_delta_manager()
            .await
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let delta_diff = custodian_delta_after - custodian_delta_before;
        // validate the delta of the custodian has increased by 'unlock_lock_delta'
        assert_eq!(U256::try_from(delta_diff.abs()).unwrap(), unlock_lock_delta);

        // -------------------------------------------- custodian can use positive balance to start an RFS
        let custodian_delta_before_rfs = helper
            .get_delta_manager()
            .await
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let settle_amount = (unlock_lock_delta + 1) / 2;
        helper.start_prank(&custodian_key_pair.private_key);
        let settlement_manager = helper.get_settlement_manager().await;
        settlement_manager
            .create_request_for_settlement(unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        let rfs_id = settlement_manager
            .get_active_rfs(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        helper.stop_prank();
        // validate that the RFS has been started
        println!("Created an RFS with an id:{}", rfs_id);
        // make bid in this rfs as LP 1 and LP2 with half the amount each
        // lp1 bid
        helper.start_prank(&lp_one_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .bid(rfs_id, settle_amount)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();
        // lp2 bid
        helper.start_prank(&lp_two_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .bid(rfs_id, settle_amount)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        // LP1 and LP2 will Make deposits equivalent to their bids
        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_deposit(
                lp_one_key_pair.public_key,
                custodian_key_pair.public_key,
                Currency::NGN.to_string(),
                settle_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();
        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_deposit(
                lp_two_key_pair.public_key,
                custodian_key_pair.public_key,
                Currency::NGN.to_string(),
                settle_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // LP1 settle
        helper.start_prank(&lp_one_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .settle(rfs_id)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        // LP2 settle
        helper.start_prank(&lp_two_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .settle(rfs_id)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        helper.start_prank(&custodian_key_pair.private_key);
        let settlement_manager = helper.get_settlement_manager().await;
        settlement_manager
            .close_request_for_settlement()
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        // validate the delta of the custodian has changed by at least 'unlock_lock_delta' amount
        let custodian_delta_after_rfs = helper
            .get_delta_manager()
            .await
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();

        assert_eq!(
            custodian_delta_before_rfs - custodian_delta_after_rfs,
            I256::try_from(settle_amount * 2).unwrap() // Since there are two LP's
        );
    }

    #[tokio::test]
    async fn test_can_create_and_partially_fill_rfs() {
        //  get two LPS for the NGN currency pair
        //  get a custodian for the NGN currency pair
        //  get a random user who would want to withdraw some vrl

        //  signal some liquidity for both LP's
        //  find a way to get some vrl tokens to the user
        //  user withdraws to custodian
        //  custodian creates an RFS
        let config = Config::from_env();
        let currency_hash: [u8; 32] = Currency::NGN.hash().into();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let lp_one_key_pair = helper.generate_funded_keypair(LP_NGN_ONE_SEED).await;
        let lp_two_key_pair = helper.generate_funded_keypair(LP_NGN_TWO_SEED).await;
        let user_key_pair = helper.generate_funded_keypair(USER_NGN_ONE_SEED).await;
        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;
        let uniswap_key_pair: KeyPair = helper
            .generate_funded_keypair(UNISWAP_CONTRACT_MOCK_SEED)
            .await;

        let min_stake_amount = helper
            .get_stake_contract()
            .await
            .get_min_stake()
            .call()
            .await
            .unwrap();

        // -------------------- Create custodians and LP
        // create a custodian
        create_custodian(&mut helper, &custodian_key_pair, currency_hash)
            .await
            .unwrap();
        // create an lp
        create_lp(
            &mut helper,
            &lp_one_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();
        // create another lp
        create_lp(
            &mut helper,
            &lp_two_key_pair,
            currency_hash,
            min_stake_amount * 10,
        )
        .await
        .unwrap();

        // --------------------- Signal some liquidity as both LP1 and LP2
        // make a deposit using the liquidity verifier
        let lp_one_signal_amount = value_in_wei(100);

        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_liquidity(
                lp_one_key_pair.public_key,
                Currency::NGN.to_string(),
                lp_one_signal_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // make a deposit using the liquidity verifier
        let lp_two_signal_amount = value_in_wei(50);

        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_liquidity(
                lp_two_key_pair.public_key,
                Currency::NGN.to_string(),
                lp_two_signal_amount,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // --------------------- Signal some liquidity as both LP1 and LP2

        // --------------------- lock and unlock VRL mocking uni hook contract
        // when a liquidity is signalled, some VRL is assigned to the signaller
        // the uniswap hook contract can lock and unlock some VRL to the user
        // mock the uniswap hook contract and call for the locking and unlocking
        let unlock_lock_delta = value_in_wei(20);
        helper.start_prank(&uniswap_key_pair.private_key);
        let user_vrl_before = helper
            .get_vrl_manager()
            .await
            .get_user_currency_vrl(user_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();
        // lock some vrl from LP one
        helper
            .get_vrl_manager()
            .await
            .lock_vrl(lp_one_key_pair.public_key, currency_hash, unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        // lock some vrl from one LP
        helper
            .get_vrl_manager()
            .await
            .lock_vrl(lp_two_key_pair.public_key, currency_hash, unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        // unlock some vrl to the user
        helper
            .get_vrl_manager()
            .await
            .unlock_vrl(user_key_pair.public_key, currency_hash, unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();
        // --------------------- lock and unlock VRL mocking uni hook contract
        // validate user VRL
        let user_vrl_after = helper
            .get_vrl_manager()
            .await
            .get_user_currency_vrl(user_key_pair.public_key, currency_hash)
            .call()
            .await
            .unwrap();
        assert_eq!(user_vrl_after - user_vrl_before, unlock_lock_delta);

        // ---------------------- user withdraws VRL by sending delta to custodian and burning vrl and emitting event
        let custodian_delta_before = helper
            .get_delta_manager()
            .await
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        helper.start_prank(&user_key_pair.private_key);
        let vrl_manager = helper.get_vrl_manager().await;
        vrl_manager
            .offramp(
                custodian_key_pair.public_key,
                currency_hash,
                unlock_lock_delta,
            )
            .send()
            .await
            .unwrap();
        helper.stop_prank();
        let custodian_delta_after = helper
            .get_delta_manager()
            .await
            .delta_of_participant(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        let delta_diff = custodian_delta_after - custodian_delta_before;
        // validate the delta of the custodian has increased by 'unlock_lock_delta'
        assert_eq!(U256::try_from(delta_diff.abs()).unwrap(), unlock_lock_delta);

        // -------------------------------------------- custodian can use positive balance to start an RFS
        helper.start_prank(&custodian_key_pair.private_key);
        let settlement_manager = helper.get_settlement_manager().await;
        settlement_manager
            .create_request_for_settlement(unlock_lock_delta)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        let rfs_id = settlement_manager
            .get_active_rfs(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();
        helper.stop_prank();
        // validate that the RFS has been started
        println!("Created an RFS with an id:{}", rfs_id);
        // make bid in this rfs as LP 1 and LP2 with half the amount each
        // lp1 bid
        helper.start_prank(&lp_one_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .bid(rfs_id, (unlock_lock_delta + 1) / 2)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();
        // lp2 bid
        helper.start_prank(&lp_two_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .bid(rfs_id, (unlock_lock_delta + 1) / 2)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        // LP1 and LP2 will Make deposits equivalent to their bids
        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_deposit(
                lp_one_key_pair.public_key,
                custodian_key_pair.public_key,
                Currency::NGN.to_string(),
                (unlock_lock_delta + 1) / 2,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();
        helper
            .get_liquidity_verifier()
            .await
            .manual_signal_deposit(
                lp_two_key_pair.public_key,
                custodian_key_pair.public_key,
                Currency::NGN.to_string(),
                (unlock_lock_delta + 1) / 2,
            )
            .send()
            .await
            .unwrap()
            .await
            .unwrap();

        // LP1 settle
        helper.start_prank(&lp_one_key_pair.private_key);
        helper
            .get_settlement_manager()
            .await
            .settle(rfs_id)
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        let staking_contract = helper.get_stake_contract().await;
        // LP2 does not settle and will be slashed
        // get stake before
        let absent_participant_stake_before_slash = staking_contract
            .get_balance(lp_two_key_pair.public_key)
            .call()
            .await
            .unwrap();

        helper.start_prank(&custodian_key_pair.private_key);
        let settlement_manager = helper.get_settlement_manager().await;
        settlement_manager
            .close_request_for_settlement()
            .send()
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();
        helper.stop_prank();

        // get stake after
        let absent_participant_stake_after_slash = staking_contract
            .get_balance(lp_two_key_pair.public_key)
            .call()
            .await
            .unwrap();

        // confirm reduction in unparticipant's stake
        assert!(absent_participant_stake_after_slash < absent_participant_stake_before_slash)
        // validate the delta of the custodian has changed by at least 'unlock_lock_delta' amount
    }

    // if any tests fail and rfs is still open, use this to cleanup and close any existing rfs
    #[tokio::test]
    async fn test_can_close_existing_rfs_for_custodian() {
        let config = Config::from_env();
        let mut helper: ContractsHelper = ContractsHelper::new(&config);

        let custodian_key_pair: KeyPair = helper.generate_funded_keypair(CUSTODIAN_SEED).await;

        let rfs_id = helper
            .get_settlement_manager()
            .await
            .get_active_rfs(custodian_key_pair.public_key)
            .call()
            .await
            .unwrap();

        if rfs_id != 0 {
            println!("Closing rfs with id: {}", rfs_id);
            helper.start_prank(&custodian_key_pair.private_key);
            let settlement_manager = helper.get_settlement_manager().await;
            settlement_manager
                .close_request_for_settlement()
                .send()
                .await
                .unwrap()
                .await
                .unwrap()
                .unwrap();
            helper.stop_prank();
        }
    }
}
