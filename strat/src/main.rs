use alloy::dyn_abi::DynSolValue;
use alloy::network::EthereumWallet;
use alloy::primitives::{I256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::eth::TransactionRequest;
use alloy::sol_types::SolCall;
use clap::Parser;
use dotenv::dotenv;
use eyre::Result;
use log::info;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio::time::sleep;

mod constants;
use constants::{NetworkConstants, UniswapActions};

mod sol;
use sol::{compute_pool_id, get_pool_slot0, IPoolManager, IPositionManager, PositionInfoWrap};

mod liquidity;
use liquidity::{
    align_to_nearest_tick, get_amounts_for_liquidity, get_liquidity_for_amounts,
    get_sqrt_price_at_tick,
};

mod errors;

// CLI Arguments
#[derive(Parser, Debug)]
#[command(about = "Fiet Proxy Theory Experiment - Uniswap V4 Position Rebalancer Strategy")]
struct Args {
    #[arg(long, help = "Position token ID")]
    token_id: u64,

    #[arg(
        long,
        default_value = "10",
        help = "Threshold in ticks to trigger rebalance"
    )]
    threshold: u32,

    #[arg(
        long,
        default_value = "100",
        help = "Range width in ticks for new position"
    )]
    range_width: u32,

    #[arg(
        long,
        default_value = "arbitrum_sepolia",
        help = "Network to use (arbitrum, arbitrum_sepolia, eth_sepolia)"
    )]
    network: String,

    #[arg(long, help = "RPC URL (overrides network default)")]
    rpc_url: Option<String>,

    #[arg(
        long,
        help = "Private key for transaction signing (or set PRIVATE_KEY env var)"
    )]
    private_key: Option<String>,

    #[arg(long, default_value = "60", help = "Check interval in seconds")]
    interval: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    env_logger::init_from_env(env_logger::Env::default().default_filter_or("info"));

    // Load environment variables from .env file
    dotenv().ok();

    let args = Args::parse();
    info!("Starting Fiet pool position rebalancer strategy...");
    info!("Arguments: {:?}", args);

    // Get network constants based on network argument
    let network_constants = match args.network.as_str() {
        "arbitrum" => NetworkConstants::arbitrum(),
        "arbitrum_sepolia" => NetworkConstants::arbitrum_sepolia(),
        "eth_sepolia" => NetworkConstants::eth_sepolia(),
        _ => {
            return Err(eyre::eyre!(
                "Invalid network. Use: arbitrum, arbitrum_sepolia, or eth_sepolia"
            ))
        }
    };

    info!("Network constants: {:?}", network_constants);

    // Determine RPC URL: CLI arg > env var > network default
    let rpc_url = args
        .rpc_url
        .or_else(|| std::env::var("RPC_URL").ok())
        .unwrap_or_else(|| network_constants.rpc_url.to_string());

    log::debug!("RPC URL: {:?}", rpc_url);

    // Determine private key: CLI arg > env var
    let private_key = args
        .private_key
        .or_else(|| std::env::var("PRIVATE_KEY").ok())
        .ok_or_else(|| eyre::eyre!("Private key must be provided via --private-key or PRIVATE_KEY environment variable"))?;

    // Set up signer and provider
    let signer = private_key.parse::<alloy::signers::local::PrivateKeySigner>()?;
    let wallet = EthereumWallet::from(signer.clone());
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .connect_http(rpc_url.parse()?);

    let position_manager = IPositionManager::new(network_constants.position_manager, &provider);
    let pool_manager = IPoolManager::new(network_constants.pool_manager, &provider);

    let recipient = signer.address();
    info!("Recipient signer address: {:?}", recipient);

    let mut position_token_id = args.token_id;

    loop {
        // 1. Get position info
        let pool_and_position = position_manager
            .getPoolAndPositionInfo(U256::from(position_token_id))
            .call()
            .await?;

        // Check owner
        let owner = position_manager
            .ownerOf(U256::from(position_token_id))
            .call()
            .await?;
        info!("Position owner: {:?}", owner);
        if owner != recipient {
            return Err(eyre::eyre!("Signer {:?} is not the owner of tokenId {}, owner is {:?}. Please use the owner's private key or approve the signer.", recipient, position_token_id, owner));
        }

        let pool_key = pool_and_position.poolKey;
        let position_info = pool_and_position.info;

        // Compute poolId (bytes32 from pool_key hash)
        let pool_id = compute_pool_id(&pool_key); // works.

        info!("Pool ID: {:?}", pool_id);
        info!("Position info: {:?}", position_info);

        // Compute state_slot = keccak256(abi.encodePacked(pool_id, bytes32(uint256(6))))
        let slot0 = get_pool_slot0(&pool_manager, pool_id).await?;
        let current_tick = slot0.tick;
        let sqrt_price_x96 = slot0.sqrt_price_x96;

        info!("Current tick: {}", current_tick);

        // 3. Get tick bounds
        let position_info_wrapped = PositionInfoWrap(U256::from(position_info));
        let tick_lower: i32 = position_info_wrapped.tick_lower().try_into().unwrap();
        let tick_upper: i32 = position_info_wrapped.tick_upper().try_into().unwrap();
        info!("Position ticks: lower={}, upper={}", tick_lower, tick_upper);

        // 4. Check if rebalance needed
        let tick_lower_diff = (current_tick - tick_lower).abs();
        let tick_upper_diff = (tick_upper - current_tick).abs();
        info!(
            "Diffs: lower={}, upper={}",
            tick_lower_diff, tick_upper_diff
        );
        let should_rebalance =
            tick_lower_diff > args.threshold as i32 || tick_upper_diff > args.threshold as i32;
        if should_rebalance {
            info!("Rebalancing triggered. Threshold: {}", args.threshold);
            // Rebalancing position...
            info!("Rebalancing position...");

            // Get current liquidity
            let liquidity: u128 = position_manager
                .getPositionLiquidity(U256::from(position_token_id))
                .call()
                .await?
                .try_into()
                .unwrap();
            info!("Current liquidity: {}", liquidity);

            // Get current sqrt price
            // Removed: let sqrt_price_x96 = slot0.sqrtPriceX96;
            info!("Current sqrt_price_x96: {}", sqrt_price_x96);

            // Compute new ticks
            let tick_spacing: i32 = pool_key.tickSpacing.try_into().unwrap();
            let mut new_lower = current_tick - (args.range_width as i32) / 2;
            let mut new_upper = current_tick + (args.range_width as i32) / 2;

            log::debug!(
                "New ticks pre-alignment: lower={}, upper={}, tick_spacing={}",
                new_lower,
                new_upper,
                tick_spacing,
            );

            // Align to tick spacing
            new_lower = align_to_nearest_tick(new_lower, tick_spacing);
            new_upper = align_to_nearest_tick(new_upper, tick_spacing);

            // Clamp to min/max tick
            new_lower = new_lower.max(-887220);
            new_upper = new_upper.min(887220);
            info!("New ticks: lower={}, upper={}", new_lower, new_upper);

            // Compute amounts from old position
            let sqrt_lower_old = get_sqrt_price_at_tick(tick_lower)?;
            let sqrt_upper_old = get_sqrt_price_at_tick(tick_upper)?;
            let (amount0, amount1) = get_amounts_for_liquidity(
                U256::from(sqrt_price_x96),
                sqrt_lower_old,
                sqrt_upper_old,
                liquidity,
            )?;
            info!("Old amounts: amount0={}, amount1={}", amount0, amount1);

            // Compute new liquidity
            let sqrt_lower_new = get_sqrt_price_at_tick(new_lower)?;
            let sqrt_upper_new = get_sqrt_price_at_tick(new_upper)?;
            let new_liquidity = get_liquidity_for_amounts(
                U256::from(sqrt_price_x96),
                sqrt_lower_new,
                sqrt_upper_new,
                amount0,
                amount1,
            )?;
            info!("New liquidity: {}", new_liquidity);

            // Build actions
            let uniswap_actions = UniswapActions::new();
            let actions: Vec<u8> = vec![
                uniswap_actions.burn_position,
                uniswap_actions.mint_position,
                uniswap_actions.take_pair,
            ]; // BURN_POSITION, MINT_POSITION, TAKE_PAIR

            // Build params
            let mut params_encoded: Vec<Vec<u8>> = Vec::new();

            // Burn params: (uint256 tokenId, uint256 amount0Min, uint256 amount1Min, bytes hookData)
            let burn_tuple = vec![
                DynSolValue::Uint(U256::from(position_token_id), 256),
                DynSolValue::Uint(U256::ZERO, 256),
                DynSolValue::Uint(U256::ZERO, 256),
                DynSolValue::Bytes(vec![].into()),
            ];
            params_encoded.push(DynSolValue::Tuple(burn_tuple).abi_encode());

            // Mint params: (PoolKey key, int24 tickLower, int24 tickUpper, uint128 liquidityDelta, uint256 amount0Max, uint256 amount1Max, address owner, bytes hookData)
            let mint_tuple = vec![
                DynSolValue::Address(pool_key.currency0),
                DynSolValue::Address(pool_key.currency1),
                DynSolValue::Uint(U256::from(pool_key.fee), 24),
                DynSolValue::Int(I256::from(pool_key.tickSpacing), 24),
                DynSolValue::Address(pool_key.hooks),
                DynSolValue::Int(I256::try_from(new_lower).unwrap(), 24),
                DynSolValue::Int(I256::try_from(new_upper).unwrap(), 24),
                DynSolValue::Uint(U256::from(new_liquidity), 128),
                DynSolValue::Uint(amount0, 256),
                DynSolValue::Uint(amount1, 256),
                DynSolValue::Address(recipient),
                DynSolValue::Bytes(vec![].into()),
            ];
            params_encoded.push(DynSolValue::Tuple(mint_tuple).abi_encode());

            // Take pair params: (Currency currency0, Currency currency1, address receiver)
            let take_tuple = vec![
                DynSolValue::Address(pool_key.currency0),
                DynSolValue::Address(pool_key.currency1),
                DynSolValue::Address(recipient),
            ];
            params_encoded.push(DynSolValue::Tuple(take_tuple).abi_encode());

            // ? CREATE UNLOCK DATA ------------------------------------------------------------
            // Manually encode unlockData in strict format to match contract's decoder
            let actions_raw: Vec<u8> = actions.clone();
            let actions_len = actions_raw.len() as u64;
            let actions_padded_len = ((actions_len + 31) / 32) * 32;
            let params_len = params_encoded.len() as u64;

            // Compute relative offsets for params (relative to params.length position)
            let mut param_offset_values: Vec<U256> = Vec::new();
            let mut current = U256::from(params_len * 32);
            for p in &params_encoded {
                param_offset_values.push(current);
                let len = p.len() as u64;
                let padded = ((len + 31) / 32) * 32;
                current += U256::from(32 + padded);
            }

            // Build unlock_data Vec<u8>
            let mut unlock_data_vec: Vec<u8> = Vec::new();

            // word0: 0x40
            unlock_data_vec.extend_from_slice(&U256::from(0x40u64).to_be_bytes::<32>());

            // word1: params_length_offset = 0x60 + actions_padded_len
            let params_length_offset = 0x60u64 + actions_padded_len;
            unlock_data_vec
                .extend_from_slice(&U256::from(params_length_offset).to_be_bytes::<32>());

            // word2: actions_len
            unlock_data_vec.extend_from_slice(&U256::from(actions_len).to_be_bytes::<32>());

            // actions data + padding
            unlock_data_vec.extend(&actions_raw);
            let current_size = unlock_data_vec.len();
            unlock_data_vec.resize(
                current_size + (actions_padded_len - actions_len) as usize,
                0,
            );

            // params.length
            unlock_data_vec.extend_from_slice(&U256::from(params_len).to_be_bytes::<32>());

            // params offsets
            for off in param_offset_values {
                unlock_data_vec.extend_from_slice(&off.to_be_bytes::<32>());
            }

            // params tails
            for p in &params_encoded {
                let len = p.len() as u64;
                unlock_data_vec.extend_from_slice(&U256::from(len).to_be_bytes::<32>());
                unlock_data_vec.extend(p);
                let current_len = 32 + p.len();
                let target_len = 32 + ((p.len() + 31) / 32) * 32;
                unlock_data_vec.resize(unlock_data_vec.len() + (target_len - current_len), 0);
            }

            let unlock_data = unlock_data_vec;
            // CREATE UNLOCK DATA ------------------------------------------------------------

            // Get current timestamp for deadline
            let current_timestamp = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs();
            let deadline = current_timestamp + 3600;

            let call = IPositionManager::modifyLiquiditiesCall {
                unlockData: unlock_data.clone().into(),
                deadline: U256::from(deadline),
            };
            let mut tx = TransactionRequest::default()
                .to(network_constants.position_manager)
                .input(call.abi_encode().into());
            tx.gas = Some(10_000_000);

            log::debug!(
                "ModifyLiquidities calldata: 0x{}",
                hex::encode(call.abi_encode())
            );

            // Build and send transaction
            let send_result = provider.send_transaction(tx).await;
            let pending_tx = match send_result {
                Ok(ptx) => ptx,
                Err(err) => {
                    info!("Transaction send failed: {}", err);
                    return Err(err.into());
                }
            };
            let receipt = pending_tx.get_receipt().await?;
            if !receipt.status() {
                // ! This is not reached as the error occurs in the prior RpcError block...
                // info!("Transaction reverted on-chain");
                // let unlock_data_clone = unlock_data.clone();
                // if let Err(sim_err) = position_manager
                //     .modifyLiquidities(unlock_data_clone.into(), U256::from(deadline))
                //     .call()
                //     .await
                // {
                //     if let Some(revert_data) = sim_err.as_revert_data() {
                //         let error_msg = errors::parse_revert_error(revert_data.to_vec().as_slice());
                //         info!("Revert reason: {}", error_msg);
                //         return Err(eyre::eyre!("Transaction reverted: {}", error_msg));
                //     } else {
                //         info!("Simulation error: {}", sim_err);
                //         return Err(sim_err.into());
                //     }
                // } else {
                //     return Err(eyre::eyre!(
                //         "Transaction reverted but simulation succeeded - state changed?"
                //     ));
                // }
            }

            // Parse logs for new token ID
            let transfer_topic =
                alloy::primitives::keccak256("Transfer(address,address,uint256)".as_bytes());
            let mut new_token_id_opt = None;
            for log in receipt.logs().iter() {
                let topics = log.topics();
                if topics.len() == 3
                    && topics[0] == transfer_topic
                    && log.address() == network_constants.position_manager
                {
                    let from = alloy::primitives::Address::from_word(topics[1]);
                    let to = alloy::primitives::Address::from_word(topics[2]);
                    let token_id = log.data().data.to_vec();
                    if from == alloy::primitives::Address::ZERO && to == recipient {
                        new_token_id_opt = Some(U256::from_be_slice(&token_id));
                        break;
                    }
                }
            }

            if let Some(new_id) = new_token_id_opt {
                position_token_id = new_id.to::<u64>();
                info!("New position token ID: {}", new_id);
                info!("Rebalance completed. New token ID: {}", position_token_id);
            } else {
                info!("Warning: Could not find new token ID in logs");
            }

            info!("Rebalance transaction confirmed: {:?}", receipt);
        } else {
            info!("Position within bounds.");
        }

        sleep(Duration::from_secs(args.interval)).await;
    }
}

#[cfg(test)]
mod tests {
    // use super::*;

    #[test]
    fn test_should_rebalance() {
        let current_tick = 100i32;
        let tick_lower = 50i32;
        let tick_upper = 150i32;
        let threshold = 30u32;

        let tick_lower_diff = (current_tick - tick_lower).abs();
        let tick_upper_diff = (tick_upper - current_tick).abs();
        let should = tick_lower_diff > threshold as i32 || tick_upper_diff > threshold as i32;
        assert!(should); // abs(100-50)=50 >30, yes

        // Another case inside bounds
        let tick_lower = 80i32;
        let tick_upper = 120i32;
        let tick_lower_diff = (current_tick - tick_lower).abs();
        let tick_upper_diff = (tick_upper - current_tick).abs();
        let should_not = tick_lower_diff > threshold as i32 || tick_upper_diff > threshold as i32;
        assert!(!should_not); // 20 <30, 20<30
    }

    #[test]
    fn test_new_tick_calculation() {
        let current_tick = 100i32;
        let range_width = 100u32;
        let tick_spacing = 10i32;

        let mut new_lower = current_tick - (range_width as i32) / 2;
        let mut new_upper = current_tick + (range_width as i32) / 2;
        new_lower = (new_lower / tick_spacing) * tick_spacing;
        new_upper = (new_upper / tick_spacing) * tick_spacing;
        new_lower = new_lower.max(-887220);
        new_upper = new_upper.min(887220);

        assert_eq!(new_lower, 50);
        assert_eq!(new_upper, 150);
    }
}
