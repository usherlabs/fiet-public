# VTS Library Unit Testing Suite

This directory contains comprehensive unit tests for the VTS (Variable Token Staking) libraries, specifically `VTSPositionLib` and `VTSFeeLib`.

## Architecture

### Base Module: `VTSLibTestBase.sol`

Located at `test/modules/VTSLibTestBase.sol`, this abstract contract provides:

- **Emulated VTSStorage**: A complete `VTSStorage` struct for isolated testing
- **Helper Functions**: Utilities for setting up pools, positions, and accounting state
- **Default Test Values**: Standardised constants for consistent test scenarios
- **Assertion Helpers**: Convenient assertion functions for common checks

### Harness Contracts

Located in `test/libraries/harnesses/`:

- **`VTSPositionLibHarness.sol`**: Exposes internal `VTSPositionLib` functions for testing
- **`VTSFeeLibHarness.sol`**: Exposes internal `VTSFeeLib` functions for testing

These harnesses use the DELEGATECALL pattern, allowing library functions to operate directly on the harness contract's storage.

### Mock Contracts

Located in `test/libraries/mocks/`:

- **`MockPoolManager.sol`**: Mock implementation of `IPoolManager` for testing functions that require pool state queries

## Test Files

### `VTSPositionLib.t.sol`

Comprehensive tests covering:

- **Commitment Tracking** (`_trackCommitment`):
  - Adding liquidity increases commitment maxima
  - Removing liquidity decreases commitment maxima
  - Full removal resets to zero
  - Zero delta (poke) is a no-op
  - Partial removal clamps to zero

- **Settlement Updates** (`_updateSettlement`):
  - Positive deposits increase settled amounts
  - Negative withdrawals decrease settled amounts
  - Netting against deficits first
  - Netting against commitment deficits
  - Clamping to commitment maxima
  - Never creating deficits from withdrawals

- **RFS Calculation** (`getRFS`):
  - Fully settled positions return closed RFS
  - Under-settled positions return open RFS
  - Deficits require additional settlement
  - Commitment deficits inflate requirements

- **Position Registration** (`_registerPosition`):
  - Creates new positions correctly
  - Prevents duplicate registration

- **Fuzz Tests**:
  - Symmetric add/remove operations
  - Settlement never exceeds commitment
  - VTS ratio invariants

### `VTSFeeLib.t.sol`

Comprehensive tests covering:

- **Fee Adjustment Peeking** (`_peekFeeAdjustment`):
  - Returns current pending adjustments
  - Handles zero values

- **Fee Pot Management**:
  - Storage access for slashed pot
  - Protocol fee accrued tracking

- **Fee Processing** (`processPositionFees`):
  - Fee sharing disabled returns zero
  - Positive net settlement allocates bonuses
  - Zero net settlement no bonus
  - Negative net settlement no bonus
  - Dust net settlement skipped
  - Self-contribution excluded from bonus calculation

- **Fee Finalisation** (`_finaliseFeeAdjustment`):
  - Positive pending funds pot
  - Negative pending drains pot
  - Insufficient pot clamps drain
  - No incremental funding snapshot (proactive funding removed)

- **Fuzz Tests**:
  - Fee adjustment invariants
  - Bonus allocation proportionality

## Usage

### Running Tests

```bash
# Run all library tests
forge test --match-path "test/libraries/**/*.t.sol"

# Run specific test file
forge test --match-path "test/libraries/VTSPositionLib.t.sol"

# Run with verbosity
forge test --match-path "test/libraries/**/*.t.sol" -vvv

# Run specific test function
forge test --match-test "test_trackCommitment_addsLiquidity_increasesCommitmentMax"
```

### Writing New Tests

1. **Extend `VTSLibTestBase`**:
   ```solidity
   contract MyLibTest is VTSLibTestBase {
       MyLibHarness harness;
       
       function setUp() public {
           harness = new MyLibHarness();
       }
   }
   ```

2. **Use Helper Functions**:
   ```solidity
   // Create a position in harness storage
   PositionId positionId = _createHarnessPosition(
       owner, poolId, tickLower, tickUpper, liquidity, salt
   );
   
   // Set up accounting state
   VTSStorage storage harnessStorage = _getHarnessStorage();
   harnessStorage.positionAccounting[positionId].settled.token0 = 100e18;
   ```

3. **Assert Results**:
   ```solidity
   (uint256 settled0,,,) = harness.getPositionAccounting(positionId);
   assertEq(settled0, expectedValue, "Settled should match expected");
   ```

## Key Testing Principles

1. **Isolation**: Each test operates on isolated storage, preventing test interference
2. **Completeness**: Tests cover happy paths, edge cases, and error conditions
3. **Invariants**: Fuzz tests verify critical invariants hold across input ranges
4. **Clarity**: Test names clearly describe what is being tested
5. **Maintainability**: Helper functions reduce duplication and improve readability

## Future Enhancements

- [ ] Add tests for growth settlement functions (requires more complex mock setup)
- [ ] Add tests for `onMMSettle` integration function
- [ ] Add tests for seizure calculation (`_calcSeizure`)
- [ ] Add invariant tests using Foundry's invariant testing framework
- [ ] Add gas usage benchmarks for critical functions
