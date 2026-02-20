# Fiet Protocol

## Overview

The Fiet Protocol is a comprehensive DeFi solution combining automated market making with verified reserve liquidity. For detailed documentation, visit [docs.fiet.finance](https://docs.fiet.finance).

### EVM Interfaces

EVM interfaces for integration:

- `contracts/evm/src/interfaces/IMMPositionManager`
- `contracts/evm/src/interfaces/ILCC`
- `contracts/evm/src/interfaces/ICommitmentDescriptor`
- `contracts/evm/src/interfaces/IMinimalLiquidityHub`

## Documentation

- **Protocol Documentation**: [docs.fiet.finance](https://docs.fiet.finance)
- **Arbitrum Stylus Contracts**: [contracts/stylus/README.md](contracts/stylus/README.md).
  - Kernel-compatible **Intent Policy** (ERC-7579 module type 5) used with PermissionValidator policies such as CallPolicy.
- **Reactive Automation Contracts**: [contracts/reactive/README.md](contracts/reactive/README.md)
  - Keeper automation for lazy liquidity: Async settlement queue clearance once liquidity becomes available .

## License

This project is licensed under the Business Source License - see the [LICENSE](LICENSE) file for details.
