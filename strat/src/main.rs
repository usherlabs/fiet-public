use alloy::dyn_abi::DynSolValue;
use alloy::network::EthereumWallet;
use alloy::primitives::{I256, U256};
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::eth::TransactionRequest;
use alloy::sol_types::SolCall;
use clap::Parser;
use dotenv::dotenv;
use eyre::Result;
use std::time::Duration;
use tokio::time::sleep;

mod constants;
use constants::{NetworkConstants, UniswapActions};

mod sol;
use sol::{compute_pool_id, IPoolManager, IPositionManager, PositionInfoWrap};

mod liquidity;
use liquidity::{get_amounts_for_liquidity, get_liquidity_for_amounts, get_sqrt_price_at_tick};

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
    // Load environment variables from .env file
    dotenv().ok();

    let args = Args::parse();

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

    // Determine RPC URL: CLI arg > env var > network default
    let rpc_url = args
        .rpc_url
        .or_else(|| std::env::var("RPC_URL").ok())
        .unwrap_or_else(|| network_constants.rpc_url.to_string());

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

    let mut position_token_id = args.token_id;

    loop {
        // 1. Get position info
        let pool_and_position = position_manager
            .getPoolAndPositionInfo(U256::from(position_token_id))
            .call()
            .await?;

        let pool_key = pool_and_position.poolKey;
        let position_info = pool_and_position.info;

        // Compute poolId (bytes32 from pool_key hash)
        let pool_id = compute_pool_id(&pool_key);

        println!("Pool ID: {:?}", pool_id);

        // 2. Get current tick
        let slot0 = pool_manager.getSlot0(pool_id).call().await?;
        let current_tick: i32 = slot0.tick.try_into().unwrap();

        // 3. Get tick bounds
        let position_info_wrapped = PositionInfoWrap(U256::from(position_info));
        let tick_lower: i32 = position_info_wrapped.tick_lower().try_into().unwrap();
        let tick_upper: i32 = position_info_wrapped.tick_upper().try_into().unwrap();

        // 4. Check if rebalance needed
        let tick_lower_diff = (current_tick - tick_lower).abs();
        let tick_upper_diff = (tick_upper - current_tick).abs();
        let should_rebalance =
            tick_lower_diff > args.threshold as i32 || tick_upper_diff > args.threshold as i32;
        if should_rebalance {
            // Rebalancing position...
            println!("Rebalancing position...");

            // Get current liquidity
            let liquidity: u128 = position_manager
                .getPositionLiquidity(U256::from(position_token_id))
                .call()
                .await?
                .try_into()
                .unwrap();

            // Get current sqrt price
            let sqrt_price_x96 = slot0.sqrtPriceX96;

            // Compute new ticks
            let tick_spacing: i32 = pool_key.tickSpacing.try_into().unwrap();
            let mut new_lower = current_tick - (args.range_width as i32) / 2;
            let mut new_upper = current_tick + (args.range_width as i32) / 2;

            // Align to tick spacing
            new_lower = (new_lower / tick_spacing) * tick_spacing;
            new_upper = (new_upper / tick_spacing) * tick_spacing;

            // Clamp to min/max tick
            new_lower = new_lower.max(-887220);
            new_upper = new_upper.min(887220);

            // Compute amounts from old position
            let sqrt_lower_old = get_sqrt_price_at_tick(tick_lower)?;
            let sqrt_upper_old = get_sqrt_price_at_tick(tick_upper)?;
            let (amount0, amount1) = get_amounts_for_liquidity(
                U256::from(sqrt_price_x96),
                sqrt_lower_old,
                sqrt_upper_old,
                liquidity,
            )?;

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

            // Encode unlockData = abi.encode(actions, params)
            let actions_dyn = DynSolValue::Bytes(actions.into());
            let params_dyn = DynSolValue::Array(
                params_encoded
                    .into_iter()
                    .map(|p| DynSolValue::Bytes(p.into()))
                    .collect(),
            );
            let unlock_tuple = vec![actions_dyn, params_dyn];
            let unlock_data = DynSolValue::Tuple(unlock_tuple).abi_encode();

            // Get current timestamp for deadline
            let block = provider
                .get_block_by_number(alloy::rpc::types::eth::BlockNumberOrTag::Latest)
                .await?
                .unwrap();
            let current_timestamp = block.header.timestamp;
            let deadline = current_timestamp + 3600;

            // Build and send transaction
            let call = IPositionManager::modifyLiquiditiesCall {
                unlockData: unlock_data.into(),
                deadline: U256::from(deadline),
            };
            let tx = TransactionRequest::default()
                .to(network_constants.position_manager)
                .input(call.abi_encode().into());
            let pending_tx = provider.send_transaction(tx).await?;
            let receipt = pending_tx.get_receipt().await?;

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
                println!("New position token ID: {}", new_id);
            } else {
                println!("Warning: Could not find new token ID in logs");
            }

            println!("Rebalance transaction confirmed: {:?}", receipt);
        } else {
            println!("Position within bounds.");
        }

        sleep(Duration::from_secs(args.interval)).await;
    }
}
