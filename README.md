# Fiet Protocol

## Folder/Directory structure

```
fiet-protocol/
├── scripts/
│   ├── 1_deploy.sh
│   └── 2_initialize.sh
│
├── solidity/
│   ├── lib/
│   ├── src/
│   ├── test/
│   └── ...
│  
├── stylus/
│   ├── delta_manager/
│   ├── fiet_stake/
│   ├── library/
│   ├── liquidity_verifier/
│   ├── settlement_manager/
│   ├── token/
│   └── vrl_manager/
│
├── tests/integration/tests
│                     ├── delta.rs
│                     ├── rfs.rs
│                     └── stake.rs
│
├── .env
├── .env.sample
└── README.md
```

## Overview

The Fiet Protocol directory structure is organized as follows:

- **stylus/**: Contains the main components of the Fiet Protocol, including contracts for staking, token management, and settlement.
  - **delta_manager/**: Keeps track of the deltas of each participants.
  - **fiet_stake/**: The contract responsible for managing token staking.
  - **library/**: A utility library providing core functionalities and helper traits.
  - **liquidity_verifier/**: Used for verifying deposits and signalling liquidity to the VRL contracts and delta manager contracts
  - **settlement_manager/**: Manages and keeps track of off-chain fiat settlements.
  - **token/**: Contains the ERC-20 token implementation.
  - **vrl_manager/**: Handles Verified Reserve Liquidity (VRL) management and keeps track of the balances.

- **solidity/**: Contains the uniswap hook used for the Automated market maker.

- **tests/integration/tests**: Contains integration tests detailing and testing the entire flow of the protocol.
  - **delta.rs: end to end tests the flow of the addition and subtraction of deltas in the contract as various actions take place.
  - **rfs.rs: end to end tests the flow of the creation and completion of a request for settlement, most comprehensive test to demonstrate the protocol's flow because all factors need to be complete before a request for settlement can take place.
  - **stake.rs: end to end tests the flow of the staking process.

- **README.md**: The main documentation file for the Fiet Protocol.

This structure allows for modular development and easy navigation through the various components of the protocol.


## Dependencies

To work with the Fiet Protocol, you need to install the following tools:

### 1. Install Forge

**Forge** is a fast, portable, and modular toolkit for Ethereum application development. To install Forge, follow these steps:

1. **Install Foundry**: Run the following command in your terminal:
   ```bash
   curl -L https://foundry.paradigm.xyz | bash
   ```

2. **Initialize Foundry**: After installation, run:
   ```bash
   foundryup
   ```

3. **Verify Installation**: Check if Forge is installed correctly by running:
   ```bash
   forge --version
   ```

### 2. Install Cargo Stylus

**Cargo Stylus** is a command-line tool for building and deploying Stylus contracts. To install Cargo Stylus, follow these steps:

1. **Install Rust**: If you haven't already, install Rust by following the instructions at [rust-lang.org](https://www.rust-lang.org/tools/install).

2. **Install Cargo Stylus**: Use Cargo to install the Stylus CLI tool:
   ```bash
   cargo install --force cargo-stylus cargo-stylus-check
   ```

3. **Add Build Target**: Add the `wasm32-unknown-unknown` build target to your Rust compiler:
   ```bash
   rustup target add wasm32-unknown-unknown
   ```

4. **Verify Installation**: Check if Cargo Stylus is installed correctly by running:
   ```bash
   cargo stylus --help
   ```

With these tools installed, you will be ready to develop and deploy contracts within the Fiet Protocol.

## Environment Variables
The environment variables needed to run the protocol are outlined as below
```
# RPC
RPC_URL="http://localhost:8547"

# PK of the nitro node deployer
PRIVATE_KEY=0xb6b15c8cb491557369f3c7d2c287b053eb229daa9c22138887752191c9520659

# Address of nitro node deployer
ADDRESS=0x3f1Eae7D46d88F08fc2F8ed27FCb2AB183EB2d0E
```

## Deployment

To deploy and initialize the contracts in the Fiet Protocol, follow these steps:

### 1. Start the [Nitro dev node](https://docs.arbitrum.io/run-arbitrum-node/run-nitro-dev-node)

### 2. Deploy the Contracts
Run the following command to deploy the contracts using the provided bash script:

```bash
bash scripts/1_deploy.sh
```

This script will handle the deployment of the necessary contracts to the blockchain.

### 3. Initialize the Contracts

After deploying the contracts, you need to initialize them. Use the following command to run the initialization script:

```bash
bash scripts/2_initialize.sh
```

This script will set up the initial state of the contracts as required by the protocol.

### 4. Access Deployed Addresses and ABIs

- **Deployed Contract Addresses**: After deployment, the addresses of the deployed contracts can be found in the following file:
  ```
  contract/deployed_contract_address
  ```

- **Contract ABIs**: The ABI (Application Binary Interface) files for the deployed contracts are located in:
  ```
  contract/abi.sol
  ```

Make sure to reference the latest version of these files for interacting with the most recently deployed contracts in your application.

## Writing Tests

Testing is essential for ensuring the reliability and security of the Fiet Protocol. This section outlines how to write and run tests for both Solidity and Stylus components of the protocol.

### Solidity Tests

To test the Solidity contracts, follow these steps:

1. **Navigate to the Solidity Folder**: Change your directory to the folder containing your Solidity contracts.

   ```bash
   cd solidity
   ```

2. **Run Tests with Forge**: Use the following command to run all tests in the Solidity folder:

   ```bash
   forge test
   ```

This command will execute all the test cases defined in your Solidity test files and provide a summary of the results.

### Stylus Tests

The Stylus tests are organized into unit tests and integration tests.

#### Unit Tests

1. **Navigate to Each Contract Folder**: For each contract in the Stylus directory, navigate to its respective folder.

   ```bash
   cd stylus/<contract_folder>
   ```

2. **Run Unit Tests**: Execute the following command to run the unit tests for that specific contract:

   ```bash
   cargo test
   ```

This command will run all unit tests defined in the contract's test files.

#### Integration Tests

Integration tests are designed to test the interaction between multiple components of the protocol. To run integration tests:

1. **Run Each Test Block Individually**: It is crucial to run each integration test block individually to avoid nonce errors that can occur when sending multiple transactions concurrently. Use the following command for each integration test block:

   ```bash
   cargo test --test <test_name>
   ```

Replace `<test_name>` with the name of the specific integration test you want to run.

**Important Note**: Running integration tests concurrently can lead to race conditions with nonces, resulting in errors. Therefore, always run each integration test block individually to ensure accurate results.

By following these guidelines, you can effectively write and run tests for both Solidity and Stylus components of the Fiet Protocol, ensuring the robustness and reliability of your contracts.