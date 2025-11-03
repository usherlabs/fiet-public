# Fiet Protocol - Solidity Contracts

This directory contains the Solidity contracts for the Fiet Protocol, including Uniswap V4 hooks for automated market making functionality.

## Overview

The Solidity contracts provide the automated market maker (AMM) functionality for the Fiet Protocol through Uniswap V4 hooks. The system consists of:

- **CoreHook**: Manages core pool operations and liquidity commitments
- **ProxyHook**: Handles user interactions and proxy pool operations  
- **MarketFactory**: Coordinates between hooks and manages market creation
- **LiquidityCommitmentCertificate (LCC)**: Wrapped tokens representing liquidity commitments

## Directory Structure

```
contracts/evm/
├── src/                    # Contract source files
│   ├── CoreHook.sol       # Core pool hook implementation
│   ├── ProxyHook.sol      # Proxy pool hook implementation
│   ├── MarketFactory.sol  # Market factory contract
│   ├── LCC.sol           # Liquidity Commitment Certificate
│   └── interfaces/       # Contract interfaces
├── script/                # Deployment and utility scripts
│   ├── DeployComplete.s.sol    # Main deployment script
│   ├── ReadDeployment.s.sol    # Read deployment addresses
│   ├── AddLiquidity.s.sol      # Add liquidity script
│   ├── RemoveLiquidity.s.sol   # Remove liquidity script
│   ├── CreateMarket.s.sol      # Create market script
│   └── constants/              # Network-specific constants
├── test/                 # Test files
├── lib/                  # Dependencies (Forge libraries)
├── deployments/          # Deployment address files
└── Makefile             # Build and deployment commands
```

## Prerequisites

### 1. Install Foundry

**Foundry** is a fast, portable, and modular toolkit for Ethereum application development.

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash

# Initialize Foundry
foundryup -i 1.4.2

# Verify installation
forge --version
```

### 2. Install Dependencies

After cloning the repository, install dependencies and initialise git submodules:

```bash
# Install Node.js dependencies
pnpm install

# Install Forge dependencies
forge install
```

## Environment Setup

Create a `.env` file in the solidity directory with the following variables:

```bash
# RPC URLs
ARB_SEPOLIA_RPC_URL="https://sepolia-rollup.arbitrum.io/rpc"
ARB_MAINNET_RPC_URL="https://arb1.arbitrum.io/rpc"

# Deployment
PRIVATE_KEY="your_private_key_here"
ETHERSCAN_API_KEY="your_etherscan_api_key"

# Optional: Override token addresses
UNDERLYING_ASSET_0="0x..."  # USDC address
UNDERLYING_ASSET_1="0x..."  # USDT address
```

## Quick Start

### 1. Build Contracts

```bash
make build
```

### 2. Run Tests

```bash
# Run all tests
forge test

# Run specific test file
forge test --match-contract MarketFactory
```

### 3. Local Development

```bash
# Start local fork
make fork

# Deploy contracts locally
make dev MODE=LOCAL

# Deploy contracts, add liquidity and perform a swap
make e2e MODE=LOCAL
```

## Deployment

### Multi-Network Support

The deployment scripts support multiple networks:

- **Sepolia**: Testnet deployment
- **Arbitrum**: Mainnet deployment

### Deploy Contracts

```bash
# Deploy to Sepolia
NETWORK=sepolia make deploy

# Deploy to Arbitrum  
NETWORK=arbitrum make deploy

# Deploy locally (forked from mainnet)
NETWORK=arbitrum make dev MODE=LOCAL
```

### Deployment Order

1. **MarketFactory** - Deployed first (without hooks)
2. **CoreHook** - Deployed with proper HookMiner logic
3. **ProxyHook** - Deployed with proper HookMiner logic  
4. **Set Hooks** - Configure hooks in MarketFactory
5. **Hook Activation** - Verify cross-references

### Read Deployment Addresses

```bash
# Read addresses for current network
make read-deployment

# Or run directly
forge script script/ReadDeployment.s.sol --rpc-url <rpc_url>
```

## Liquidity Management

### Add Liquidity

```bash
# Add liquidity to core pool
forge script script/AddLiquidity.s.sol --rpc-url <rpc_url> --broadcast
```

### Remove Liquidity

```bash
# Remove liquidity (requires TOKEN_ID)
TOKEN_ID=47 forge script script/RemoveLiquidity.s.sol --rpc-url <rpc_url> --broadcast
```

### Create Market

```bash
# Create new market
forge script script/CreateMarket.s.sol --rpc-url <rpc_url> --broadcast
```

## Contract Architecture

### Hook System

The protocol uses a dual-hook system:

```
MarketFactory
├── CoreHook (manages core pool operations)
└── ProxyHook (manages proxy pool operations)
    └── References CoreHook for cross-pool operations
```

### Hook Flags

**CoreHook Flags:**

- `BEFORE_INITIALIZE_FLAG` - Validates pool initialization
- `AFTER_ADD_LIQUIDITY_FLAG` - Intercepts liquidity additions
- `AFTER_REMOVE_LIQUIDITY_FLAG` - Intercepts liquidity removals

**ProxyHook Flags:**

- `BEFORE_INITIALIZE_FLAG` - Validates pool initialization
- `BEFORE_ADD_LIQUIDITY_FLAG` - Blocks normal liquidity additions
- `BEFORE_SWAP_FLAG` - Overrides swap functionality
- `BEFORE_SWAP_RETURNS_DELTA_FLAG` - Allows custom swap deltas

### Pool Structure

- **Core Pool**: LCC tokens (wrapped liquidity commitments)
- **Proxy Pool**: Underlying tokens (USDC/USDT) with user interface

## Available Commands

### Build Commands

```bash
forge build          # Build contracts
forge clean          # Clean build artifacts
```

### Deployment Commands

```bash
make deploy         # Deploy all contracts
make create-market  # Create market
```

### Development Commands

```bash
make fork               # Start local fork
make dev MODE=LOCAL     # Full development setup
make read-deployment    # Read deployment addresses
```

### Quality Commands

```bash
make format         # Format code
make lint           # Lint code
make security       # Security analysis
make quality        # Run all quality checks
```

## Testing

### Run Tests

```bash
# Run all tests
forge test

# Run specific test
forge test --match-contract MarketFactory

# Run with verbose output
forge test -vvv
```

### Test Coverage

```bash
# Generate coverage report
forge coverage

# Generate coverage report with lcov
forge coverage --report lcov
```

## Troubleshooting

### Common Issues

1. **Hook Address Mismatch**

   ```bash
   # Verify hook flags
   forge script script/DeployComplete.s.sol --sig "verifyDeployment()"
   ```

2. **Insufficient Funds**
   - Ensure deployer account has sufficient ETH for gas
   - Check token balances for liquidity operations

3. **Network Configuration**
   - Verify RPC URLs are correct
   - Check network constants in `script/constants/`

### Debug Commands

```bash
# Read deployment addresses
forge script script/ReadDeployment.s.sol --rpc-url <rpc_url>

# Verify deployment
forge script script/DeployComplete.s.sol --sig "verifyDeployment()" --rpc-url <rpc_url>

```

## Security

- All hooks use CREATE2 for deterministic addresses
- Hook flags are verified to match expected permissions
- Cross-references are verified after deployment
- Comprehensive test coverage for all critical functions

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `forge test`
5. Run quality checks: `make quality`
6. Submit a pull request

# README UPDATES

MMPositionManager actions:

```solidity
// INCREASE
bytes memory incParams = abi.encode(poolKey, tokenId, positionIndex, uint256(1e18));
bytes memory decParams = abi.encode(poolKey, tokenId, positionIndex, uint256(5e17));
bytes memory actions = abi.encodePacked(
    bytes1(uint8(MMAction.INCREASE_LIQUIDITY)),
    bytes1(uint8(MMAction.DECREASE_LIQUIDITY))
);
bytes[] memory params = new bytes[](2);
params[0] = incParams;
params[1] = decParams;

mmp.modifyLiquiditiesWithoutUnlock(actions, params);
```
