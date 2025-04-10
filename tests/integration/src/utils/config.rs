use std::{env, error::Error, fs};

use dotenv::from_path;
use ethers::{signers::{LocalWallet, Signer}, types::Address};
use std::str::FromStr;
use eyre::eyre;


#[derive(Debug, Clone)]
pub struct Config {
    pub rpc_url: String,
    pub private_key: String,
    pub public_key: Address,
    pub deployed_contracts: Contracts,
}

// a struct containing the contract addresses
#[derive(Debug, Clone)]
pub struct Contracts {
    pub delta_manager: String,
    pub fiet_stake: String,
    pub liquidity_verifier: String,
    pub settlement_manager: String,
    pub token: String,
    pub vrl_manager: String,
}

impl Contracts {
    pub fn from_file_path() -> Self {
        // make sure the deploy script has been run before hand to deploy
        // and initialize all the contracts before calling them here
        let delta_manager: String = load_address("delta_manager".to_string()).unwrap();
        let fiet_stake: String = load_address("fiet_stake".to_string()).unwrap();
        let liquidity_verifier: String = load_address("liquidity_verifier".to_string()).unwrap();
        let settlement_manager: String = load_address("settlement_manager".to_string()).unwrap();
        let token: String = load_address("token".to_string()).unwrap();
        let vrl_manager: String = load_address("vrl_manager".to_string()).unwrap();

        return Self {
            delta_manager,
            fiet_stake,
            liquidity_verifier,
            settlement_manager,
            token,
            vrl_manager,
        };
    }
}

impl Config {
    pub fn from_env() -> Self {
        // load the environment variables from .env file incase it iasnot been loaded externally
        load_env();

        let private_key = std::env::var("PRIVATE_KEY")
            .map_err(|_| eyre!("No {} env var set", "PRIVATE_KEY"))
            .unwrap();
        let rpc_url = std::env::var("RPC_URL")
            .map_err(|_| eyre!("No {} env var set", "RPC_URL"))
            .unwrap();

        // derive a public key from the provided private key
        let public_key = get_wallet_address(private_key.clone());

        Self {
            rpc_url,
            private_key,
            public_key,
            deployed_contracts: Contracts::from_file_path(),
        }
    }
}

pub fn load_env() {
    // Go two steps down by appending subdirectories
    let base_dir = env::current_dir()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join(".env");

    from_path(base_dir).unwrap();
}

pub fn load_address(contract_folder_name: String) -> Result<String, Box<dyn Error>> {
    let base_path = env::current_dir()
        .unwrap()
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("stylus")
        .join(contract_folder_name)
        .join("deployed_contract_address");

    // Read the file content into a Vec<u8>
    let bytes = fs::read(base_path)?;

    // Convert to String if it's text
    let content = strip_non_alphanumeric(String::from_utf8_lossy(&bytes).to_string());

    // Return the content
    return Ok(content);
}

fn strip_non_alphanumeric(input: String) -> String {
    input.chars().filter(|c| c.is_alphanumeric()).collect()
}

pub fn get_wallet_address(private_key: String) -> Address{
    let wallet = LocalWallet::from_str(&private_key).unwrap();
    return wallet.address();
}