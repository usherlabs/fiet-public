# MM Atomic Re-Validation Mechanism

## Vulnerability

**Live price-based issuance validation without tolerance in MM add-liquidity hook causes transaction-level DoS via front-run price moves.**

When market makers add or mint liquidity, the protocol validates LCC issuance against the live pool price inside the afterAddLiquidity hook and reverts on insufficient backing. An attacker can front-run with a small price move so that the check fails at execution time, causing the add-liquidity to revert. This is an ordering-sensitive/MEV grief vector with no loss of funds.

In CoreHook.afterAddLiquidity, VTSOrchestrator.processPosition calls VTSPositionLib.touchPosition, which for MM operations invokes VTSPositionLib.\_handleLiquidityIncrease. That function reads the live pool price via poolManager.getSlot0 and calls VTSCommitLib.validateLiquidityDelta with revertIfInsufficientBacking = true. validateLiquidityDelta computes issuedValue (using LiquidityUtils.calculateEffectiveTokenAmounts at the current tick) and compares it to signalUsd + settledUsd. If issuedValue exceeds backing, it reverts. Because this check uses the current pool tick at execution time and there is no caller-configurable tolerance or pre-commit bound, an attacker can front-run with a swap to nudge the tick so that issuedValue > signal + settled, forcing the add-liquidity to revert. The revert rolls back the entire modifyLiquidity call, wasting gas and blocking the intended operation. This affects MM add/mint flows; direct LP adds are not subject to this issuance validation path.

## Overview

This document outlines the implementation scope for mitigating vulnerability #30 (MEV griefing via front-run price moves on MM add-liquidity validation) through a 7702-based atomic re-validation policy.

**Vulnerability Context:**
When market makers add liquidity, the protocol validates LCC issuance against live pool state (current tick/sqrtPriceX96 from `getSlot0`). An attacker can front-run with a small swap, nudging the tick so that `issuedValue > signalUsd + settledUsd`, causing the add-liquidity to revert. This is a transaction-level DoS/griefing vector with no loss of funds.

**Mitigation Strategy:**
Rather than modifying the core protocol's strict execution-time validation, we implement a **client-side atomic re-validation policy** using EIP-7702 (account abstraction). This allows MMs to validate intra-transaction state differences immediately before their actions are taken, rejecting transactions that would fail due to adversarial state manipulation.

---

## Design Goals

1. **Atomic Pre-Execution Validation**: Re-validate all critical state dependencies immediately before transaction execution
2. **Protected Execution Context**: Leverage 7702 to ensure validation occurs in a tamper-resistant sequencing
3. **Protocol-Agnostic Core**: Core VTS validation remains strict; the mitigation lives at the execution layer
4. **Environment-Aware**: Most effective on L2s with strong ordering guarantees; degrades gracefully on MEV-exposed venues

---

## Technical Scope

### 1. Intent Policy Extension (`src/fiet-maker-policy/`)

#### New Opcode: `VALIDATE_LIQUIDITY_DELTA` (0x40)

**Purpose:** Atomically re-validate that the backing check will pass before allowing the add-liquidity to proceed.

**Parameters:**

```rust
struct ValidateLiquidityDeltaParams {
    // Pool identification
    currency0: Address,
    currency1: Address,
    fee: u24,
    tick_spacing: i24,

    // Position parameters from the intended operation
    tick_lower: i24,
    tick_upper: i24,
    liquidity_delta: i128,

    // Commit identification
    commit_id: u256,

    // Tolerance bounds (caller-configurable)
    max_issued_usd: u256,          // Revert if issuedUsd exceeds this
    max_tick_deviation: i24,       // Revert if |currentTick - expectedTick| > this
    min_backing_buffer_bps: u16,   // Required buffer: issuedUsd * (10000 + bps) <= backing
}
```

**Validation Logic:**

1. Query `getSlot0` for current `sqrtPriceX96` and `currentTick`
2. Compute `issuedUsd` via `calculateEffectiveTokenAmounts` + oracle pricing
3. Query settled amounts for position (if exists)
4. Query signal value for commit
5. Check all tolerance bounds:
   - `issuedUsd <= max_issued_usd`
   - `|currentTick - expectedTick| <= max_tick_deviation`
   - `issuedUsd * (10000 + min_backing_buffer_bps) / 10000 <= (signalUsd + settledUsd)`
6. If any check fails, the entire intent reverts atomically

**Files to modify:**

- `src/fiet-maker-policy/src/types/opcodes.rs` - Add new opcode
- `src/fiet-maker-policy/src/evaluator.rs` - Implement validation logic
- `src/fiet-maker-policy/src/facts/onchain.rs` - Add state reading helpers

### 2. Kernel 7702 Integration (`src/fiet-maker-policy/src/kernel/`)

#### Transaction Bundling Requirements

The 7702 policy must ensure that re-validation and execution are **atomically bundled** such that:

1. No external state can change between validation and execution
2. The validation results are consumed by the subsequent action

**Implementation Details:**

```rust
// In kernel/mod.rs or new kernel/validation.rs

/// Pre-flight validation bundle for MM operations
pub struct MMValidationBundle {
    /// Validation step
    validation: IntentOp,
    /// Action step (addLiquidity, etc.)
    action: IntentOp,
    /// Binding: validation result hash must match action expectation
    binding: ValidationBinding,
}

/// Ensures atomic execution via 7702 bundling
fn execute_validated_bundle(bundle: MMValidationBundle, state: &mut KernelState) -> Result<()> {
    // Step 1: Execute validation
    let validation_result = evaluate_op(bundle.validation, state)?;

    // Step 2: Verify binding (validation output matches action input)
    bundle.binding.verify(&validation_result)?;

    // Step 3: Execute action
    // Critical: state must be unchanged between validation and action
    evaluate_op(bundle.action, state)
}
```

**Files to modify:**

- `src/fiet-maker-policy/src/kernel/mod.rs` - Add bundle execution logic
- `src/fiet-maker-policy/src/kernel/types.rs` - Add bundle types
- `src/fiet-maker-policy/src/kernel/interfaces.rs` - Update interfaces

### 3. Fact System Extension (`src/fiet-maker-policy/src/facts/`)

#### New Fact Types for State Re-Validation

```rust
// In facts/mod.rs or new facts/validation.rs

/// Fact: Current pool state from getSlot0
pub struct PoolSlot0Fact {
    pub pool_id: PoolId,
    pub sqrt_price_x96: u160,
    pub tick: i24,
    pub observation_index: u16,
    pub observation_cardinality: u16,
    pub observation_cardinality_next: u16,
    pub fee_protocol: u8,
    pub unlocked: bool,
}

/// Fact: Computed issuance value for proposed liquidity
pub struct IssuedValueFact {
    pub effective_amount0: u256,
    pub effective_amount1: u256,
    pub issued_usd: u256,
    pub oracle_price0: u256,
    pub oracle_price1: u256,
}

/// Fact: Current backing state
pub struct BackingStateFact {
    pub signal_usd: u256,
    pub settled_usd: u256,
    pub total_backing: u256,
}
```

**Fact Implementations:**

- `PoolSlot0Fact`: Call `getSlot0` on PoolManager
- `IssuedValueFact`: Call `LiquidityUtils.calculateEffectiveTokenAmounts` with current slot0, then `OracleUtils.lccPairValue`
- `BackingStateFact`: Query position settled amounts + commit signal value from VTS

**Files to modify:**

- `src/fiet-maker-policy/src/facts/mod.rs` - Add new fact types
- `src/fiet-maker-policy/src/facts/onchain.rs` - Implement on-chain reading

### 4. Policy Encoder Updates (`tools/fiet-maker-policy-encoder/`)

#### New Encoding Functions

```rust
// In encoder.rs

/// Encode a VALIDATE_LIQUIDITY_DELTA operation
pub fn encode_validate_liquidity_delta(params: &ValidateLiquidityDeltaParams) -> Vec<u8> {
    // Opcode: 0x40
    // Followed by ABI-encoded parameters
    let mut encoded = vec![0x40];
    encoded.extend(abi_encode_params(params));
    encoded
}

/// Create a validation bundle for MM add-liquidity
pub fn create_mm_add_liquidity_bundle(
    pool_params: PoolParams,
    position_params: PositionParams,
    commit_id: U256,
    tolerances: ToleranceConfig,
) -> IntentBundle {
    let validation = encode_validate_liquidity_delta(/* ... */);
    let action = encode_add_liquidity(/* ... */);

    IntentBundle {
        ops: vec![validation, action],
        execution_mode: ExecutionMode::AtomicStrict,
    }
}
```

**Files to modify:**

- `tools/fiet-maker-policy-encoder/src/encoder.rs` - Add encoding functions
- `tools/fiet-maker-policy-encoder/src/types.rs` - Add parameter types
- `tools/fiet-maker-policy-encoder/src/tests.rs` - Add test vectors

### 5. E2E Test Coverage (`e2e/src/tests/`)

#### New Test Scenarios

**Test 1: `mm-revalidation-front-run-griefing.test.ts`**

- Simulate adversarial front-run tick manipulation
- Verify that re-validation catches the state change and reverts
- Confirm that without re-validation, the griefing succeeds

**Test 2: `mm-revalidation-tolerance-bounds.test.ts`**

- Test each tolerance parameter independently
  - `max_issued_usd`: Reject if price spike would exceed
  - `max_tick_deviation`: Reject if tick moved too far
  - `min_backing_buffer_bps`: Reject if backing margin too thin

**Test 3: `mm-revalidation-7702-bundle.test.ts`**

- Test atomic bundling under 7702
- Verify that bundled validation + action succeeds when state is stable
- Verify that bundle reverts if state changes mid-bundle (simulated)

**Files to create:**

- `e2e/src/tests/mm-revalidation-front-run-griefing.test.ts`
- `e2e/src/tests/mm-revalidation-tolerance-bounds.test.ts`
- `e2e/src/tests/mm-revalidation-7702-bundle.test.ts`

### 6. Integration with Existing MMPositionManager

The re-validation policy should be usable by MMs through their existing `MMPositionManager` workflow, but with an optional 7702-protected path:

```solidity
// In MMPositionManager (existing EVM contract)

/// @notice Add liquidity with atomic re-validation via 7702
/// @dev This function is called within a 7702 intent context
/// @param poolKey The pool key
/// @param params The modify liquidity params
/// @param hookData The hook data (contains commitId)
/// @param validationProof The 7702 policy validation result
function addLiquidityWithRevalidation(
    PoolKey calldata poolKey,
    ModifyLiquidityParams calldata params,
    bytes calldata hookData,
    bytes calldata validationProof
) external {
    // Verify validation proof was generated by trusted policy kernel
    require(verifyValidationProof(validationProof), "Invalid validation");

    // Extract validated parameters from proof
    (uint256 validatedIssuedUsd, int24 validatedTick, /* ... */) =
        decodeValidationProof(validationProof);

    // Continue with standard add liquidity flow
    // The CoreHook will re-validate, but the 7702 policy ensured
    // state was acceptable at the start of this transaction
    _addLiquidity(poolKey, params, hookData);
}
```

---

## Implementation Phases

### Phase 1: Core Infrastructure (Priority: High)

- [ ] Define `VALIDATE_LIQUIDITY_DELTA` opcode and parameters
- [ ] Implement fact types for pool state, issued value, and backing
- [ ] Add on-chain reading implementations in `facts/onchain.rs`
- [ ] Update evaluator to handle new opcode

### Phase 2: Kernel Integration (Priority: High)

- [ ] Design validation bundle types
- [ ] Implement atomic bundle execution
- [ ] Add binding verification between validation and action
- [ ] Update kernel interfaces

### Phase 3: Tooling & Encoder (Priority: Medium)

- [ ] Add encoding functions for validation operations
- [ ] Create helper functions for MM bundle generation
- [ ] Update policy encoder CLI

### Phase 4: E2E Testing (Priority: Medium)

- [ ] Implement front-run griefing simulation tests
- [ ] Add tolerance bound tests
- [ ] Create 7702 bundle integration tests

### Phase 5: Documentation & Examples (Priority: Low)

- [ ] Document MM integration patterns
- [ ] Create example policy configurations
- [ ] Update README with re-validation usage

---

## Security Considerations

1. **Validation Freshness**: The validation must occur as close to execution as possible. 7702 bundling helps, but on MEV-heavy chains, even bundled transactions can be reordered.

2. **Oracle Consistency**: The re-validation uses the same oracle prices as the core protocol. If the oracle is manipulable, the re-validation can be bypassed.

3. **Tolerance Calibration**: MMs must set realistic tolerances. Too tight = frequent self-rejection; too loose = griefing still possible.

4. **Fallback Behavior**: If 7702 is unavailable or fails, MMs can still use direct MMPositionManager calls, accepting the baseline griefing risk.

---

## Related Files in Core Protocol

- `contracts/evm/src/libraries/VTSCommitLib.sol` - Core validation logic
- `contracts/evm/src/libraries/VTSPositionLib.sol` - `_handleLiquidityIncrease` with validation
- `contracts/evm/src/libraries/Checkpoint.sol` - Grace bypass time logic
- `contracts/evm/src/VTSOrchestrator.sol` - `processPosition` entry point
- `contracts/evm/src/CoreHook.sol` - `_afterAddLiquidity` hook

---

## References

- Vulnerability #30: "Live price-based issuance validation without tolerance in MM add-liquidity hook causes transaction-level DoS via front-run price moves"
- EIP-7702: Set EOA account code
- `TruncGeoOracle.sol` (Uniswap v4): TWAP observation patterns (considered but discarded for this mitigation)

---

**Created:** 2024-03-12  
**Status:** Planning  
**Owner:** Protocol Engineering
