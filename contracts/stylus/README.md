# Fiet Protocol - Stylus Contracts

This directory contains the Stylus contracts for the Fiet Protocol, written in Rust and compiled to WebAssembly (WASM) for deployment on Arbitrum Stylus.

## Overview

The Stylus contracts/libraries provide the a super-set of functionality for the Fiet Protocol. They function to improve the gas efficiency of operations on the Fiet Protocol. Their inclusion in the Protocol is modular by nature, meaning Fiet Protocol is native to pure Solidity implementations but empowered by Stylus capabilities.

## Directory Structure

TODO:

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

### 5. Install [ArbOS-enabled Foundry](https://github.com/iosiro/arbos-foundry)

To learn more about ArbOS Foundry, [please see the repository](https://github.com/iosiro/arbos-foundry).

```bash
# Build the fork
cd <path-to>/arbos-foundry
cargo build --release --locked

# Put symlinks somewhere on your PATH (keeps them updated after rebuilds)
mkdir -p "$HOME/.local/bin"

# Link whatever arbos-* tools exist
for f in /Users/ryansoury/dev/arbos-foundry/target/release/arbos-*; do
  [ -x "$f" ] && ln -sf "$f" "$HOME/.local/bin/$(basename "$f")"
done

# Ensure on PATH
grep -q '\.local/bin' "$HOME/.zshrc" || echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.zshrc"
exec zsh

# Verify
arbos-forge --version
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
cd stylus/...
cargo test

# Run integration tests
cd tests/...
cargo test
```

## Contract/Library Details

TODO: 

## Deployment

### Testnet Information

All testnet information, including faucets and RPC endpoints, can be found [here](https://docs.arbitrum.io/stylus/reference/testnet-information).

### Deploy Individual Contract

TODO: 

### Deploy All Contracts

TODO: 

## Testing

TODO: 

### Integration Tests

TODO: 

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
