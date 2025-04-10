use super::{
    contracts::{ContractsHelper, KeyPair},
    helpers::hex_to_address,
};
use ethers::types::{Address, U256};
use std::error::Error;

pub async fn mint(
    contracts: &ContractsHelper,
    mint_amount: U256,
    to: Address,
) -> Result<(), Box<dyn Error>> {
    contracts
        .get_erc20token_contract()
        .await
        .mint_to(to, mint_amount)
        .send()
        .await?
        .await?;

    return Ok(());
}

pub async fn stake(contracts: &ContractsHelper, stake_amount: U256) -> Result<(), Box<dyn Error>> {
    // approve the staking contract to take 'stake_amount' tokens
    contracts
        .get_erc20token_contract()
        .await
        .approve(hex_to_address(&contracts.contracts.fiet_stake), U256::MAX)
        .send()
        .await?
        .await?;

    // stake the specified amount using the staking contract
    contracts
        .get_stake_contract()
        .await
        .stake(stake_amount)
        .send()
        .await?
        .await?;

    return Ok(());
}

pub async fn create_custodian(
    helper: &mut ContractsHelper,
    custodian_key_pair: &KeyPair,
    currency_hash: [u8; 32],
) -> Result<(), Box<dyn Error>> {
    // in order to create a custodian
    // an admin has to whitelist the custodian
    helper
        .get_delta_manager()
        .await
        .whitelist_custodian(custodian_key_pair.public_key, true)
        .send()
        .await?
        .await?;

    // we will then register as a custodian by having them make the registeration request
    helper.start_prank(&custodian_key_pair.private_key);
    helper
        .get_delta_manager()
        .await
        .register_as_custodian(currency_hash)
        .send()
        .await?
        .await?;
    helper.stop_prank();

    return Ok(());
}

pub async fn create_lp(
    helper: &mut ContractsHelper,
    lp_key_pair: &KeyPair,
    currency_hash: [u8; 32],
    stake_amount: U256
) -> Result<(), Box<dyn Error>> {
    helper.start_prank(&lp_key_pair.private_key);
    // in order to create an LP
    // a stake must be made
    // get the minstake amount and stake that
    // make sure you stake on the staking contract
    stake(&helper, stake_amount).await.unwrap();
    // register as an lp
    helper
        .get_delta_manager()
        .await
        .register_as_lp(currency_hash)
        .send()
        .await
        .unwrap()
        .await
        .unwrap();
    helper.stop_prank();
    return Ok(());
}
