# `ResilientOracle` Deployment

This directory contains custom deployment scripts for integrating the ResilientOracle protocol. Whilst we utilise the [ResilientOracle repository from Venus Protocol as a git submodule](http://github.com/venusProtocol/oracle/), Fiet is **not dependent on externally deployed contracts**. Instead, we require custom deployment of this Oracle protocol to ensure isolated utility for Fiet protocol's specific requirements.

## Quick Start

```bash
# 1. Install dependencies (from contracts/evm/)
yarn install

# 2. Deploy oracle
just deploy-oracle

# For local development with fork
just fork                    # In another terminal
MODE=LOCAL just deploy-oracle
```

## Overview

The oracle deployment scripts provide a customised deployment process that:

- Uses a tailored Hardhat configuration for protocol-specific deployment paths
- Integrates with the main protocol deployment pipeline
- Stores deployment artifacts in a structured location for easy integration
- Supports multiple network environments

## Prerequisites

- Node.js and Yarn installed
- Access to the target network RPC endpoints
- Private key configured in `.env` file (for non-development networks)
- Git submodule initialised (`contracts/evm/lib/oracle` directory) via Forge (`forge install`)
- Dependencies installed from project root: `yarn install` (run from `contracts/evm/`)

## Network Configuration

The deployment supports the following networks:

- `development` - Local development network (hardhat node)
- `sepolia` - Ethereum Sepolia testnet
- `arbitrumsepolia` - Arbitrum Sepolia testnet
- `arbitrumone` - Arbitrum One mainnet

## Deployment Process

### Setup

First, ensure dependencies are installed from the project root:

```bash
cd contracts/evm
yarn install
```

### Running Oracle Deployment

Deploy the oracle using the `just` command runner:

```bash
just deploy-oracle
```

The deployment automatically detects the network based on the `NETWORK` environment variable (defaults to `sepolia`). For local development:

```bash
# Start local fork first
just fork

# Deploy oracle to development network
MODE=LOCAL NETWORK=sepolia just deploy-oracle
```

### Network Selection

The deployment script maps network names as follows:

- `NETWORK=sepolia` → deploys to `arbitrumsepolia` (Arbitrum Sepolia testnet)
- `NETWORK=arbitrum` → deploys to `arbitrumone` (Arbitrum One mainnet)
- `NETWORK=ethsepolia` → deploys to `sepolia` (Ethereum Sepolia testnet)
- `MODE=LOCAL` → deploys to `development` (local Hardhat node)

### How It Works

The `just deploy-oracle` command performs the following steps:

1. **Configuration Setup**: Copies the custom Hardhat configuration (`hardhat.custom.config.ts`) into the `lib/oracle` submodule directory as `hardhat.fiet.config.ts`
2. **Network Mapping**: Maps the Fiet protocol network names to oracle network names
3. **Deployment Execution**: Changes directory to `lib/oracle` and runs Hardhat deployment with the specified network and `--tags deploy --reset` flags
4. **Artifact Storage**: Saves deployment artifacts to `deployments/oracle_deployments/<network>/`

### Custom Configuration

The custom Hardhat configuration (`hardhat.custom.config.ts`) provides:

- **Custom Deployment Paths**: Deployment artifacts are stored in `deployments/oracle_deployments/` instead of the default oracle repository location
- **Environment Variable Loading**: Loads environment variables from the project root `.env` file (`contracts/evm/.env`)
- **Network Configuration**: Configures RPC URLs, chain IDs, and account management for supported networks
- **Etherscan Integration**: Enables contract verification on supported networks
- **External Dependencies**: Points to `node_modules` in the parent directory (`contracts/evm/node_modules`) for accessing Venus Protocol dependencies
- **Hardhat Deploy Ethers**: Includes `hardhat-deploy-ethers` plugin for contract interaction utilities

## Integration with Protocol Deployment

The deployed oracle address must be available as an environment variable (`RESILIENT_ORACLE_ADDRESS`) when deploying the main protocol contracts. The protocol's `OracleHelper` contract expects this address to be pre-deployed.

### Deployment Output

Deployment artifacts are stored in:

```text
deployments/oracle_deployments/<chain>/
```

For example:

```text
deployments/oracle_deployments/development/
deployments/oracle_deployments/sepolia/
deployments/oracle_deployments/arbitrumsepolia/
deployments/oracle_deployments/arbitrumone/
```

## Environment Variables

The deployment script uses environment variables from the project root `.env` file:

- `PRIVATE_KEY` - Private key for contract deployment (required for non-development networks)
- `ARCHIVE_NODE_sepolia` - Optional Sepolia RPC URL (falls back to public RPC)
- `ARB_SEPOLIA_RPC_URL` - Optional Arbitrum Sepolia RPC URL (falls back to public RPC)
- `ARB_MAINNET_RPC_URL` - Optional Arbitrum One RPC URL (falls back to public RPC)
- `ETHERSCAN_API_KEY` - Etherscan API key for contract verification

## Notes

- The `--reset` flag is used by default to force fresh deployments and bypass cache
- The deployment uses the `--tags deploy` flag to execute only tagged deployment scripts
- Ensure the oracle git submodule is initialised via Forge (`forge install`) and up to date before deployment (located at `contracts/evm/lib/oracle`)
- Dependencies must be installed from `contracts/evm/` root directory, not from within `lib/oracle/`
- The custom config file (`hardhat.fiet.config.ts`) is automatically generated in `lib/oracle/` during deployment and is gitignored
- For production deployments, verify all contract addresses and configuration parameters
- The deployment runs from within `lib/oracle/` directory to ensure correct relative imports in deployment scripts

## Technical Reference: Price Decimal Normalisation

The `ChainlinkOracle` contract performs **two layers of decimal normalisation** to ensure consistent 18-decimal precision pricing across all assets, regardless of their native token decimals or the Chainlink feed's precision.

### Layer 1: Chainlink Feed Normalisation

Chainlink USD price feeds typically return prices with **8 decimals of precision**. The oracle scales the raw Chainlink answer up to 18 decimals:

```solidity
// In _getChainlinkPrice()
uint256 decimalDelta = 18 - feed.decimals();
return uint256(answer) * (10 ** decimalDelta);
```

**Example – ETH/USD:**

- Chainlink returns: `200000000000` (represents $2,000.00 with 8 decimals)
- `decimalDelta = 18 - 8 = 10`
- Result: `200000000000 × 10^10 = 2000 × 10^18` (i.e., $2,000 in 18-decimal format)

### Layer 2: Asset Decimal Normalisation

The second transformation in `_getPriceInternal` adjusts the price based on the **asset's own token decimals**:

```solidity
// In _getPriceInternal()
uint256 decimalDelta = 18 - decimals;
return price * (10 ** decimalDelta);
```

This creates a "scaling multiplier" so that downstream calculations work uniformly with the formula:

```
USD_value (18 decimals) = (raw_token_amount × scaled_price) / 1e18
```

### Worked Examples

| Asset | Token Decimals | Chainlink Price | After Layer 1 | After Layer 2 | 1 Token Value Calculation |
|-------|----------------|-----------------|---------------|---------------|---------------------------|
| ETH   | 18             | $2,000          | `2000e18`     | `2000e18`     | `(1e18 × 2000e18) / 1e18 = 2000e18` ✓ |
| USDC  | 6              | $1              | `1e18`        | `1e30`        | `(1e6 × 1e30) / 1e18 = 1e18` ✓ |
| WBTC  | 8              | $40,000         | `40000e18`    | `40000e28`    | `(1e8 × 40000e28) / 1e18 = 40000e18` ✓ |

### Why This Matters

This double normalisation ensures that regardless of:

1. The Chainlink feed's native precision (usually 8 decimals)
2. The token's native decimals (6, 8, 18, etc.)

...the final price can be used uniformly across the protocol for accurate USD value calculations. This is a common pattern in DeFi to avoid precision loss and enable apples-to-apples comparisons between assets with different decimal configurations.
