# Fiet Protocol

## Overview

The Fiet Protocol is a comprehensive DeFi solution combining automated market making with verified reserve liquidity. For detailed documentation, visit [docs.fiet.finance](https://docs.fiet.finance).

## Project Structure

```
fiet-protocol/
├── contracts/evm/             # Fiet Protocol on EVM: Uniswap V4 hooks and AMM contracts
├── contracts/evm-scripts/     # Administrative and Developer scripts for EVM deployments 
├── contracts/stylus/          # Core protocol contracts (Rust/WASM)
├── tests/                     # Integration tests
├── scripts/                   # Deployment scripts
└── docs/                      # Protocol documentation
```

## Embedded Wiki

### Core

- [contracts/evm/README.md](contracts/evm/README.md) — Solidity contracts and development notes
- [contracts/evm/INVARIANTS.md](contracts/evm/INVARIANTS.md) — Invariants and protocol assumptions
- [contracts/evm/oracle/README.md](contracts/evm/oracle/README.md) — Oracle contracts and setup

### Admin

- [contracts/evm-scripts/README.md](contracts/evm-scripts/README.md) — EVM scripts and tooling
- [contracts/evm-scripts/script/admin/README.md](contracts/evm-scripts/script/admin/README.md) — Admin script usage
- [contracts/evm-scripts/script/admin/ORACLE.md](contracts/evm-scripts/script/admin/ORACLE.md) — Oracle admin guide

### Periphery

- [contracts/stylus/README.md](contracts/stylus/README.md) — Stylus contracts and development notes

## Getting Started

### For Solidity Development

See [contracts/evm/README.md](contracts/evm/README.md) for comprehensive Solidity development documentation, including deployment, testing, and local development setup.

#### Notes & Standards

- The `evm-scripts` folder is a standalone Foundry project and is not included in the main contract compilation (such as when running with `--via-IR=false`, e.g. for coverage reports).
- For the best developer experience and to minimize risk of version incompatibilities, use Foundry version **1.4.2** (the same version as used in CI).
- All contracts should be formatted with the default forge fmt config. Run forge fmt.

### For Rust (Arbitrum Stylus) Development  

See [contracts/stylus/README.md](contracts/stylus/README.md) for comprehensive Stylus development documentation, including deployment, testing, and local development setup.

## Documentation

- **Protocol Documentation**: [docs.fiet.finance](https://docs.fiet.finance)
- **Solidity Contracts**: [contracts/evm/README.md](contracts/evm/README.md)
- **Stylus Contracts**: [contracts/stylus/README.md](contracts/stylus/README.md)

## License

This project is licensed under the Business Source License - see the [LICENSE](LICENSE) file for details.
