# Checkpoint and Position-Level Commitment Deficit Specification

This document specifies the overhauled checkpoint and commitment deficit mechanism in the Fiet Protocol. The redesign consolidates `declareUnbackedCommitment` and `markCheckpoint` into a unified, position-specific `checkpoint` function with O(1) complexity, eliminating position iteration whilst maintaining the critical backing invariant.

## Overview

The checkpoint mechanism serves two purposes:

1. **RFS (Ready-For-Seizure) State Tracking**: Recording when positions enter or exit RFS-open states, enabling grace period enforcement before seizure.
2. **Commitment Backing Verification**: Validating that issued LCCs remain backed by signal reserves plus settled liquidity, with position-level deficit tracking when backing is insufficient.

## The Checkpoint Problem and Solution

### The Core Problem

In the Fiet Protocol, **Liquidity Commitment Certificates (LCCs) represent claims on underlying assets** that must always be backed by either:

1. **Verified off-chain reserves** (Market Maker's signal) - proof of capital held in external accounts
2. **On-chain settled liquidity** - native tokens already deposited in the position

When a Market Maker (MM) issues LCCs against a position but their off-chain reserves decrease (due to trading losses, withdrawals, regulatory actions, etc.), the position becomes **insufficiently backed**. This creates a critical risk:

- **LCC holders have claims on assets that may not exist**
- **The protocol's solvency guarantee is compromised**
- **Other protocol participants are exposed to the MM's insolvency**

### The Checkpoint Solution

The checkpoint mechanism provides **permissionless, position-specific intervention** to detect and rectify backing shortfalls. It solves the core problem through:

#### 1. Continuous Backing Verification

Any party can call `checkpoint()` with a LiquiditySignal to verify that:

```
issuedLCCs ≤ offChainReserves + onChainSettlements
```

Where:
- `issuedLCCs` = USD value of effective token amounts in the position at current price
- `offChainReserves` = USD value of MM's verified signal reserves
- `onChainSettlements` = USD value of native tokens settled in the position

#### 2. Position-Level Deficit Tracking

When insufficient backing is detected, the system calculates a **position-specific deficit** in token units, proportional to the shortfall. This deficit:

- **Inflates RFS requirements** - forces the position into an intervention-ready state
- **Enables immediate seizure** - deficit positions can be seized without grace periods
- **Tracks recovery progress** - deficits are consumed as settlements are posted

#### 3. Economic Incentives for Intervention

The mechanism creates strong incentives for rapid intervention:

- **Advancers** (keepers who detect and declare shortfalls) get authorised to call checkpoint
- **Seizers** can immediately capture under-backed positions at favorable terms
- **Market Makers** must maintain backing or face position loss

#### 4. Recovery Pathways

Multiple paths exist to restore backing:

- **Deficit Clawback**: MMs can improve their signal, automatically reducing deficits proportionally
- **Settlement Posting**: Native tokens consume deficits before increasing settled amounts
- **Position Seizure**: Third parties can settle inflated RFS requirements and seize positions

### How It Works: Step-by-Step

#### Step 1: Checkpoint Initiation

```solidity
// Keeper detects potential backing issue
positionManager.checkpoint(commitId, positionIndex, liquiditySignal);
```

#### Step 2: RFS State Calculation

The system first calculates the current RFS (Ready-For-Seizure) state:

```solidity
// Calculate current VTS requirements vs settled amounts
bool rfsOpen = calcRFS(positionId); // Is position under-collateralized?

// Mark the checkpoint state transition
markCheckpoint(positionId, rfsOpen);
```

#### Step 3: Backing Verification (if withCommitment = true)

If a LiquiditySignal is provided, verify the backing invariant:

```solidity
// Get effective issued amounts at current price
(uint256 issued0, uint256 issued1) = calculateEffectiveTokenAmounts(position);
uint256 issuedUsd = oracle.getValue(issued0, issued1);

// Get signal reserves
uint256 signalUsd = signalManager.getTotalValue(mmState);

// Get settled amounts
uint256 settledUsd = oracle.getValue(settled0, settled1);

// Check invariant
uint256 backingUsd = signalUsd + settledUsd;
if (issuedUsd > backingUsd) {
    // Insufficient backing - calculate deficit
    uint256 deficitUsd = issuedUsd - backingUsd;

    // Convert to position-level deficit in token units
    uint256 deficitBps = (deficitUsd * BPS) / issuedUsd;
    pa.commitmentDeficit.token0 = (issued0 * deficitBps) / BPS;
    pa.commitmentDeficit.token1 = (issued1 * deficitBps) / BPS;
}
```

#### Step 4: Intervention Enablement

With deficits recorded, the position becomes immediately seizable:

```solidity
// Position can now be seized without grace period
if (pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0) {
    // Immediate seizure enabled
    canSeize = true;
}
```

#### Step 5: Recovery or Seizure

**Recovery Path**: MM improves backing through signal renewal:
- Deficit reduces proportionally to surplus
- Full surplus clears deficit entirely

**Intervention Path**: Third party seizes:
- Posts settlements covering inflated RFS requirements
- Receives seized position liquidity
- Becomes new position owner

### Economic Impact

The checkpoint mechanism transforms a systemic risk into an economic opportunity:

- **For Keepers**: Revenue from monitoring and declaring backing issues
- **For Seizers**: Profitable intervention in under-collateralized positions
- **For MMs**: Strong incentive to maintain reserves and monitor backing
- **For Protocol**: Guaranteed solvency through enforceable backing requirements

### Why Position-Specific, O(1) Design?

**Previous Approach**: Commit-level iteration (O(n) positions)
- Required visiting every position in a commitment
- Gas costs scaled with position count
- Complex state aggregation

**New Approach**: Position-specific checkpointing (O(1))
- Each position checkpointed independently
- Constant gas costs regardless of commit size
- Granular deficit tracking enables precise intervention
- Eliminates iteration bottlenecks

This design ensures the protocol can scale to thousands of positions per commitment whilst maintaining the critical backing guarantee.

## Architecture

### Component Hierarchy

```
MMPositionManager (Entry Point)
    │
    ├── CheckpointEntrypoints (Abstract Module)
    │   └── _checkpoint() - internal virtual, overridden by MMPositionManager
    │
    ├── VTSOrchestrator.checkpoint() - orchestrates RFS + commitment checks
    │   │
    │   ├── VTSPositionLib.calcRFS() - calculates RFS state
    │   │
    │   ├── CheckpointLibrary.markCheckpoint() - marks RFS state transition
    │   │
    │   └── VTSCommitLib.checkpoint() - commitment backing verification (if withCommitment)
    │
    └── Events: Checkpointed, GracePeriodExtended
```

### Data Structures

#### Position-Level Checkpoint (`RFSCheckpoint`)

```solidity
struct RFSCheckpoint {
    uint256 timeOfLastTransition;    // Timestamp when RFS state last changed
    bool isOpen;                      // Whether RFS is currently open
    uint256 gracePeriodExtension0;    // Extension to token0 grace period
    uint256 gracePeriodExtension1;    // Extension to token1 grace period
}
```

**Location**: Embedded directly in `Position` struct (not a separate mapping).

#### Position-Level Deficit (`PositionAccounting.commitmentDeficit`)

```solidity
struct PositionAccounting {
    // ... other fields ...
    TokenPairUint commitmentDeficit;  // Position-scoped deficit in token units
}
```

**Key Design Decision**: Deficits are stored at the position level, not the commit level. This enables:
- O(1) checkpoint operations (no position iteration)
- Granular deficit tracking per position
- Independent deficit resolution per position

## Checkpoint Function

### Interface

```solidity
// CheckpointEntrypoints.sol - External entry points
function checkpoint(uint256 tokenId, uint256 positionIndex) external;
function checkpoint(uint256 tokenId, uint256 positionIndex, bytes calldata liquiditySignal) external;

// VTSOrchestrator.sol - Internal orchestration
function checkpoint(
    address sender,
    uint256 commitId,
    uint256 positionIndex,
    bytes memory liquiditySignal,
    bool withCommitment
) external onlyMMPositionManager;
```

### Behaviour

The `checkpoint` function operates in two modes determined by the `withCommitment` boolean:

| Mode | `withCommitment` | Signal Required | Actions |
|------|------------------|-----------------|---------|
| Basic | `false` | No | Marks RFS checkpoint only |
| Full | `true` | Yes | Marks RFS checkpoint + validates backing + updates deficits |

### Flow Diagram

```
checkpoint(sender, commitId, positionIndex, liquiditySignal, withCommitment)
    │
    ├── 1. Resolve positionId from commitId + positionIndex
    │
    ├── 2. Calculate RFS state via VTSPositionLib.calcRFS()
    │       └── Returns (rfsOpen: bool, delta: BalanceDelta)
    │
    ├── 3. Mark RFS checkpoint via CheckpointLibrary.markCheckpoint()
    │       └── Updates position.checkpoint.isOpen and timeOfLastTransition
    │
    ├── 4. Emit Checkpointed event
    │
    └── 5. IF withCommitment:
            └── Call VTSCommitLib.checkpoint() for backing verification
```

## Commitment Backing Verification

When `withCommitment` is `true`, the checkpoint function verifies the backing invariant for the specific position.

### The Invariant

For any position within a commitment:

$$
\text{issuedUsd} \leq \text{signalUsd} + \text{settledUsd}
$$

**Where:**

- $\text{issuedUsd}$: USD value of effective LCC amounts issued for this position, calculated at current pool price.
- $\text{signalUsd}$: USD value of verified off-chain reserves from the MarketMaker's LiquiditySignal.
- $\text{settledUsd}$: USD value of on-chain settled liquidity for this position.

### Effective Token Amount Calculation

Issued amounts are derived from **effective token amounts** at the current pool price, not commitment maxima:

```solidity
(uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
(uint256 eff0, uint256 eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
    sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, int256(pos.liquidity)
);
uint256 issuedUsd = OracleUtils.lccPairValue(oracleHelper, currency0, eff0, currency1, eff1);
```

This ensures the backing check reflects the actual exposure of the position at the current price, rather than the maximum potential exposure.

### Authorisation

The commitment backing verification requires:

1. **Valid Signal**: The LiquiditySignal must be verified by VRLSignalManager.
2. **Owner Consistency**: `newSignal.mmState.owner == oldMmState.owner`
3. **Advancer Authorisation**: `sender == newSignal.mmState.advancer`
4. **No Self-Declaration**: `advancer ≠ owner` (prevents MM from declaring their own positions unbacked)

```solidity
if (
    newSignal.mmState.owner != oldMmState.owner ||
    sender != newSignal.mmState.advancer ||
    newSignal.mmState.advancer == newSignal.mmState.owner
) {
    revert Errors.InvalidSender();
}
```

## Deficit Calculation and Update

### Case 1: Sufficient Backing (No New Deficit)

When $\text{issuedUsd} \leq \text{backingUsd}$:

```solidity
uint256 backingUsd = signalUsd + settledUsd;

if (issuedUsd <= backingUsd) {
    // Backing sufficient - reduce/clear existing deficit if present
    uint256 currentDeficitUsd = OracleUtils.lccPairValue(..., pa.commitmentDeficit.token0, ..., pa.commitmentDeficit.token1);
    
    if (currentDeficitUsd > 0) {
        uint256 surplusUsd = backingUsd - issuedUsd;
        
        if (surplusUsd >= currentDeficitUsd) {
            // Full deficit clearance
            pa.commitmentDeficit.token0 = 0;
            pa.commitmentDeficit.token1 = 0;
        } else {
            // Proportional reduction
            uint256 reduce0 = FullMath.mulDiv(pa.commitmentDeficit.token0, surplusUsd, currentDeficitUsd);
            uint256 reduce1 = FullMath.mulDiv(pa.commitmentDeficit.token1, surplusUsd, currentDeficitUsd);
            
            pa.commitmentDeficit.token0 -= reduce0;
            pa.commitmentDeficit.token1 -= reduce1;
        }
    }
}
```

**Deficit Clawback**: When backing improves (signal increases or settlements occur), existing deficits are reduced proportionally to the surplus. This provides a path for MMs to recover from temporary backing shortfalls without requiring complete deficit elimination in a single transaction.

### Case 2: Insufficient Backing (New Deficit)

When $\text{issuedUsd} > \text{backingUsd}$:

```solidity
uint256 deficitUsd = issuedUsd - backingUsd;
uint256 deficitBps = FullMath.mulDiv(deficitUsd, LiquidityUtils.BPS_DENOMINATOR, issuedUsd);

// Apply deficit proportionally to effective amounts
uint256 def0 = FullMath.mulDiv(eff0, deficitBps, LiquidityUtils.BPS_DENOMINATOR);
uint256 def1 = FullMath.mulDiv(eff1, deficitBps, LiquidityUtils.BPS_DENOMINATOR);

pa.commitmentDeficit.token0 = def0;
pa.commitmentDeficit.token1 = def1;
```

The deficit is expressed in token units proportional to the effective amounts, ensuring consistent inflation of RFS requirements.

### Mathematical Properties

**Deficit BPS Bounds:**
$$
0 \leq \text{deficitBps} \leq 10000
$$

Since $\text{deficitUsd} \leq \text{issuedUsd}$, the deficit BPS cannot exceed 100%.

**Deficit Unit Calculation:**
$$
\text{def}_0 = \text{eff}_0 \times \frac{\text{deficitBps}}{10000}
$$
$$
\text{def}_1 = \text{eff}_1 \times \frac{\text{deficitBps}}{10000}
$$

## Seizability Determination

A position is seizable through two paths:

### Path 1: Position-Level Deficit

If `pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0`, the position is **immediately seizable** without grace period checks. The deficit indicates a declared backing shortfall that requires intervention.

### Path 2: RFS Grace Period Elapsed

If the position's RFS checkpoint is open AND the grace period has elapsed:

```solidity
bool gracePeriod0Elapsed = timeSinceLastCheckpoint > (vtsConf.token0.gracePeriodTime + checkpoint.gracePeriodExtension0);
bool gracePeriod1Elapsed = timeSinceLastCheckpoint > (vtsConf.token1.gracePeriodTime + checkpoint.gracePeriodExtension1);
canSeize = gracePeriod0Elapsed || gracePeriod1Elapsed;
```

### Seizability Check Implementation

```solidity
function isSeizable(VTSStorage storage s, uint256 commitId, uint256 positionIndex, bool revertOnFalse)
    internal view returns (bool canSeize)
{
    PositionId positionId = commit.positions[positionIndex];
    PositionAccounting storage pa = s.positionAccounting[positionId];
    
    // Path 1: Immediate seizure via deficit
    if (pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0) {
        return true;
    }
    
    // Path 2: RFS grace period check
    RFSCheckpoint memory checkpoint = s.positions[positionId].checkpoint;
    if (!checkpoint.isOpen) {
        if (revertOnFalse) revert Errors.RFSNotOpenForPosition(positionId);
        return false;
    }
    
    // Grace period calculations...
}
```

## Settlement and Deficit Consumption

When positive settlements occur, they net against the position's commitment deficit before increasing settled amounts:

```solidity
// In VTSPositionLib._updateSettlement
if (delta > 0 && pa.commitmentDeficit.token0 > 0) {
    uint256 consume = Math.min(uint256(delta), pa.commitmentDeficit.token0);
    pa.commitmentDeficit.token0 -= consume;
    delta -= int256(consume);
}
// Similar for token1
```

**Important Note**: Settling native tokens does NOT increase backing signal. It only decreases/nets against the deficit. The backing equation is:

$$
\text{backing} = \text{signal} + \text{settled}
$$

Where signal represents off-chain reserves, and settled represents on-chain liquidity already in the position.

## Key Design Differences from Previous Implementation

| Aspect | Previous | Current |
|--------|----------|---------|
| **Deficit Storage** | Commit-level `deficitBps` | Position-level `commitmentDeficit` (token units) |
| **Position Iteration** | Required (O(n)) | Eliminated (O(1)) |
| **Checkpoint Storage** | Separate `checkpoints` mapping | Embedded in `Position` struct |
| **Function Consolidation** | Separate `markCheckpoint` and `declareUnbackedCommitment` | Unified `checkpoint` with `withCommitment` flag |
| **Issued Value Calculation** | Commit-level aggregates from `commitmentMaxTotal` | Position-specific effective amounts at current price |
| **Deficit Clearance** | Required signal renewal | Automatic clawback on backing improvement |
| **Commit Struct** | Included `settled`, `commitmentMaxTotal`, `deficitBps` | Minimal: `mmState`, `expiresAt`, `positions`, `positionCount` |

## Events

```solidity
event Checkpointed(uint256 commitId, uint256 positionIndex, RFSCheckpoint checkpoint, bool withCommitment);
event GracePeriodExtended(uint256 commitId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);
event PositionSettled(
    uint256 indexed commitId,
    uint256 indexed positionIndex,
    int128 settlementDelta0,
    int128 settlementDelta1,
    uint256 settledToken0,
    uint256 settledToken1,
    bool isSeizing,
    bool rfsOpen
);
```

## API Reference

### CheckpointEntrypoints

```solidity
/// @notice Marks a checkpoint for a single position (RFS state only)
function checkpoint(uint256 tokenId, uint256 positionIndex) external;

/// @notice Marks a checkpoint with commitment backing verification
function checkpoint(uint256 tokenId, uint256 positionIndex, bytes calldata liquiditySignal) external;
```

### IVTSOrchestrator

```solidity
/// @notice Full checkpoint function with all options
function checkpoint(
    address sender,
    uint256 commitId,
    uint256 positionIndex,
    bytes memory liquiditySignal,
    bool withCommitment
) external;

/// @notice Get commit details
function getCommit(uint256 commitId)
    external view returns (MarketMaker.State memory mmState, uint256 expiresAt, uint256 positionCount);

/// @notice Get position commitment maxima
function getCommitmentMaxima(PositionId positionId)
    external view returns (uint256 commitment0, uint256 commitment1);
```

## Example Scenarios

### Scenario 1: Basic Checkpoint (RFS Marking)

A keeper wants to mark the current RFS state for a position:

```solidity
positionManager.checkpoint(tokenId, positionIndex);
// Only marks RFS state, no backing check
```

### Scenario 2: Full Checkpoint with Backing Verification

An advancer detects insufficient backing and wants to declare it:

```solidity
positionManager.checkpoint(tokenId, positionIndex, liquiditySignal);
// Marks RFS + verifies backing + updates deficit if insufficient
```

### Scenario 3: Deficit Clawback

A position has a deficit of 1000 token0 and 500 token1. The MM improves their signal, creating a 20% surplus:

- Current deficit USD: $1500
- Surplus USD: $300 (20% of $1500)
- New deficit token0: $1000 - (1000 × 0.20) = 800$
- New deficit token1: $500 - (500 × 0.20) = 400$

### Scenario 4: Immediate Seizure via Deficit

A position has `commitmentDeficit.token0 = 500`:

```solidity
// isSeizable returns true immediately - no grace period check needed
bool canSeize = CheckpointLibrary.isSeizable(s, commitId, positionIndex, false);
// canSeize = true
```

## Security Considerations

### Self-Declaration Prevention

The advancer authorisation requirements prevent MMs from declaring their own positions unbacked:
- Caller must be the advancer specified in the signal
- Advancer cannot equal the owner
- Signal owner must match commit owner

### Oracle Dependency

USD value calculations rely on oracle prices. Mitigations:
- Signal proofs limit manipulation vectors
- Competitive advancer market ensures accurate declarations
- RFS and seizure mechanisms provide additional safety layers

### No Commit-Level Running Totals

The removal of commit-level aggregates (`settled`, `commitmentMaxTotal`) eliminates the need for expensive iteration whilst ensuring position-level accuracy. Each position's backing is verified independently using current effective amounts.

## Conclusion

The overhauled checkpoint mechanism provides a unified, efficient approach to RFS state tracking and commitment backing verification. By eliminating position iteration and storing deficits at the position level, the system achieves O(1) complexity whilst maintaining the critical backing invariant. The deficit clawback mechanism provides a recovery path for MMs, whilst immediate seizability through position-level deficits ensures rapid intervention when backing shortfalls are detected.
