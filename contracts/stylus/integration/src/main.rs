use std::{fs, path::PathBuf, str::FromStr, sync::Arc};

use anyhow::{anyhow, Context, Result};
use clap::Parser;
use ethers::{
    contract::abigen,
    middleware::SignerMiddleware,
    providers::{Http, Middleware, Provider},
    signers::{LocalWallet, Signer},
    types::{Address, U256},
};
use serde_json::Value;

abigen!(
    IntentValidator,
    r#"[
        function onInstall(bytes data) external payable
        function onUninstall(bytes data) external payable
        function isModuleType(uint256 moduleTypeId) external view returns (bool)
        function isInitialized(address smartAccount) external view returns (bool)
        function isValidSignatureWithSender(address sender, bytes32 hash, bytes data) external view returns (bytes4)
    ]"#
);

/// Minimal integration harness for the Stylus validator.
///
/// This runner assumes the contract is already deployed (eg via `tools/deployer`) and that the
/// RPC has funds for the given private key.
#[derive(Parser, Debug)]
#[command(author, version, about)]
struct Cli {
    /// RPC URL to use for calls/transactions.
    #[arg(long, env = "RPC_URL")]
    rpc_url: String,

    /// Path to deployments JSON (written by tools/deployer).
    #[arg(long, default_value = "deployments.devnet.json", env = "DEPLOYMENTS")]
    deployments_path: PathBuf,

    /// Key under `deployments` to look up.
    #[arg(long, default_value = "intent-validator")]
    contract_key: String,

    /// Deployer/test private key (0x...).
    #[arg(long, env = "PKEY", conflicts_with = "private_key_path")]
    private_key: Option<String>,

    /// Path to file containing the deployer/test private key (0x...).
    #[arg(long, env = "PRIV_KEY_PATH", conflicts_with = "private_key")]
    private_key_path: Option<PathBuf>,

    /// Smart account address to test initialisation for.
    ///
    /// If omitted, uses the signer address (useful as a simple stand-in for a Kernel account).
    #[arg(long)]
    smart_account: Option<String>,

    /// Authorised signer address to install (packed into the first 20 bytes for onInstall).
    ///
    /// If omitted, uses the signer address.
    #[arg(long)]
    authorised_signer: Option<String>,

    /// Canonical StateView (v4-periphery lens) address for facts.
    #[arg(long, env = "STATE_VIEW")]
    state_view: String,

    /// Canonical VTSOrchestrator address for facts.
    #[arg(long, env = "VTS_ORCHESTRATOR")]
    vts_orchestrator: String,

    /// Canonical LiquidityHub address for facts.
    #[arg(long, env = "LIQUIDITY_HUB")]
    liquidity_hub: String,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    let contract_address = read_contract_address(&cli.deployments_path, &cli.contract_key)?;

    let provider = Provider::<Http>::try_from(cli.rpc_url.as_str())
        .with_context(|| format!("invalid RPC_URL: {}", cli.rpc_url))?;

    let chain_id = provider.get_chainid().await.context("failed to fetch chain id")?;
    let wallet = load_wallet(&cli)?.with_chain_id(chain_id.as_u64());
    let signer_addr = wallet.address();

    let smart_account = match cli.smart_account {
        Some(ref s) => Address::from_str(s).context("invalid --smart-account address")?,
        None => signer_addr,
    };

    let authorised_signer = match cli.authorised_signer {
        Some(ref s) => Address::from_str(s).context("invalid --authorised-signer address")?,
        None => signer_addr,
    };

    let state_view = Address::from_str(cli.state_view.as_str()).context("invalid --state-view address")?;
    let vts_orchestrator =
        Address::from_str(cli.vts_orchestrator.as_str()).context("invalid --vts-orchestrator address")?;
    let liquidity_hub =
        Address::from_str(cli.liquidity_hub.as_str()).context("invalid --liquidity-hub address")?;

    let client = Arc::new(SignerMiddleware::new(provider, wallet));
    let contract = IntentValidator::new(contract_address, client.clone());

    // Sanity: module types.
    let is_validator = contract.is_module_type(U256::from(1u64)).call().await?;
    let is_hook = contract.is_module_type(U256::from(2u64)).call().await?;
    let is_other = contract.is_module_type(U256::from(3u64)).call().await?;

    if !is_validator || is_hook || is_other {
        return Err(anyhow!(
            "unexpected module-type detection: validator={}, hook={}, other={}",
            is_validator,
            is_hook,
            is_other
        ));
    }

    // Initial state.
    let before = contract.is_initialized(smart_account).call().await?;
    println!("isInitialised(before): {before}");

    // Install + check.
    if !before {
        // onInstall expects:
        // uint8 version=1 || bytes20 signer || bytes20 stateView || bytes20 vtsOrchestrator || bytes20 liquidityHub
        let mut install_data = Vec::with_capacity(81);
        install_data.push(1u8);
        install_data.extend_from_slice(authorised_signer.as_bytes());
        install_data.extend_from_slice(state_view.as_bytes());
        install_data.extend_from_slice(vts_orchestrator.as_bytes());
        install_data.extend_from_slice(liquidity_hub.as_bytes());
        let call = contract.on_install(install_data.into()).value(0u64);
        let pending = call.send().await?;
        let receipt = pending.await?.ok_or_else(|| anyhow!("onInstall tx dropped"))?;
        println!("onInstall tx: {:?}", receipt.transaction_hash);
    }

    let after_install = contract.is_initialized(smart_account).call().await?;
    println!("isInitialised(after install): {after_install}");
    if !after_install {
        return Err(anyhow!("expected contract to be initialised after onInstall"));
    }

    // Uninstall + check.
    let call = contract.on_uninstall(Vec::new().into()).value(0u64);
    let pending = call.send().await?;
    let receipt = pending.await?.ok_or_else(|| anyhow!("onUninstall tx dropped"))?;
    println!("onUninstall tx: {:?}", receipt.transaction_hash);

    let after_uninstall = contract.is_initialized(smart_account).call().await?;
    println!("isInitialised(after uninstall): {after_uninstall}");
    if after_uninstall {
        return Err(anyhow!("expected contract to be uninitialised after onUninstall"));
    }

    println!("Integration checks passed.");
    Ok(())
}

fn read_contract_address(deployments_path: &PathBuf, contract_key: &str) -> Result<Address> {
    let s = fs::read_to_string(deployments_path)
        .with_context(|| format!("failed reading deployments file: {}", deployments_path.display()))?;
    let v: Value = serde_json::from_str(&s)
        .with_context(|| format!("failed parsing deployments JSON: {}", deployments_path.display()))?;

    let addr_str = v
        .get("deployments")
        .and_then(|d| d.get(contract_key))
        .and_then(|c| c.get("address"))
        .and_then(|a| a.as_str())
        .ok_or_else(|| anyhow!("missing deployments.{}.address", contract_key))?;

    Address::from_str(addr_str).context("invalid address in deployments JSON")
}

fn load_wallet(cli: &Cli) -> Result<LocalWallet> {
    let pk = if let Some(ref p) = cli.private_key {
        p.trim().to_string()
    } else if let Some(ref path) = cli.private_key_path {
        fs::read_to_string(path)
            .with_context(|| format!("failed reading private key file: {}", path.display()))?
            .trim()
            .to_string()
    } else {
        return Err(anyhow!(
            "missing signing key: provide --private-key / --private-key-path (or set PKEY / PRIV_KEY_PATH)"
        ));
    };

    LocalWallet::from_str(&pk).context("invalid private key")
}


