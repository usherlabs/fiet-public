use alloy::primitives::U256;
use alloy::providers::{Provider, ProviderBuilder};
use alloy::rpc::types::eth::TransactionRequest;
use alloy::sol_types::SolCall;
use clap::Parser;
use dotenv::dotenv;
use eyre::Result;
use std::time::Duration;
use tokio::time::sleep;

mod constants;
use constants::NetworkConstants;

mod sol;
use sol::{compute_pool_id, IPoolManager, IPositionManager, PositionInfo};

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
    threshold: i32,

    #[arg(
        long,
        default_value = "100",
        help = "Range width in ticks for new position"
    )]
    range_width: i32,

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

    // Set up provider
    let provider = ProviderBuilder::new().on_http(rpc_url.parse()?);

    let position_manager = IPositionManager::new(network_constants.position_manager, &provider);
    let pool_manager = IPoolManager::new(network_constants.pool_manager, &provider);

    loop {
        // 1. Get position info
        let pool_and_position = position_manager
            .getPoolAndPositionInfo(U256::from(args.token_id))
            .call()
            .await?;

        let pool_key = pool_and_position.poolKey;
        let position_info = pool_and_position.info;

        // Compute poolId (bytes32 from pool_key hash)
        let pool_id = compute_pool_id(&pool_key);

        println!("Pool ID: {:?}", pool_id);

        // 2. Get current tick
        let slot0 = pool_manager.getSlot0(pool_id).call().await?;
        let current_tick = slot0.tick; // Extract tick from slot0

        // 3. Get tick bounds
        let position_info_wrapped = PositionInfo(position_info);
        let tick_lower = position_info_wrapped.tick_lower();
        let tick_upper = position_info_wrapped.tick_upper();

        // 4. Check if rebalance needed
        let should_rebalance = ((current_tick - tick_lower).abs() > args.threshold)
            || ((tick_upper - current_tick).abs() > args.threshold);
        if should_rebalance {
            // Rebalance
            println!("Rebalancing position...");

            // Get current liquidity
            let liquidity = position_manager
                .getPositionLiquidity(U256::from(args.token_id))
                .call()
                .await?;

            // Compute new ticks
            let new_lower = current_tick - args.range_width / 2;
            let new_upper = current_tick + args.range_width / 2;

            // Build unlockData for modifyLiquidities: batch DECREASE_LIQUIDITY and INCREASE_LIQUIDITY
            // This requires encoding actions, params, etc. See PositionManager code for details.
            let unlock_data = todo!("Encode unlockData for rebalance");

            // Set deadline, e.g., block.timestamp + 1 hour
            let deadline = todo!("Calculate current timestamp + 3600");

            // Build and send transaction
            let call = IPositionManager::modifyLiquiditiesCall {
                unlockData: unlock_data,
                deadline,
            };
            let tx = TransactionRequest::default()
                .to(network_constants.position_manager)
                .input(call.abi_encode().into());
            let pending_tx = provider.send_transaction(tx).await?;
            let receipt = pending_tx.watch().await?;
            println!("Rebalance transaction confirmed: {:?}", receipt.0);
        } else {
            println!("Position within bounds.");
        }

        sleep(Duration::from_secs(args.interval)).await;
    }
}
