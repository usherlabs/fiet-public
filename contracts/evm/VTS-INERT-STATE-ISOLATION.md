# VTS Inert State Isolation

## Purpose
This note describes how Phase 1 should treat fee-era fields in [`contracts/evm/src/types/VTS.sol`](contracts/evm/src/types/VTS.sol) once those fields are no longer live on the default v1 runtime path.

The goal is not immediate deletion. The goal is to make the later deletion or extraction step safe by:
- identifying the fee-era field groups explicitly;
- keeping them conceptually separate from the base accounting model;
- documenting how those groups should later move into dedicated legacy structs, or be removed entirely if no longer needed.

## Phase 1 expectation
Runtime quarantine is keyed off **`coverageFeeShare > 0`** (`VTSFeeLinkedLib.isFeeCapabilityEnabled`): the default config uses **`coverageFeeShare == 0`**, so ambient mutation of the legacy blocks below should not occur on the default v1 path.

Phase 1 should do one of the following:

1. **Preferred when low risk**: isolate inert fee-era field groups into their own dedicated structs while preserving layout and runtime behaviour.
2. **Fallback when safer**: keep the current structs intact, but add clear comments that mark the quarantined blocks and describe the intended future split.

This note exists so that Phase 2 does not need to rediscover the boundaries from scratch.

## Current mixed accounting problem
[`PositionAccounting`](contracts/evm/src/types/VTS.sol) and [`PoolAccounting`](contracts/evm/src/types/VTS.sol) currently mix:
- base market accounting that remains core to v1;
- fee-adjustment-era accounting that becomes inert on the default path after quarantine.

That is workable during Phase 1, but it makes later removal risky unless the inert blocks are grouped deliberately.

## Suggested structural split

### Position-side
Keep these fields conceptually in the **base** position accounting model:
- `commitmentMax`
- `settled`
- `cumulativeDeficit`
- `deficitGrowthInsideLast`
- `inflowGrowthInsideLast`
- `cumulativeOutflows`
- `commitmentDeficit`
- `commitmentDeficitBps`
- `commitmentDeficitSince`

Treat these fields as the **legacy fee/capability** block:
- `feeGrowthInsideLast`
- `outflowsAtFeeSnap`
- `feesShared`
- `pendingFeeAdj`
- `coverageIndexLastX128`
- `residualCoverageIndexLastX128`
- `pendingResidualBurnBase`
- `pendingResidualFeeBacking`
- `pendingResidualBurnOutflowsFloor`
- `diceOrdinaryRealisationCarry`
- `diceResidualRealisationCarry`
- `diceOrdinaryCovAgg`
- `diceResidualCovAgg`
- `ciseIndexLastX128`
- `ciseExposureSinceLastMod`
- `feesSharedRemainingFactorLastX128`
- `feesSharedEpoch`
- `feeBurnGrowthRemainder`

Suggested future conceptual shape:

```solidity
struct PositionAccountingCore {
    TokenPairUint commitmentMax;
    TokenPairUint settled;
    TokenPairUint cumulativeDeficit;
    TokenPairUint deficitGrowthInsideLast;
    TokenPairUint inflowGrowthInsideLast;
    TokenPairUint cumulativeOutflows;
    TokenPairUint commitmentDeficit;
    uint16 commitmentDeficitBps;
    TokenPairUint commitmentDeficitSince;
}

struct PositionAccountingLegacyFee {
    TokenPairUint feeGrowthInsideLast;
    TokenPairUint outflowsAtFeeSnap;
    TokenPairUint feesShared;
    TokenPairInt pendingFeeAdj;
    TokenPairUint coverageIndexLastX128;
    TokenPairUint residualCoverageIndexLastX128;
    TokenPairUint pendingResidualBurnBase;
    TokenPairUint pendingResidualFeeBacking;
    TokenPairUint pendingResidualBurnOutflowsFloor;
    TokenPairUint diceOrdinaryRealisationCarry;
    TokenPairUint diceResidualRealisationCarry;
    TokenPairUint diceOrdinaryCovAgg;
    TokenPairUint diceResidualCovAgg;
    TokenPairUint ciseIndexLastX128;
    TokenPairUint ciseExposureSinceLastMod;
    TokenPairUint feesSharedRemainingFactorLastX128;
    TokenPairUint feesSharedEpoch;
    TokenPairUint feeBurnGrowthRemainder;
}
```

### Pool-side
Keep these fields conceptually in the **base** pool accounting model:
- `deficitGrowthGlobal`
- `inflowGrowthGlobal`

Treat these fields as the **legacy fee/capability** block:
- `slashedPot`
- `totalDeficitPrincipal`
- `coveragePerDeficitIndexX128`
- `coveragePerResidualDeficitIndexX128`
- `coverageResidualDICE`
- `totalSettled`
- `coveragePerSettledIndexX128`
- `totalCISEExposureSinceLastMod`
- `feesSharedRemainingFactorX128`
- `feesSharedEpoch`

Suggested future conceptual shape:

```solidity
struct PoolAccountingCore {
    TokenPairUint deficitGrowthGlobal;
    TokenPairUint inflowGrowthGlobal;
}

struct PoolAccountingLegacyFee {
    TokenPairUint slashedPot;
    TokenPairUint totalDeficitPrincipal;
    TokenPairUint coveragePerDeficitIndexX128;
    TokenPairUint coveragePerResidualDeficitIndexX128;
    TokenPairUint coverageResidualDICE;
    TokenPairUint totalSettled;
    TokenPairUint coveragePerSettledIndexX128;
    TokenPairUint totalCISEExposureSinceLastMod;
    TokenPairUint feesSharedRemainingFactorX128;
    TokenPairUint feesSharedEpoch;
}
```

## Phase 1 code-comment guidance
If Phase 1 does not perform the struct extraction directly, it should still annotate [`contracts/evm/src/types/VTS.sol`](contracts/evm/src/types/VTS.sol) clearly.

Recommended comment style:
- add a short banner comment before the fee-era field block in `PositionAccounting`;
- add a short banner comment before the fee-era field block in `PoolAccounting`;
- state that these fields are quarantined from the default v1 path and are retained for explicit legacy capability paths only;
- state that the block is intended for future extraction into a dedicated legacy struct during Phase 2.

The purpose of those comments is to make later removal mechanical rather than interpretive.

## Migration order for later phases
When Phase 2 begins, the safest order is:

1. prove the fields are inert on the default path;
2. keep explicit capability tests for the legacy path still passing;
3. extract or wrap the quarantined blocks into dedicated structs if needed;
4. update call sites to reference the isolated legacy block explicitly;
5. only then consider field deletion or full removal.

Do not combine:
- runtime quarantine,
- struct extraction,
- deletion,
- and test pruning

in one step unless there is a compelling reason.

## What this note is for
This file is the hand-off document from Phase 1 to later phases. It should let a future refactor answer:
- which fields are base-critical;
- which fields are quarantined;
- what the intended future struct split looks like;
- and in what order those inert fields should be removed or migrated.
