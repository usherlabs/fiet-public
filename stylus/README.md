# Fiet Protocol - Stylus Contracts

This directory contains the Stylus contracts for the Fiet Protocol, written in Rust and compiled to WebAssembly (WASM) for deployment on Arbitrum Stylus.

## Overview

The Stylus contracts provide the core functionality of the Fiet Protocol, including staking, token management, settlement, and liquidity verification. The system consists of:

- **DeltaManager**: Tracks participant deltas and manages protocol state
- **FietStake**: Handles token staking and slashing mechanisms
- **SettlementManager**: Manages off-chain fiat settlements
- **LiquidityVerifier**: Verifies deposits and signals liquidity
- **Token**: ERC-20 token implementation
- **VRLManager**: Handles Verified Reserve Liquidity management
- **Library**: Core utilities and helper traits

## Directory Structure

```
stylus/
├── delta_manager/           # Delta tracking and management
├── fiet_stake/             # Token staking and slashing
├── library/                # Core utilities and traits
├── liquidity_verifier/     # Liquidity verification
├── settlement_manager/     # Settlement management
├── token/                  # ERC-20 token implementation
├── vrl_manager/           # VRL management
└── README.md              # This file
```

## Prerequisites

### 1. Install Rust

Install Rust by following the instructions at [rust-lang.org](https://www.rust-lang.org/tools/install):

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
```

### 2. Install Cargo Stylus

Install the Stylus CLI tool with Cargo:

```bash
cargo install --force cargo-stylus cargo-stylus-check
```

### 3. Add WASM Build Target

Add the `wasm32-unknown-unknown` build target to your Rust compiler:

```bash
rustup target add wasm32-unknown-unknown
```

### 4. Verify Installation

Check if Cargo Stylus is installed correctly:

```bash
cargo stylus --help
```

## Quick Start

### 1. Build Contracts

```bash
# Build all contracts
cargo stylus check

# Build specific contract
cd stylus/delta_manager
cargo stylus check
```

### 2. Export ABIs

```bash
# Export ABI for specific contract
cd stylus/delta_manager
cargo stylus export-abi
```

### 3. Run Tests

```bash
# Run unit tests for specific contract
cd stylus/delta_manager
cargo test

# Run integration tests
cd tests/integration
cargo test
```

## Contract Details

### DeltaManager

Tracks the deltas of each participant in the protocol.

**Key Functions:**
- `initialize()` - Initialize the contract
- `update_delta(participant, delta)` - Update participant delta
- `get_delta(participant)` - Get participant delta
- `is_active(participant)` - Check if participant is active

### FietStake

Handles token staking for participants in the Fiet Protocol.

**Key Functions:**
- `initialize(stake_token, delta_manager, settlement_manager, min_stake)`
- `stake(amount)` - Stake tokens
- `unstake(amount)` - Unstake tokens (only if inactive)
- `slash(owner, bps)` - Slash staker by basis points
- `withdraw(amount, to)` - Withdraw slashed tokens

**Features:**
- Enforces minimum stake requirement
- Integrates with DeltaManager for activity validation
- Supports admin-controlled slashing
- Owner can withdraw slashed tokens

### SettlementManager

Manages and tracks off-chain fiat settlements.

**Key Functions:**
- `create_settlement_request(amount, currency)` - Create settlement request
- `approve_settlement(request_id)` - Approve settlement
- `complete_settlement(request_id)` - Complete settlement
- `get_settlement_status(request_id)` - Get settlement status

### LiquidityVerifier

Verifies deposits and signals liquidity to VRL contracts and delta manager.

**Key Functions:**
- `verify_deposit(amount, token)` - Verify deposit
- `signal_liquidity(amount, token)` - Signal liquidity
- `get_verification_status(deposit_id)` - Get verification status

### Token

ERC-20 token implementation for the Fiet Protocol.

**Key Functions:**
- `mint(to, amount)` - Mint tokens
- `burn(from, amount)` - Burn tokens
- `transfer(to, amount)` - Transfer tokens
- `approve(spender, amount)` - Approve spender

### VRLManager

Handles Verified Reserve Liquidity (VRL) management and tracks balances.

**Key Functions:**
- `register_vrl(amount, token)` - Register VRL
- `verify_vrl(vrl_id)` - Verify VRL
- `get_vrl_balance(token)` - Get VRL balance
- `withdraw_vrl(amount, token)` - Withdraw VRL

### Library

Core utilities and helper traits for the Fiet Protocol.

**Features:**
- **Currency Enum**: Hardcoded ISO 4217 currency support (`NGN`, `AUD`)
- **Role Enum**: Defines participant roles (`Custodian`, `LP`)
- **RFS Stages**: Enum for Request For Settlement lifecycle stages
- **Hashable Trait**: Generic trait for Keccak256 hashing

## Deployment

### Testnet Information

All testnet information, including faucets and RPC endpoints, can be found [here](https://docs.arbitrum.io/stylus/reference/testnet-information).

### Deploy Individual Contract

```bash
# Navigate to contract directory
cd stylus/delta_manager

# Check compilation
cargo stylus check

# Estimate gas
cargo stylus deploy \
  --private-key-path=<PRIVKEY_FILE_PATH> \
  --estimate-gas

# Deploy contract
cargo stylus deploy \
  --private-key-path=<PRIVKEY_FILE_PATH>
```

### Deploy All Contracts

```bash
# Deploy all contracts using scripts
bash scripts/1_deploy.sh
```

## Testing

### Unit Tests

Run unit tests for individual contracts:

```bash
# Test DeltaManager
cd stylus/delta_manager
cargo test

# Test FietStake
cd stylus/fiet_stake
cargo test

# Test other contracts similarly
```

### Integration Tests

Integration tests are located in `tests/integration/` and test the interaction between multiple components.

**Important**: Run each integration test block individually to avoid nonce errors:

```bash
cd tests/integration

# Run delta tests
cargo test --test delta

# Run RFS tests
cargo test --test rfs

# Run stake tests
cargo test --test stake
```

**Note**: Running integration tests concurrently can lead to race conditions with nonces. Always run each test block individually.

## Build Options

### Optimize WASM Size

By default, cargo stylus builds with sensible optimizations. For size optimization:

```bash
# Build with size optimizations
cargo stylus build --release

# Check WASM size
ls -la target/wasm32-unknown-unknown/release/*.wasm
```

### Custom Build Configuration

Control compilation options in `Cargo.toml`:

```toml
[profile.release]
opt-level = 3
lto = true
codegen-units = 1
panic = "abort"
```

## Development

### Code Expansion

To see the pure Rust code that will be deployed onchain:

```bash
# Install cargo-expand
cargo install cargo-expand

# Expand macros
cargo expand --all-features --release --target=<YOUR_ARCHITECTURE>
```

Find your architecture with:
```bash
rustc -vV | grep host
```

### ABI Export

Export Solidity ABIs for your contracts:

```bash
cargo stylus export-abi
```

This requires the export-abi feature in `Cargo.toml`:
```toml
[features]
export-abi = ["stylus-sdk/export-abi"]
```

## Environment Variables

Create a `.env` file in the project root:

```bash
# RPC Configuration
RPC_URL="https://sepolia-rollup.arbitrum.io/rpc"

# Deployment
PRIVATE_KEY="your_private_key_here"
ADDRESS="your_deployer_address"

# Contract Addresses (after deployment)
DELTA_MANAGER_ADDRESS="0x..."
FIET_STAKE_ADDRESS="0x..."
SETTLEMENT_MANAGER_ADDRESS="0x..."
```

## Available Commands

### Build Commands

```bash
cargo stylus check      # Check compilation
cargo stylus build      # Build contracts
cargo stylus clean      # Clean build artifacts
```

### Deployment Commands

```bash
cargo stylus deploy     # Deploy contract
cargo stylus export-abi # Export ABI
```

### Testing Commands

```bash
cargo test              # Run unit tests
cargo test --test <name> # Run specific integration test
```

## Troubleshooting

### Common Issues

1. **WASM Compilation Errors**
   ```bash
   # Ensure WASM target is installed
   rustup target add wasm32-unknown-unknown
   
   # Clean and rebuild
   cargo clean
   cargo stylus check
   ```

2. **Deployment Failures**
   - Ensure sufficient ETH for gas
   - Verify private key format
   - Check RPC endpoint connectivity

3. **Test Failures**
   - Run integration tests individually
   - Check nonce conflicts
   - Verify test environment setup

### Debug Commands

```bash
# Check contract compilation
cargo stylus check

# Estimate deployment gas
cargo stylus deploy --estimate-gas

# Expand macros for debugging
cargo expand --all-features --release
```

## Security

- All contracts use the Stylus SDK for secure WASM compilation
- Comprehensive test coverage for critical functions
- Access control mechanisms for sensitive operations
- Integration with Arbitrum's security features

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Run tests: `cargo test`
5. Check compilation: `cargo stylus check`
6. Submit a pull request