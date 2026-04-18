# Fiet Protocol - Solidity Contracts

This directory contains the Solidity contracts for the Fiet Protocol, including Uniswap V4 hooks for automated market making functionality.

## Overview

The Solidity contracts provide the automated market maker (AMM) functionality for the Fiet Protocol through Uniswap V4 hooks. The system consists of:

- **CoreHook**: Manages core pool operations and liquidity commitments
- **ProxyHook**: Handles user interactions and proxy pool operations
- **MarketFactory**: Coordinates between hooks and manages market creation
- **LiquidityCommitmentCertificate (LCC)**: Wrapped tokens representing liquidity commitments

Deployment and operational scripts (including the `justfile`) live in [`../evm-scripts/`](../evm-scripts/README.md).

## Prerequisites

### 1. Install Foundry

**Foundry** is a fast, portable, and modular toolkit for Ethereum application development.

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash

# Initialise Foundry
foundryup -i 1.4.2

# Verify installation
forge --version
```

### 2. Install Dependencies

After cloning the repository, install dependencies and initialise git submodules:

```bash
# 0. Install Just (used for deployment scripts in ../evm-scripts)
brew install just

# 1. Install Forge dependencies (git submodules)
forge install

# 2. Install Node.js dependencies (includes lib/oracle)
node ./patch-oracle.cjs && yarn install
```

### 3. Deploy `ResilientOracle`

The protocol depends on an external deployment of the **ResilientOracle** from Venus Protocol. The oracle must be deployed before deploying the main protocol contracts.

**Important**: The oracle is deployed separately using custom deployment scripts. See the [`oracle/README.md`](oracle/README.md) for detailed deployment instructions.

```bash
# From contracts/evm-scripts/: deploy oracle to your target network
MODE=LIVE NETWORK=sepolia BROADCAST=true just deploy-oracle
```

The deployed oracle address must be available as `RESILIENT_ORACLE_ADDRESS` in your environment variables when deploying the main protocol contracts.

## Environment Setup

Create a `.env` file in `contracts/evm-scripts/` with the following variables:

```bash
# RPC URLs
ARB_SEPOLIA_RPC_URL="https://sepolia-rollup.arbitrum.io/rpc"
ARB_MAINNET_RPC_URL="https://arb1.arbitrum.io/rpc"
ETH_SEPOLIA_RPC_URL="https://sepolia.infura.io/v3/<key>"  # or any ETH Sepolia RPC

# Deployment
PRIVATE_KEY="your_private_key_here"
ETHERSCAN_API_KEY="your_etherscan_api_key"

# Oracle (required - must be deployed separately)
RESILIENT_ORACLE_ADDRESS="0x..."  # Address of deployed ResilientOracle contract

# Optional: Override token addresses
UNDERLYING_ASSET_0="0x..."  # USDC address
UNDERLYING_ASSET_1="0x..."  # USDT address
```

## Quick Start

### 1. Build Contracts

```bash
forge build
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
# From contracts/evm-scripts/: start local fork
NETWORK=sepolia just fork

# From contracts/evm-scripts/: deploy contracts locally
MODE=LOCAL NETWORK=sepolia BROADCAST=true just dev

# From contracts/evm-scripts/: deploy contracts, add liquidity, and perform a swap
MODE=LOCAL NETWORK=sepolia BROADCAST=true just e2e
```

## Deployment

### Commands

See [EVM Scripts Directory](../evm-scripts/)

### Multi-Network Support

The deployment scripts support multiple networks:

- **Sepolia**: Testnet deployment
- **Arbitrum**: Mainnet deployment

### Deploy Contracts

**Prerequisite**: Ensure the ResilientOracle has been deployed and `RESILIENT_ORACLE_ADDRESS` is set in your `.env` file. See [Deploy ResilientOracle](#3-deploy-resilientoracle) above.

```bash
# From contracts/evm-scripts/: deploy to Arbitrum Sepolia
MODE=LIVE NETWORK=sepolia BROADCAST=true just deploy

# From contracts/evm-scripts/: deploy to Arbitrum mainnet
MODE=LIVE NETWORK=arbitrum BROADCAST=true just deploy

# From contracts/evm-scripts/: deploy locally (forked from mainnet)
MODE=LOCAL NETWORK=arbitrum BROADCAST=true just dev
```

### Deployment Order

1. **MarketFactory** - Deployed first (without hooks)
2. **CoreHook** - Deployed with proper HookMiner logic
3. **ProxyHook** - Deployed with proper HookMiner logic
4. **Set Hooks** - Configure hooks in MarketFactory
5. **Hook Activation** - Verify cross-references

### Read Deployment Addresses

```bash
# From contracts/evm-scripts/: read addresses for current network
MODE=LIVE NETWORK=sepolia just read-deployment

# Or run directly (from contracts/evm-scripts/)
forge script script/ReadDeployment.s.sol --rpc-url <rpc_url>
```

## Liquidity Management

### Add Liquidity

```bash
# From contracts/evm-scripts/: add liquidity to market
MODE=LIVE NETWORK=sepolia BROADCAST=true just add-liquidity
```

### Remove Liquidity

```bash
# From contracts/evm-scripts/: remove liquidity (requires TOKEN_ID)
MODE=LIVE NETWORK=sepolia BROADCAST=true TOKEN_ID=47 just remove-liquidity
```

### Create Market

```bash
# From contracts/evm-scripts/: create new market
MODE=LIVE NETWORK=sepolia BROADCAST=true just create-market
```

## Contract Architecture

### Hook System

The protocol uses a dual-hook system:

```text
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

### Development Commands

```bash
just fork               # Start local fork (from contracts/evm-scripts/)
MODE=LOCAL BROADCAST=true just dev     # Full development setup (from contracts/evm-scripts/)
just read-deployment    # Read deployment addresses (from contracts/evm-scripts/)
```

### Quality Commands

```bash
yarn run format     # Format code (from contracts/evm/)
yarn run lint       # Lint code (from contracts/evm/)
yarn run security   # Security analysis (from contracts/evm/)
yarn run format:check && yarn run lint && yarn run security  # Run all quality checks (from contracts/evm/)
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

### Fuzzing (Medusa)

Medusa is the authoritative property-fuzzing path for `contracts/evm/test/fuzz/`. Canonical invariant harnesses live
under `test/fuzz/invariants/`, and a small set of legacy-named regression harnesses is retained for historical bug
surfaces that are now also run by Medusa.

```bash
# Run the full Medusa-backed suite
just fuzz
just fuzz-deep
just fuzz-invariants

# Run a short artifact-preserving smoke campaign
just medusa-coverage-smoke

# Run individual harnesses
just medusa-lcc-backing
just medusa-commit-01
```

Notes:

- Install `medusa` plus `crytic-compile`, or bootstrap with `scripts/codex-setup.sh`.
- The runner is `scripts/medusa.sh`; it uses `[profile.medusa]` in `foundry.toml` and writes build output to
  `out-medusa/`.
- Solidity property functions use the `fuzz_*` prefix, and Medusa is the only supported runner for this suite.
- Set `MEDUSA_CORPUS_DIR=artifacts/medusa-local` to keep per-harness corpus / coverage-guided artifacts in the repo
  workspace.
- See `test/fuzz/README.md` for the invariant coverage map and `INVARIANTS.md` for canonical invariant IDs.

### Mutation Testing (Gambit)

This repo includes a lightweight mutation testing runner: `mutation_tests.sh`.

At a high level it:

- Generates Solidity mutants using **Gambit**
- Creates an isolated **git worktree** at `./.mutation-worktree/`
- Overlays each mutant into the worktree and runs `forge test`
- Records whether each mutant is **killed** (tests fail) or **survived** (tests pass)

#### **Prerequisites**

- `gambit` on your `PATH` (built from `Certora/Gambit`)
- `solc` on your `PATH` (matching the project/compiler constraints)
- `forge` on your `PATH`
- `git` available (for worktrees)

#### **Basic usage**

```bash
# Run against the default core target set
./mutation_tests.sh

# Target a specific contract file
./mutation_tests.sh src/LiquidityHub.sol

# Downsample mutants (useful to start with)
NUM_MUTANTS=25 ./mutation_tests.sh src/LiquidityHub.sol

# Skip Gambit's solc validation step (faster, but may generate uncompilable mutants)
SKIP_VALIDATE=1 NUM_MUTANTS=25 ./mutation_tests.sh src/LiquidityHub.sol
```

#### **Clean vs resume runs**

```bash
# Guaranteed clean run (removes ./gambit_out and ./.mutation-worktree first)
CLEAN_BEFORE=1 ./mutation_tests.sh

# Resume a prior run (reuse existing mutants and skip already-recorded mutant IDs)
REUSE_OUTDIR=1 RESUME=1 ./mutation_tests.sh

# Keep going even if a mutant run errors (records 'errored' and continues)
FAIL_FAST=0 ./mutation_tests.sh
```

#### **Outputs**

- `./gambit_out/`: mutants, logs, and `mutation_results.csv`
- `./.mutation-worktree/`: the worktree checkout used to run tests (local artefact)

You should generally **not commit** these artefacts; add them to `.gitignore` if needed.

### Test Coverage

```bash
# Generate coverage report
forge coverage

# Generate coverage report with lcov
forge coverage --report lcov
```

Use the **provided wrapper** to generate a summary plus `lcov` output:

```bash
./coverage.sh
```

This writes `./lcov.info` and prints a coverage summary to stdout.

## Troubleshooting

### Common Issues

1. **Hook Address Mismatch**

   ```bash
   # Verify hook flags
   forge script script/deploy/DeployContracts.s.sol:DeployContracts --sig "verifyDeployment()"
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
forge script script/deploy/DeployContracts.s.sol:DeployContracts --sig "verifyDeployment()" --rpc-url <rpc_url>

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
5. Run quality checks: `yarn run format:check && yarn run lint && yarn run security`
6. Submit a pull request

## README updates

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
