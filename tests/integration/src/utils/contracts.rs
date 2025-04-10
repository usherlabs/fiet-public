use super::{
    config::{Config, Contracts},
    transactions::mint,
};
use ethers::{
    contract::abigen,
    core::{k256::ecdsa::SigningKey, rand},
    middleware::SignerMiddleware,
    providers::{Http, Middleware, Provider},
    signers::{LocalWallet, Signer, Wallet},
    types::{Address, TransactionReceipt, TransactionRequest, U256},
};
use rand_chacha::rand_core::RngCore;
use rand_chacha::rand_core::SeedableRng;
use rand_chacha::ChaCha20Rng;

use std::{str::FromStr, sync::Arc};

// define the ABIs
abigen!(
    IERC20,
    r#"[
        function name() external pure returns (string memory)
        function symbol() external pure returns (string memory)
        function decimals() external pure returns (uint8)
        function totalSupply() external view returns (uint256)
        function balanceOf(address owner) external view returns (uint256)
        function transfer(address to, uint256 value) external returns (bool)
        function transferFrom(address from, address to, uint256 value) external returns (bool)
        function approve(address spender, uint256 value) external returns (bool)
        function allowance(address owner, address spender) external view returns (uint256)
        function initialize() external
        function mint(uint256 value) external
        function mintTo(address to, uint256 value) external
        function burn(uint256 value) external
        function sample() external returns (string memory)
    ]"#
);

abigen!(
    IFietStake,
    r#"[
        function initialize(address stake_token, address delta_manager, address settlement_manager, uint256 min_stake) external
        function setAdmin(address new_admin_address, bool is_admin) external
        function stake(uint256 amount) external
        function stakeFor(address owner, uint256 amount) external
        function unstake(uint256 amount) external
        function slash(address owner, uint256 bps) external
        function slashByAmount(address owner, uint256 target_amount, int256 delta_amount) external
        function withdraw(uint256 amount, address to) external
        function getBalance(address owner) external returns (uint256)
        function getStakedToken() external returns (address)
        function isStaked(address owner) external returns (bool)
        function getSlashBps(uint256 target_amount, int256 delta_amount) external view returns (uint256)
        function getSlashAmount(uint256 bps) external view returns (uint256)
        function getMinStake() external view returns (uint256)
    ]"#
);

abigen!(
    IDeltaManager,
    r#"[
        function initialize(address liquidity_verifier, address stake_contract, address vrl_manager, address settlement_manager) external
        function whitelistCustodian(address custodian, bool whitelist) external
        function registerAsCustodian(bytes32 currency_hash) external
        function registerAsLp(bytes32 currency_hash) external
        function unregisterParticipant() external
        function signalDelta(address owner, bytes32 currency_hash, int256 delta) external returns (int256)
        function deltaOfParticipant(address owner) external returns (int256)
        function currencyHashOfParticipant(address owner) external returns (bytes32)
        function isActiveParticipant(address owner) external returns (bool)
        function getCurrencyParticipants(bytes32 currency_hash) external returns (address[] memory)
        function adminSettleDelta(uint256 amount, address user) external
        function userSettleDelta(uint256 amount) external
    ]"#
);

abigen!(
    ILiquidityManager,
    r#"[
        function initialize(address vrl_manager_address, address delta_manager_address) external
        function manualSignalDeposit(address owner, address custodian, string calldata currency, uint256 amount) external
        function manualSignalLiquidity(address lp_address, string calldata currency, uint256 amount) external
    ]"#
);

abigen!(
    ISettlement,
    r#"[
        function initialize(address delta_manager, address stake_manager, uint256 ttl) external
        function createRequestForSettlement(uint256 settle_amount) external
        function bid(uint256 rfs_id, uint256 amount) external
        function closeRequestForSettlement() external
    ]"#
);

abigen!(
    IVRLManager,
    r#"[
        function initialize(address liquidity_verifier, address delta_manager, address uniswap_hook, uint256 decimals) external
        function depostVerifiedFiat(address owner, bytes32 currency_hash, uint256 amount) external
        function getUserCurrencyVrl(address owner, bytes32 currency_hash) external view returns (uint256)
        function lockVrl(address owner, bytes32 currency_hash, uint256 delta) external returns (uint256)
        function unlockVrl(address owner, bytes32 currency_hash, uint256 delta) external returns (uint256)
        function burnVrlForDelta(address owner, bytes32 currency_hash, uint256 delta) external returns (uint256)
        function getDecimals() external view returns (uint256)
        function getOwner() external view returns (address)
        function getLockedVrl() external view returns (uint256)
    ]"#
);
// define the ABIs

#[derive(Debug, Clone)]
pub struct KeyPair {
    pub private_key: String,
    pub public_key: Address,
}
pub struct ContractsHelper {
    provider: Provider<Http>,
    private_key: String,
    override_pk: Option<String>,
    pub contracts: Contracts,
}

impl ContractsHelper {
    pub fn new(config: &Config) -> Self {
        let provider = Provider::<Http>::try_from(config.rpc_url.clone()).unwrap();
        let config_private_key = config.private_key.clone();

        // override the private key if needed, in order to simulate another entity
        let private_key = config_private_key;

        Self {
            provider,
            private_key,
            contracts: config.deployed_contracts.clone(),
            override_pk: None,
        }
    }

    pub async fn get_erc20token_contract(&self) -> IERC20<MiddlewareSignerType> {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        let contract_address: Address = self.contracts.token.clone().parse().unwrap();
        let contract = IERC20::new(contract_address, client);

        return contract;
    }

    pub async fn get_stake_contract(&self) -> IFietStake<MiddlewareSignerType> {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        let contract_address: Address = self.contracts.fiet_stake.clone().parse().unwrap();
        let contract = IFietStake::new(contract_address, client);

        return contract;
    }

    pub async fn get_delta_manager(&self) -> IDeltaManager<MiddlewareSignerType> {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        let contract_address: Address = self.contracts.delta_manager.clone().parse().unwrap();
        let contract = IDeltaManager::new(contract_address, client);

        return contract;
    }

    pub async fn get_liquidity_verifier(&self) -> ILiquidityManager<MiddlewareSignerType> {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        let contract_address: Address = self.contracts.liquidity_verifier.clone().parse().unwrap();
        let contract = ILiquidityManager::new(contract_address, client);

        return contract;
    }

    pub async fn get_vrl_manager(&self) -> IVRLManager<MiddlewareSignerType> {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        let contract_address: Address = self.contracts.vrl_manager.clone().parse().unwrap();
        let contract = IVRLManager::new(contract_address, client);

        return contract;
    }

    pub async fn get_settlement_manager(&self) -> ISettlement<MiddlewareSignerType> {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        let contract_address: Address = self.contracts.settlement_manager.clone().parse().unwrap();
        let contract = ISettlement::new(contract_address, client);

        return contract;
    }

    pub async fn transfer_eth(&self, recipient: Address, amount: f64) -> TransactionReceipt {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();
        let chain_id = self.get_chain_id().await;

        let client = Arc::new(SignerMiddleware::new(
            self.provider.clone(),
            wallet.clone().with_chain_id(chain_id),
        ));

        // Recipient address and value
        let value = ethers::utils::parse_ether(amount).unwrap(); // 0.01 ETH

        // Send the transaction
        let tx = TransactionRequest::pay(recipient, value);
        let tx_rcpt = client
            .send_transaction(tx, None)
            .await
            .unwrap()
            .await
            .unwrap()
            .unwrap();

        return tx_rcpt;
    }

    pub async fn generate_funded_keypair(&self, seed: Option<u64>) -> KeyPair {
        //amount of ether this wallet stars with when generated
        let initial_balance: f64 = 0.1;
        // Generate a random wallet (includes private key)

        // if a seed is provided then generate a wallet deterministically, otherwise generate one randomly
        let seed = if seed.is_some() {
            seed.unwrap()
        } else {
            rand::random::<u64>()
        };
        let mut rng = ChaCha20Rng::seed_from_u64(seed);

        // Generate random 32 bytes for private key
        let mut key_bytes = [0u8; 32];
        rng.fill_bytes(&mut key_bytes);
        let wallet = LocalWallet::from_bytes(&key_bytes).expect("Invalid private key");

        // Get the private key bytes and encode as hex
        let private_key_bytes = wallet.signer().to_bytes();
        let private_key = format!("0x{}", hex::encode(private_key_bytes));
        let public_key = wallet.address();

        // transfer some eth
        self.transfer_eth(public_key, initial_balance).await;
        // mint some fiet tokens
        mint(&self, U256::from(10e18 as u64), public_key)
            .await
            .unwrap();

        return KeyPair {
            private_key,
            public_key: public_key,
        };
    }

    // ------------------- Helper Methods
    pub async fn get_chain_id(&self) -> u64 {
        let chain_id = self.provider.get_chainid().await.unwrap().as_u64();
        return chain_id;
    }

    pub fn start_prank(&mut self, override_private_key: &String) {
        self.override_pk = Some(override_private_key.clone());
    }

    pub fn stop_prank(&mut self) {
        self.override_pk = None;
    }

    pub fn get_private_key(&self) -> String {
        if self.override_pk.is_some() {
            self.override_pk.clone().unwrap()
        } else {
            self.private_key.clone()
        }
    }

    pub fn get_public_key(&self) -> Address {
        let wallet = LocalWallet::from_str(&self.get_private_key()).unwrap();

        return wallet.address();
    }
}

type MiddlewareSignerType = SignerMiddleware<Provider<Http>, Wallet<SigningKey>>;
