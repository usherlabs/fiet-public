# `ResilientOracle` Deployment

This directory contains custom deployment scripts for integrating the ResilientOracle protocol. Whilst we utilise the [ResilientOracle repository from Venus Protocol as a git submodule](http://github.com/venusProtocol/oracle/), Fiet is **not dependent on externally deployed contracts**. Instead, we require custom deployment of this Oracle protocol to ensure isolated utility for Fiet protocol's specific requirements.

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

## Network Configuration

The deployment supports the following networks:

- `development` - Local development network (hardhat node)
- `sepolia` - Ethereum Sepolia testnet
- `arbitrumsepolia` - Arbitrum Sepolia testnet
- `arbitrumone` - Arbitrum One mainnet

## Deployment Process

### Running Oracle Deployment

```bash
sh ./deploy.sh <chain>
```

Example for local development on Arbitrum mainnet Anvil fork:

```bash
make fork

CHAIN_ID=421614 ./deploy.sh development
```

Replace `<chain>` with one of the supported network names:

```bash
# Examples
sh ./deploy.sh development
sh ./deploy.sh sepolia
sh ./deploy.sh arbitrumsepolia
sh ./deploy.sh arbitrumone
```

### How It Works

The deployment script (`deploy.sh`) performs the following steps:

1. **Configuration Setup**: Copies the custom Hardhat configuration (`hardhat.custom.config.ts`) into the `lib/oracle` submodule directory, overriding the default configuration
2. **Dependency Installation**: Installs required dependencies within the `lib/oracle` directory
3. **Deployment Execution**: Runs Hardhat deployment with the specified network and deployment tags
4. **Artifact Storage**: Saves deployment artifacts to `deployments/oracle_deployments/<chain>/`

### Custom Configuration

The custom Hardhat configuration (`hardhat.custom.config.ts`) provides:

- **Custom Deployment Paths**: Deployment artifacts are stored in `deployments/oracle_deployments/` instead of the default oracle repository location
- **Environment Variable Loading**: Loads environment variables from the project root `.env` file
- **Network Configuration**: Configures RPC URLs, chain IDs, and account management for supported networks
- **Etherscan Integration**: Enables contract verification on supported networks

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
- For production deployments, verify all contract addresses and configuration parameters
