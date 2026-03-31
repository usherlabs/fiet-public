# Validating CREATE2 Addresses for Echidna Fuzz Tests

Echidna fuzz harnesses use **hard-linked library addresses** so that Foundry's linker and HEVM can resolve `DELEGATECALL` targets deterministically. These addresses are computed via CREATE2 from a fixed deployer and salt. When library bytecode changes (e.g. after a refactor or dependency update), the CREATE2 addresses change and must be recomputed.

## When to Regenerate

Regenerate addresses when:

- You modify any of: `LCCFactoryLinkedLib`, `VTSCommitLib`, `VTSPositionLib`
- You change dependencies (e.g. Uniswap v4, OpenZeppelin) that affect those libraries
- Echidna fails with `EchidnaLinkedLibs: * addr mismatch` during harness deployment

### If You See the Mismatch Error

If Echidna fails with:

```text
Error("EchidnaLinkedLibs: LCCFactoryLinkedLib addr mismatch")
Error("EchidnaLinkedLibs: VTSCommitLib addr mismatch")
Error("EchidnaLinkedLibs: VTSPositionLib addr mismatch")
Error("...deploying/linking to empty address...")
```

you **must** recompute the addresses and update them in the two places below. The error means the hardcoded addresses no longer match the current compiled bytecode.

## How to Run Validation

Copy-paste (from repo root):

```bash
cd contracts/evm && just validate-fuzz-libs
```

This runs `ValidateEchidnaLinkedLibs.s.sol` under `FOUNDRY_PROFILE=echidna` so the computed addresses match Echidna build settings.

## If Validation Fails

Update **exactly two** places with the recomputed addresses:

### 1. `contracts/evm/test/fuzz/base/EchidnaLinkedLibs.sol`

Replace the three constant values (lines ~12–14):

```solidity
address internal constant LCC_FACTORY_LINKED_LIB = 0x...;
address internal constant VTS_COMMIT_LIB = 0x...;
address internal constant VTS_POSITION_LIB = 0x...;
```

### 2. `contracts/evm/foundry.toml`

In the `[profile.echidna]` section, update the `libraries` array (lines ~62–71). Replace the hex addresses in the first three entries:

```toml
libraries = [
  "src/libraries/LCCFactoryLib.sol:LCCFactoryLinkedLib:0x...",   # update this address
  "src/libraries/VTSCommitLib.sol:VTSCommitLib:0x...",            # update this address
  "src/libraries/VTSPositionLib.sol:VTSPositionLib:0x...",      # update this address
  "src/libraries/VTSSwapLib.sol:VTSSwapLib:0x...",
  "src/libraries/VTSFeeLib.sol:VTSFeeLinkedLib:0x...",
]
```

Only the first three entries are validated by the current script.

## Scope

Current validation covers:

- `LCCFactoryLinkedLib`
- `VTSCommitLib`
- `VTSPositionLib`

## Why CREATE2 Addresses Change

CREATE2 address = `keccak256(0xff || deployer || salt || keccak256(initCode))`

The `initCode` is the library's creation bytecode. Any change to the library source or its dependencies changes the compiled bytecode, which changes `keccak256(initCode)`, which changes the final address.