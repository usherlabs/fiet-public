[Informational] Floor conversion without remainder tracking in VTSPositionLib._rebaseResidualFeeGrowthOnActiveIncrease during active add-liquidity causes dust-level underfunding of slashed pot and bonuses

# Description

When adding liquidity to an already-active position with an open residual-burn episode, pre-add fee backing is banked using a floored conversion and the fee-growth snapshot is advanced without tracking the discarded fraction, permanently losing <1 raw token unit per event, slightly underfunding the slashed pot and bonuses.

In VTSPositionLib._rebaseResidualFeeGrowthOnActiveIncrease, if a position is already active and a residual-burn episode is open for one deficit lane, the function banks pre-add fee backing as floor((fg - feeGrowthInsideLast) * liquidityBeforeAdd / Q128) into pendingResidualFeeBacking for the opposite fee lane(s), then advances feeGrowthInsideLast to fg. No remainder is stored for the discarded fractional part. Because the snapshot moves forward, the fractional remainder from that pre-add window is unrecoverable. Later, when residual burns are applied via VTSFeeLib._applyBankedResidualBurn/_applyBurnBase/_calculateFeesBurn, the pot is funded from the banked amount only; thus the slashed pot and subsequent bonus allocations (CISE) are slightly reduced. CoreHook._beforeAddLiquidity triggers settlePositionGrowths first, which may consume part of the fresh fees, but any remaining pre-add window handled by _rebaseResidualFeeGrowthOnActiveIncrease still incurs the floor-and-advance behavior. Each event loses strictly less than 1 raw token unit per fee lane and cannot realistically aggregate into material loss without highly uneconomic repetition.

# Severity

**Impact Explanation:** [Low] The per-event underfunding is strictly less than 1 raw token unit per fee lane, does not affect principal or invariants, and results only in a dust-level reduction of the slashed pot and bonuses.

**Likelihood Explanation:** [Low] Exploitation at scale requires maintaining residual episodes, interleaving swaps to ensure fresh fee growth before each add, and repeating many adds, which is economically irrational relative to dust-level benefit.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Attacker repeatedly performs small add-liquidity operations during an open residual-burn episode, interleaving with swap activity to ensure fresh fee growth before each add. Each add banks floor((fg - last) * L_before / Q128) for the fee lane and advances the snapshot, discarding <1 raw token unit per event. Over many operations, this slightly underfunds the slashed pot and reduces bonuses, while the attacker marginally avoids being slashed by that dust.
#### Preconditions / Assumptions
- (a). Position is active (nonzero liquidity) before the add
- (b). A residual-burn episode is open on one deficit lane (pendingResidualBurnBase for that lane > 0)
- (c). Fresh fee growth has accrued on the opposite fee lane since the last fee snapshot (fg > feeGrowthInsideLast)
- (d). Liquidity increase is executed (liquidityBeforeAdd > 0)
- (e). Interleaved swaps to repeatedly advance fee growth between adds
- (f). Settle pipeline before the add does not fully consume the fresh fee window (optional but increases effect)

### Scenario 2.
An honest LP adds liquidity during normal operations while a residual-burn episode is open and some fee growth exists since the last snapshot. The pre-add window is banked with flooring and the snapshot is advanced, permanently discarding the fractional remainder and very slightly reducing future slashed-pot funding and bonuses.
#### Preconditions / Assumptions
- (a). Position is active (nonzero liquidity) before the add
- (b). A residual-burn episode is open on one deficit lane
- (c). Some swap-driven fee growth on the opposite fee lane since the last fee snapshot
- (d). User performs a routine add-liquidity

# Proposed fix

## VTS.sol

File: `contracts/evm/src/types/VTS.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/types/VTS.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {Commit} from "./Commit.sol";
 import {PositionId, Position} from "./Position.sol";
 import {Pool} from "./Pool.sol";
 import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
 import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
 import {IVRLSignalManager} from "../interfaces/IVRLSignalManager.sol";
 import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 
 struct TokenConfiguration {
     // Grace period time
     uint256 gracePeriodTime;
     // Base VTS Rate in bps (basis points)
     uint256 baseVTSRate;
     // Max grace period time
     uint256 maxGracePeriodTime;
     // Minimum time a non-zero commitment deficit must persist before grace bypass is allowed (0 disables age gating)
     uint256 unbackedCommitmentGraceBypassTime;
     // Optional token deficit threshold used only when deficit bps is below bypass bps (0 disables)
     uint256 unbackedCommitmentGraceBypassThreshold;
 }
 
 // forge-lint: disable-next-line(pascal-case-struct)
 struct MarketVTSConfiguration {
     // Token configuration for token0
     TokenConfiguration token0;
     // Token configuration for token1
     TokenConfiguration token1;
     // Fee share applied to LP fees when protocol covers deficits (in basis points)
     uint16 coverageFeeShare;
     // Minimum residual liquidity units threshold for full position closure during seizure
     uint256 minResidualUnits;
     // Commitment deficit severity threshold (bps) above which grace bypass is allowed
     uint16 unbackedCommitmentGraceBypassBps;
 }
 
 /// @notice Context struct for position processing dependencies
 /// @dev Passed to VTSPositionLib.touchPosition to provide access to external contracts
 struct PositionContext {
     // PoolManager for position queries and state management
     IPoolManager poolManager;
     // LiquidityHub for LCC issuance/cancellation
     ILiquidityHub liquidityHub;
     // OracleHelper for commitment validation
     IOracleHelper oracleHelper;
     // Market vault address for settlement clamping
     IMarketVault marketVault;
 }
 
 /// @notice Lightweight orchestrator context for lifecycle library paths
 struct VTSLifecycleContext {
     IPoolManager poolManager;
     ILiquidityHub liquidityHub;
     IOracleHelper oracleHelper;
     IVRLSettlementObserver settlementObserver;
 }
 
 /// @notice CoreHook processing context before market-vault resolution
 struct VTSCoreHookContext {
     IPoolManager poolManager;
     ILiquidityHub liquidityHub;
     IOracleHelper oracleHelper;
 }
 
 /// @notice Routing context for commit/renew entrypoints
 struct VTSCommitRouterContext {
     ILiquidityHub liquidityHub;
     IVRLSignalManager signalManager;
     /// @dev Used to enforce signal admission (oracle-priceable reserve set) on commit/renew.
     IOracleHelper oracleHelper;
 }
 
 /// @notice Parameters for touchPosition to reduce stack pressure
 /// @dev Bundles external call parameters into single struct
 struct TouchPositionParams {
     // The owner of the position
     address owner;
     // The pool key (needed for LCC operations and currency access)
     PoolKey poolKey;
     // The modify liquidity params
     ModifyLiquidityParams params;
     // The caller delta from poolManager.modifyLiquidity
     BalanceDelta callerDelta;
     // The fees accrued from poolManager.modifyLiquidity
     BalanceDelta feesAccrued;
     // The hook data containing PositionModificationHookData
     bytes hookData;
 }
 
 /// @notice Result of touchPosition to reduce stack pressure
 /// @dev Bundles return values into a single struct. When hook data indicates an MM operation, the MM tail
 ///      (`VTSPositionMMOpsLib.processMMOperations`) runs inside `touchPosition` before `pos` is finalised.
 ///      `pos` is always reloaded from storage at the end of `touchPosition` so it reflects checkpointing and other
 ///      MM-tail updates in the same call.
 struct TouchPositionResult {
     // The position struct
     Position pos;
     // The position id
     PositionId id;
     // The fee adjustment delta
     BalanceDelta feeAdj;
 }
 
 /// @notice Parameters for onMMSettle to reduce stack pressure
 /// @dev Bundles settlement parameters into single struct
 struct SettleParams {
     // The market vault interface for liquidity availability checks
     IMarketVault vault;
     // The position id
     PositionId positionId;
     // The pool currency of the LCC token for token0
     Currency lccCurrency0;
     // The pool currency of the LCC token for token1
     Currency lccCurrency1;
     // The balance delta of the settlement
     BalanceDelta delta;
     // Whether the position is being seized
     bool isSeizing;
     // When true, deposit lanes settle from existing positive underlying delta (explicit settle-from-deltas path). No-op for withdrawals.
     bool fromDeltas;
 }
 
 /// @notice Explicit vault execution intent computed by VTS settlement paths.
 /// @dev `requestedDelta` is the final vault delta to execute after VTS-side clamping.
 ///      `creditBackedWithdrawal{0,1}` describe the portion of positive withdrawal lanes that
 ///      are funded by produced same-underlying credit rather than the destination market reserve.
 struct VaultSettlementIntent {
     BalanceDelta requestedDelta;
     uint256 creditBackedWithdrawal0;
     uint256 creditBackedWithdrawal1;
 }
 
 /// @notice Result of onMMSettle to reduce stack pressure
 /// @dev Bundles return values into single struct
 struct SettleResult {
     // The delta actually applied to underlying
     BalanceDelta settlementDelta;
     // Explicit vault execution intent for downstream custody calls.
     VaultSettlementIntent vaultSettlementIntent;
     // Whether the RFS is open for the position
     bool rfsOpen;
     // The amount of liquidity units seized (non-zero only when seizing)
     uint256 seizedLiquidityUnits;
 }
 
 /// @notice Per-position accounting data (mirrors VTSManager per-position mappings)
 /// @dev Split out of VTSManager to follow the Bunni-style storage pattern
 struct PositionAccounting {
     // Commitment maxima per token
     TokenPairUint commitmentMax;
     // Settled amounts per token
     TokenPairUint settled;
     // Cumulative deficit per token (raw units)
     TokenPairUint cumulativeDeficit;
     // Deficit growth snapshots per token
     TokenPairUint deficitGrowthInsideLast;
     // Inflow growth snapshots per token
     TokenPairUint inflowGrowthInsideLast;
     // Fee growth snapshots per token
     TokenPairUint feeGrowthInsideLast;
     // Cumulative outflows per token
     TokenPairUint cumulativeOutflows;
     // Outflow snapshots at last fee snap per token
     TokenPairUint outflowsAtFeeSnap;
     // Commitment-scoped deficit (insolvency gate) per token.
     // Derived from checkpoint backing shortfall; not part of DICE principal accounting.
     TokenPairUint commitmentDeficit;
     // Commitment deficit severity in bps (0-10000), updated by commitment checkpoints
     uint16 commitmentDeficitBps;
     // Timestamp at which commitment deficit became non-zero per token (0 when token deficit is zero)
     TokenPairUint commitmentDeficitSince;
     // Fees shared by position per token
     TokenPairUint feesShared;
     // Pending fee adjustments per token: +slash (reduces payout), -bonus (increases payout)
     TokenPairInt pendingFeeAdj;
     // DICE: Coverage index checkpoint per token (snapshot of pool index at last settlement)
     TokenPairUint coverageIndexLastX128;
     // DICE: Residual-only coverage index checkpoint per token
     TokenPairUint residualCoverageIndexLastX128;
     // DICE: Banked residual-derived burn base awaiting a later outflow window
     TokenPairUint pendingResidualBurnBase;
     // DICE: Historical fee backing frozen for the currently unresolved residual-burn episode across
     // zero-liquidity intervals and partial liquidity decreases (removed slice). Stored by fee token lane
     // (opposite the deficit token lane) and cleared once that matching residual burn base is fully consumed.
     TokenPairUint pendingResidualFeeBacking;
     // DICE: Outflow watermark captured when residual burn base is banked
     TokenPairUint pendingResidualBurnOutflowsFloor;
     // CISE: Position checkpoint of pool coverage-per-settled index (Q128)
     TokenPairUint ciseIndexLastX128;
     // CISE: Banked realised exposure since last bonus allocation
     TokenPairUint ciseExposureSinceLastMod;
     // CSI: Position checkpoint of the pool remaining-share factor (Q128), last synced from pool for this position.
     // Interpret `feesSharedRemainingFactorLastX128` together with `feesSharedEpoch` on the same token lane:
     // when the position epoch matches the pool epoch, `factor == 0` is the baseline sentinel meaning "no prior
     // remaining-share checkpoint in this epoch yet" and the next sync should adopt the pool factor, not treat the
     // position as fully spent. Fully spent state is represented by `feesShared == 0`, not by a zero factor alone.
     TokenPairUint feesSharedRemainingFactorLastX128;
     // CSI: Position checkpoint of the pool spend epoch (per token), advanced with the pool on sync / setup.
     TokenPairUint feesSharedEpoch;
     // Remainder numerator for coverage fee-burn baseline checkpoint (see VTSFeeLib._applyBurnBase).
     TokenPairUint feeBurnGrowthRemainder;
+    // FIX: To eliminate dust-level loss when banking residual fee backing during rebase events,
+    // add a per-fee-lane Q128 remainder accumulator for residual banking (episode-scoped).
+    // This stores carry in [0, FixedPoint128.Q128 - 1] and is cleared when the residual episode resolves.
+    // TokenPairUint residualFeeBackingRemainderX128;
 }
 
 /// @notice Per-pool accounting data (mirrors VTSManager per-pool mappings)
 /// @dev Split out of VTSManager to follow the Bunni-style storage pattern
 struct PoolAccounting {
     // Deficit growth global per token
     TokenPairUint deficitGrowthGlobal;
     // Inflow growth global per token
     TokenPairUint inflowGrowthGlobal;
     // Materialised slashed-pot balances per token (authoritative budget for bonus allocation after positive
     // `pendingFeeAdj` materialisation in `VTSFeeLib`; ERC6909 backing is settled via the hook)
     TokenPairUint slashedPot;
     // DICE: Pool-wide outstanding swap-incurred deficit principal per token.
     // Mirrors summed cumulativeDeficit and excludes commitmentDeficit.
     TokenPairUint totalDeficitPrincipal;
     // DICE: Coverage-per-deficit-unit index (Q128) per token
     TokenPairUint coveragePerDeficitIndexX128;
     // DICE: Residual-only coverage-per-deficit-unit index (Q128) per token
     TokenPairUint coveragePerResidualDeficitIndexX128;
     // DICE: Deferred coverage residual (socialised when totalDeficitPrincipal = 0 at exercise time)
     TokenPairUint coverageResidualDICE;
     // CISE: Pool-wide total settled aggregate per token
     TokenPairUint totalSettled;
     // CISE: Coverage-per-settled index (Q128) per token
     TokenPairUint coveragePerSettledIndexX128;
     // CISE: Pool-wide bonus denominator window: incremented by coveredAmount on each allocatable coverage index step
     // and decremented when bonuses are allocated. Position numerators accrue lazily. Coverage exercised while
     // `totalSettled == 0` is intentionally excluded from CISE rather than being deferred and socialised later.
     TokenPairUint totalCISEExposureSinceLastMod;
     // CSI: Pool-wide remaining-share factor (Q128). Zero means either "no spend this epoch yet" or
     // "epoch fully spent"; `feesSharedEpoch` disambiguates replacement epochs.
     TokenPairUint feesSharedRemainingFactorX128;
     // CSI: Pool-wide spend epoch, incremented when a fully-spent epoch is replaced by fresh contributions.
     TokenPairUint feesSharedEpoch;
 }
 
 /// @notice Simple pair struct for per-tick growth (replaces uint256[2] arrays)
 struct GrowthPair {
     uint256 token0;
     uint256 token1;
 }
 
 /// @notice Pair struct for uint256 values per token (token0 and token1)
 /// @dev Similar to GrowthPair but used for general accounting fields
 struct TokenPairUint {
     uint256 token0;
     uint256 token1;
 }
 
 /// @notice Pair struct for int256 values per token (token0 and token1)
 /// @dev Used for signed accounting fields like net settlement and fee adjustments
 struct TokenPairInt {
     int256 token0;
     int256 token1;
 }
 
 /// @title TokenPairLib
 /// @notice Library for accessing TokenPair fields by tokenIndex
 /// @dev Provides get/set helpers to replace manual if (tokenIndex == 0) branching
 library TokenPairLib {
     /// @notice Get the value for a specific token index from a TokenPairUint
     /// @param self The TokenPairUint storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @return The value for the specified token
     function get(TokenPairUint storage self, uint8 tokenIndex) internal view returns (uint256) {
         return tokenIndex == 0 ? self.token0 : self.token1;
     }
 
     /// @notice Set the value for a specific token index in a TokenPairUint
     /// @param self The TokenPairUint storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param value The value to set
     function set(TokenPairUint storage self, uint8 tokenIndex, uint256 value) internal {
         if (tokenIndex == 0) {
             self.token0 = value;
         } else {
             self.token1 = value;
         }
     }
 
     /// @notice Get the value for a specific token index from a TokenPairInt
     /// @param self The TokenPairInt storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @return The value for the specified token
     function get(TokenPairInt storage self, uint8 tokenIndex) internal view returns (int256) {
         return tokenIndex == 0 ? self.token0 : self.token1;
     }
 
     /// @notice Set the value for a specific token index in a TokenPairInt
     /// @param self The TokenPairInt storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param value The value to set
     function set(TokenPairInt storage self, uint8 tokenIndex, int256 value) internal {
         if (tokenIndex == 0) {
             self.token0 = value;
         } else {
             self.token1 = value;
         }
     }
 }
 
 /// @notice Central storage struct (like Bunni's HubStorage)
 /// @dev Contains all state mappings for pools, commits, positions and accounting
 /// ? need a mapping from CommitId => PositionIndex => PositionId
 // forge-lint: disable-next-line(pascal-case-struct)
 struct VTSStorage {
     /// Per-pool state
     mapping(PoolId => Pool) pools;
     /// Per-pool accounting state
     mapping(PoolId => PoolAccounting) poolAccounting;
     /// Per-commit (CommitId) state
     mapping(uint256 => Commit) commits;
     /// Per-position state
     mapping(PositionId => Position) positions;
     /// Per-position accounting state
     mapping(PositionId => PositionAccounting) positionAccounting;
     /// Per-pool per-tick deficit growth outside
     mapping(PoolId => mapping(int24 => GrowthPair)) deficitGrowthOutside;
     /// Per-pool per-tick inflow growth outside
     mapping(PoolId => mapping(int24 => GrowthPair)) inflowGrowthOutside;
     /// Next commit ID for commit NFTs (starts at 1)
     uint256 nextCommitId;
     /// Global pause flag
     bool isPaused;
 }
```

## VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionLibrary,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 
 /// @title VTSPositionLib
 /// @notice Position lifecycle, registration, RFS, settlement, seizure, and growth accounting for VTS
 /// @dev External functions (called via VTSPositionLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSPositionLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using SafeCast for int128;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
     using StateLibrary for IPoolManager;
     using PoolIdLibrary for PoolKey;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in `VTSPositionMMOpsLib` liquidity increase.
     struct LiquidityIncreaseParams {
         address owner;
         uint256 commitId;
         PositionId positionId;
         BalanceDelta principalDelta;
     }
 
     /// @dev Internal struct to reduce stack depth in _deltaAndCheckpointGrowth
     struct GrowthParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
         uint128 liquidity;
         uint256 global0;
         uint256 global1;
         bool isInflow;
     }
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Sets `commitmentMax` from live Uniswap position liquidity (single source of truth).
     /// @dev Per-delta rounded add/subtract bookkeeping is not equivalent to rounding once on the total;
     ///      incremental `ceil` arithmetic can drift below the true maxima for the remaining range.
     ///      Always derive from `liveLiquidity` after any modify that changes pool position liquidity.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param liveLiquidity Current position liquidity from PoolManager after the modify
     function _trackCommitment(VTSStorage storage s, PositionId positionId, uint128 liveLiquidity) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (liveLiquidity == 0) {
             pa.commitmentMax.token0 = 0;
             pa.commitmentMax.token1 = 0;
             return;
         }
         Position memory pos = s.positions[positionId];
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(pos.tickLower, pos.tickUpper, liveLiquidity);
         pa.commitmentMax.token0 = c0;
         pa.commitmentMax.token1 = c1;
     }
 
     // --------------------------------------------------
     // Settlement Updates
     // --------------------------------------------------
 
     /// @notice Applies a settled delta to the pool-wide `totalSettled` aggregate
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param settledDelta The signed settled delta to apply
     function _applyPoolTotalSettledDelta(PoolAccounting storage paPool, uint8 tokenIndex, int256 settledDelta) private {
         if (settledDelta == 0) return;
 
         uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
 
         if (settledDelta >= 0) {
             paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
         } else {
             uint256 decSettled = uint256(-settledDelta);
             if (decSettled > currentTotalSettled) {
                 revert Errors.InvariantViolated("pool totalSettled underflow");
             }
             paPool.totalSettled.set(tokenIndex, currentTotalSettled - decSettled);
         }
     }
 
     /// @notice Updates pool accounting for settlement changes
     /// @dev Extracted to reduce stack depth in _updateSettlement
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param cur The previous settled amount
     /// @param next The new settled amount
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + settled change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 cur,
         uint256 next,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledDelta = next.toInt256() - cur.toInt256();
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
         _applyPoolTotalSettledDelta(paPool, tokenIndex, settledDelta);
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         int256 applied = _updateSettlement(s, id, tokenIndex, delta);
         applied;
     }
 
     /// @dev Nets a positive settlement delta against `commitmentDeficit` for one lane; isolated to reduce stack depth in `_vUpdateSettlement`.
     function _netCommitmentDeficitOnPositiveDelta(PositionAccounting storage pa, uint8 tokenIndex, int256 delta)
         private
         returns (int256 newDelta, uint256 commitmentDeficitCovered)
     {
         uint256 cd = pa.commitmentDeficit.get(tokenIndex);
         if (delta <= 0 || cd == 0) return (delta, 0);
 
         uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
         if (coverCd == 0) return (delta, 0);
 
         uint256 nextCd = cd - coverCd;
         pa.commitmentDeficit.set(tokenIndex, nextCd);
         if (nextCd == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, 0);
         }
         return (delta - int256(coverCd), coverCd);
     }
 
     /// @notice Verbose settlement update: returns total economic consumption and the `pa.settled` lane delta separately.
     /// @dev `totalApplied` matches legacy `_updateSettlement` return (deficit coverage + settled change).
     ///      `settledDeltaOnly` is `next - cur` on `pa.settled` for this lane only; amounts that cure
     ///      `cumulativeDeficit` / `commitmentDeficit` without increasing settled appear only in `totalApplied`.
     function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 totalApplied, int256 settledDeltaOnly)
     {
         if (delta == 0) return (0, 0);
 
         PositionAccounting storage pa = s.positionAccounting[id];
         (uint256 oldRemnantS0, uint256 oldRemnantS1) = (pa.settled.token0, pa.settled.token1);
         (totalApplied, settledDeltaOnly) = _vUpdateSettlementCore(s, id, tokenIndex, delta, pa);
         _syncInactiveRemnantAfterSettledPairChange(s, id, oldRemnantS0, oldRemnantS1);
     }
 
     /// @dev Core settlement mutation split from `_vUpdateSettlement` to avoid stack-too-deep in the outer wrapper.
     function _vUpdateSettlementCore(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         int256 delta,
         PositionAccounting storage pa
     ) private returns (int256 totalApplied, int256 settledDeltaOnly) {
         // Read current values in scoped block
         uint256 cur;
         uint256 c;
         uint256 cumulativeDef;
         {
             cur = pa.settled.get(tokenIndex);
             c = pa.commitmentMax.get(tokenIndex);
             cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         }
 
         uint256 next = cur;
         // Track deficit netting by source:
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
         // - totalDeficitCoverage: used for applied return semantics
         uint256 cumulativeDeficitCoverage = 0;
         uint256 totalDeficitCoverage = 0;
 
         if (delta > 0) {
             // Auto-net any lingering deficit first
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             {
                 uint256 coveredCd;
                 (delta, coveredCd) = _netCommitmentDeficitOnPositiveDelta(pa, tokenIndex, delta);
                 totalDeficitCoverage += coveredCd;
             }
 
             // If position-level commitment deficit is fully cured, clear any stored severity bps.
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 next = cur + uint256(delta);
                 if (next > c) {
                     // clamp to commitment maxima
                     next = c;
                 }
             }
         } else {
             // Negative delta: reduce settled, never create deficit here
             uint256 subtract = uint256(-delta);
             if (cur < subtract) {
                 subtract = cur;
             }
             next = cur - subtract;
         }
 
         // Write back updated settlement
         pa.settled.set(tokenIndex, next);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         settledDeltaOnly = next.toInt256() - cur.toInt256();
 
         // Update pool accounting via helper function.
         // This returns cumulativeDeficitCoverage + settledDelta.
         totalApplied = _updatePoolAccounting(s, id, tokenIndex, cur, next, cumulativeDeficitCoverage);
 
         // Preserve existing semantics: include both cumulativeDeficit and commitmentDeficit netting in applied.
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             totalApplied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when `isActive` flips but settled pair is unchanged
     ///      (liquidity mirror transition). O(1); no commit-wide scan.
     function _syncInactiveRemnantAfterActiveTransition(
         VTSStorage storage s,
         PositionId positionId,
         bool wasActive,
         uint256 settled0,
         uint256 settled1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         bool hasSettled = settled0 > 0 || settled1 > 0;
         bool oldShould = !wasActive && hasSettled;
         bool newShould = !pos.isActive && hasSettled;
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when only the settled pair changes while inactive.
     function _syncInactiveRemnantAfterSettledPairChange(
         VTSStorage storage s,
         PositionId positionId,
         uint256 oldS0,
         uint256 oldS1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool inactive = !pos.isActive;
         bool oldShould = inactive && (oldS0 > 0 || oldS1 > 0);
         bool newShould = inactive && (pa.settled.token0 > 0 || pa.settled.token1 > 0);
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @notice Updates the settlement amount by a delta which could be positive or negative
     /// @dev Shared by both local settlement flows and `VTSLifecycleLinkedLib`'s MM settlement path.
     ///      Nets against cumulative deficit, then derived commit deficit, then applies to settled.
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param delta The delta of the settlement
     /// @return applied The total amount applied (deficit coverage + settled increase)
     function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 applied)
     {
         (applied,) = _vUpdateSettlement(s, id, tokenIndex, delta);
     }
 
     // --------------------------------------------------
     // Growth Accounting Helper Functions
     // --------------------------------------------------
 
     /// @notice Compute inside growth for a position range using Uniswap-style "global/outside" accounting.
     /// @dev This mirrors Uniswap v4 core fee accounting:
     ///      - Branching formula: `Pool.getFeeGrowthInside()` in
     ///        `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
     ///      - Unchecked arithmetic is used intentionally to match Uniswap's modulo \(2^{256}\) behaviour.
     ///
     ///      Intuition:
     ///      - `global*` accumulators are "amount-per-liquidity-unit" in Q128.
     ///      - `outsideMap[poolId][tick]` stores growth on the _other_ side of that tick relative to the current tick,
     ///        maintained by flipping on each tick cross (see `VTSSwapLib._flipOutside`, derived from `Pool.crossTick`).
     ///      - "inside growth" for [tickLower, tickUpper) depends on where the current tick sits relative to the range.
     /// @param poolId The pool ID
     /// @param tickLower The lower tick
     /// @param tickUpper The upper tick
     /// @param tickCurrent The current pool tick
     /// @param global0 The global growth for token0
     /// @param global1 The global growth for token1
     /// @param outsideMap The outside growth mapping (deficitGrowthOutside or inflowGrowthOutside)
     /// @return inside0 The inside growth for token0
     /// @return inside1 The inside growth for token1
     function _growthInside(
         PoolId poolId,
         int24 tickLower,
         int24 tickUpper,
         int24 tickCurrent,
         uint256 global0,
         uint256 global1,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
     ) private view returns (uint256 inside0, uint256 inside1) {
         GrowthPair memory lower = outsideMap[poolId][tickLower];
         GrowthPair memory upper = outsideMap[poolId][tickUpper];
         inside0 = _growthInsideSingle(global0, lower.token0, upper.token0, tickCurrent, tickLower, tickUpper);
         inside1 = _growthInsideSingle(global1, lower.token1, upper.token1, tickCurrent, tickLower, tickUpper);
     }
 
     /// @notice Compute inside growth for a single token, branching on current tick (Uniswap-style)
     /// @dev Derived from Uniswap v4 core `Pool.getFeeGrowthInside()`:
     ///      `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
     ///
     ///      Why branching matters:
     ///      - Growth accrues to the active tick/liquidity at the moment it occurs (in our case, per swap segment).
     ///      - A position should only accrue growth while it is in-range (i.e. while current tick is within its bounds).
     ///      - When out-of-range, the position's "inside growth" should remain stable until price re-enters the range.
     ///
     ///      Why `unchecked`:
     ///      - Uniswap treats these accumulators as values modulo \(2^{256}\) (wraparound is acceptable and expected).
     function _growthInsideSingle(
         uint256 global,
         uint256 outsideLower,
         uint256 outsideUpper,
         int24 tickCurrent,
         int24 tickLower,
         int24 tickUpper
     ) private pure returns (uint256 inside) {
         unchecked {
             if (tickCurrent < tickLower) {
                 // Current tick below range: inside = outsideLower - outsideUpper
                 inside = outsideLower - outsideUpper;
             } else if (tickCurrent >= tickUpper) {
                 // Current tick at/above range: inside = outsideUpper - outsideLower
                 inside = outsideUpper - outsideLower;
             } else {
                 // Current tick inside range: inside = global - outsideLower - outsideUpper
                 inside = global - outsideLower - outsideUpper;
             }
         }
     }
 
     /// @notice Compute delta and checkpoint for growth settlement
     /// @dev This is the exact same pattern as Uniswap fees:
     ///      owed = (growthInsideNow - growthInsideLast) * liquidity / Q128, then checkpoint growthInsideLast = growthInsideNow.
     ///
     ///      We checkpoint *before* liquidity changes (see `CoreHook._beforeAddLiquidity/_beforeRemoveLiquidity`) to ensure:
     ///      - no retroactive capture (new liquidity cannot claim historical accrual), and
     ///      - fair attribution across partial adds/removes.
     /// @param pa The position accounting storage reference
     /// @param outsideMap The outside growth mapping
     /// @param p Growth parameters bundled in a struct (poolId, ticks, liquidity, globals, growthType)
     /// @return add0 The attributed growth delta for token0
     /// @return add1 The attributed growth delta for token1
     function _deltaAndCheckpointGrowth(
         PositionAccounting storage pa,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
         GrowthParams memory p
     ) private returns (uint256 add0, uint256 add1) {
         (uint256 inside0, uint256 inside1) = _growthInside(
             p.poolId, p.tickLower, p.tickUpper, p.tickCurrent, p.global0, p.global1, outsideMap
         );
 
         // Read last snapshots based on field identifier
         uint256 lastSnap0;
         uint256 lastSnap1;
         if (!p.isInflow) {
             lastSnap0 = pa.deficitGrowthInsideLast.token0;
             lastSnap1 = pa.deficitGrowthInsideLast.token1;
             pa.deficitGrowthInsideLast.token0 = inside0;
             pa.deficitGrowthInsideLast.token1 = inside1;
         } else {
             lastSnap0 = pa.inflowGrowthInsideLast.token0;
             lastSnap1 = pa.inflowGrowthInsideLast.token1;
             pa.inflowGrowthInsideLast.token0 = inside0;
             pa.inflowGrowthInsideLast.token1 = inside1;
         }
 
         unchecked {
             uint256 d0 = inside0 - lastSnap0;
             uint256 d1 = inside1 - lastSnap1;
             if (p.liquidity > 0) {
                 if (d0 > 0) {
                     add0 = FullMath.mulDiv(d0, uint256(p.liquidity), FixedPoint128.Q128);
                 }
                 if (d1 > 0) {
                     add1 = FullMath.mulDiv(d1, uint256(p.liquidity), FixedPoint128.Q128);
                 }
             }
         }
     }
 
     /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Calculate growth delta in scoped block
         uint256 add0;
         uint256 add1;
         {
             (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
             uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
             (add0, add1) = _deltaAndCheckpointGrowth(
                 pa,
                 s.deficitGrowthOutside,
                 GrowthParams({
                     poolId: poolId,
                     tickLower: pos.tickLower,
                     tickUpper: pos.tickUpper,
                     tickCurrent: tickCurrent,
                     liquidity: liq,
                     global0: paPool.deficitGrowthGlobal.token0,
                     global1: paPool.deficitGrowthGlobal.token1,
                     isInflow: false
                 })
             );
         }
 
         // Process token0 deficit in scoped block
         if (add0 > 0) {
             // Track full attributed outflows for fee sharing normalisation window
             pa.cumulativeOutflows.token0 += add0;
 
             // Consume settled coverage first, then accrue shortfall to deficit
             uint256 s0 = pa.settled.token0;
             if (s0 >= add0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - s0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
                 _sUpdateSettlement(s, positionId, 0, -s0.toInt256());
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             if (s1 >= add1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - s1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
                 _sUpdateSettlement(s, positionId, 1, -s1.toInt256());
             }
         }
     }
 
     /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         // Current tick is required for correct inside-growth branching (Uniswap-style).
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
             pa,
             s.inflowGrowthOutside,
             GrowthParams({
                 poolId: poolId,
                 tickLower: pos.tickLower,
                 tickUpper: pos.tickUpper,
                 tickCurrent: tickCurrent,
                 liquidity: liq,
                 global0: paPool.inflowGrowthGlobal.token0,
                 global1: paPool.inflowGrowthGlobal.token1,
                 isInflow: true
             })
         );
 
         // Token0: net against deficit first
         if (add0 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 0, add0.toInt256());
         }
 
         // Token1: net against deficit first
         if (add1 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 1, add1.toInt256());
         }
     }
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
         _settlePositionInflowGrowth(s, poolManager, positionId);
     }
 
     // --------------------------------------------------
     // Position Registration and Management
     // --------------------------------------------------
 
     /// @notice Register a new position in VTSStorage
     /// @param s The VTS storage
     /// @param owner The owner of the position
     /// @param poolId The pool id
     /// @param params The modify liquidity params
     function _registerPosition(
         VTSStorage storage s,
         address owner,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) internal {
         // Derive position id consistent with Uniswap position keying
         PositionId id = PositionLibrary.generateId(owner, params);
 
         // Check if already registered
         if (s.positions[id].owner != address(0)) {
             revert Errors.AlreadyRegistered(id);
         }
 
         // Register the position in VTSStorage
         s.positions[id] = Position({
             owner: owner,
             poolId: poolId,
             commitId: 0, // Will be set when position is associated with a commit
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
             isActive: true,
             salt: params.salt,
             checkpoint: RFSCheckpoint({
                 openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
             })
         });
     }
 
     function _rfsOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
         if (delta.amount0() > 0) {
             openMask |= 1;
         }
         if (delta.amount1() > 0) {
             openMask |= 2;
         }
     }
 
     /// @notice Link a position to a commit
     /// @param s The VTS storage
     /// @param positionId The position id
     /// @param commitId The token id (commit id)
     function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
         // validate there is an existing commit for the token id
         if (s.commits[commitId].expiresAt <= block.timestamp) {
             revert Errors.InvalidSignal(commitId);
         }
 
         // Get current position count to use as index for the new position
         uint256 currentPositionCount = s.commits[commitId].positionCount;
 
         // modify the commit to include the position and update the position count
         s.commits[commitId].positions[currentPositionCount] = positionId;
         s.commits[commitId].positionCount++;
 
         // update the commitId of the position i.e associate the position with the commit
         s.positions[positionId].commitId = commitId;
     }
 
     /// @notice Calculate RFS (Required for Settlement) for a position
     /// @param s The VTS storage
     /// @param poolManager The pool manager
     /// @param id The position id
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The RFS delta
     function calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
         public
         returns (bool rfsOpen, BalanceDelta delta)
     {
         // Settle position growths before calculating RFS
         settlePositionGrowths(s, poolManager, id);
 
         (rfsOpen, delta) = getRFS(s, id);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(id);
         }
     }
 
     /// @dev Snapshot parameters for init position
     struct SnapshotParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
     }
 
     /// @dev Initialise deficit growth snapshot
     function _initDeficitSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 d0, uint256 d1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.deficitGrowthGlobal.token0,
             paPool.deficitGrowthGlobal.token1,
             s.deficitGrowthOutside
         );
         pa.deficitGrowthInsideLast.token0 = d0;
         pa.deficitGrowthInsideLast.token1 = d1;
     }
 
     /// @dev Initialise inflow growth snapshot
     function _initInflowSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 i0, uint256 i1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.inflowGrowthGlobal.token0,
             paPool.inflowGrowthGlobal.token1,
             s.inflowGrowthOutside
         );
         pa.inflowGrowthInsideLast.token0 = i0;
         pa.inflowGrowthInsideLast.token1 = i1;
     }
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
     }
 
     /// @dev Seed per-tick outside growth snapshots when a tick is initialised by this liquidity add.
     ///      This moves first-write cost from swap-time tick crossing to modify-liquidity time.
     ///      Mirrors Uniswap initialisation semantics: if tick <= currentTick, outside starts at global, else 0.
     function _seedOutsideGrowthForNewlyInitializedTicks(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) private {
         if (params.liquidityDelta <= 0) return;
 
         uint128 addLiq = uint256(params.liquidityDelta).toUint128();
         (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickLower);
         (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickUpper);
 
         bool lowerInitializedByThisAdd = lowerGross == addLiq;
         bool upperInitializedByThisAdd = upperGross == addLiq;
         if (!lowerInitializedByThisAdd && !upperInitializedByThisAdd) return;
 
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         if (lowerInitializedByThisAdd) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickLower, tickCurrent);
         }
         if (upperInitializedByThisAdd && params.tickUpper != params.tickLower) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickUpper, tickCurrent);
         }
     }
 
     function _seedOutsideAtInitializedTick(
         VTSStorage storage s,
         PoolAccounting storage paPool,
         PoolId poolId,
         int24 tick,
         int24 tickCurrent
     ) private {
         if (tick > tickCurrent) return;
 
         s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
         s.deficitGrowthOutside[poolId][tick].token1 = paPool.deficitGrowthGlobal.token1;
         s.inflowGrowthOutside[poolId][tick].token0 = paPool.inflowGrowthGlobal.token0;
         s.inflowGrowthOutside[poolId][tick].token1 = paPool.inflowGrowthGlobal.token1;
     }
 
     /// @notice Checkpoint the tick-indexed growth snapshots at the current pool state.
     /// @dev Used for both first-time registration and inactive-position reactivation so zero-liquidity intervals
     ///      cannot be retroactively attributed to freshly added liquidity.
     function _checkpointTickIndexedSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         PositionAccounting storage pa = s.positionAccounting[id];
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
 
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initDeficitSnapshot(s, pa, sp);
         _initInflowSnapshot(s, pa, sp);
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @dev Effective `isSeizing` is only true for MM operations (`commitId > 0`) with `seizure.isSeizing`.
     ///      Non-MM callers cannot grant seizure semantics by forging hook bytes.
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = data.isMMOperation && mmData.seizure.isSeizing;
     }
 
     /// @notice Handles new position initialization and returns required settlement delta
     function _touchNewPosition(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         address owner,
         ModifyLiquidityParams calldata params,
         PositionId positionId,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         if (hookData.isMMOperation && hookData.isSeizing) {
             revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
         }
 
         _registerPosition(s, owner, poolId, params);
 
         if (hookData.isMMOperation && hookData.commitId > 0) {
             _linkPositionToCommit(s, positionId, hookData.commitId);
         }
 
         _initPositionSnapshots(s, poolManager, positionId);
         if (uint256(params.liquidityDelta).toUint128() != liveLiquidityAfterModify) {
             revert Errors.InvariantViolated("live liquidity mismatch on new position touch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         TokenPairUint memory commitmentMaxima = s.positionAccounting[positionId].commitmentMax;
 
         if (hookData.isMMOperation) {
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position decrease: RFS gate, commitment tracking, settled clamp / MM excess delta.
     /// @param currentLiq Live PoolManager liquidity after the remove (same as unpaused `touchPosition` decrease path).
     /// @dev RFS uses `getRFS` only; growth is already settled in CoreHook `_beforeRemoveLiquidity` — avoid `calcRFS` here
     ///      so we do not re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
     function _touchExistingDecrease(
         VTSStorage storage s,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 currentLiq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posDec = s.positions[positionId];
         if (params.tickLower != posDec.tickLower || params.tickUpper != posDec.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         // Growth is already settled in CoreHook `_beforeRemoveLiquidity`; avoid `calcRFS` here so we do not
         // re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
         // RFS-open removes revert unless this is an authorised MM seizure decrease (`isMMOperation && isSeizing`);
         // non-MM forged `seizure.isSeizing` is cleared in `_decodeHookData`.
         if (!(hookData.isMMOperation && hookData.isSeizing)) {
             (bool rfsOpen,) = getRFS(s, positionId);
             if (rfsOpen) {
                 revert Errors.RFSOpenForPosition(positionId);
             }
         }
         _trackCommitment(s, positionId, currentLiq);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);
 
         if (hookData.isMMOperation) {
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
         } else {
             _applySettlementClampFromExcess(s, positionId, excess0, excess1);
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position increase and returns required settlement delta
     function _touchExistingIncrease(
         VTSStorage storage s,
         PoolId poolId,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posInc = s.positions[positionId];
         if (params.tickLower != posInc.tickLower || params.tickUpper != posInc.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
 
         if (hookData.isMMOperation) {
             if (hookData.isSeizing) {
                 revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
             }
 
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
             uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @dev Extracted to keep `touchPosition` stack-safe when branching on fee-cap policy.
     function _afterTouchPositionFees(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta feesAccrued,
         bool capPositiveSlashToFeesAccrued
     ) private returns (BalanceDelta feeAdj) {
         if (!capPositiveSlashToFeesAccrued) {
             return VTSFeeLinkedLib.afterTouchPosition(s, positionId);
         }
         int128 fa0 = feesAccrued.amount0();
         int128 fa1 = feesAccrued.amount1();
         uint256 positiveCap0 = fa0 > 0 ? uint256(uint128(fa0)) : 0;
         uint256 positiveCap1 = fa1 > 0 ? uint256(uint128(fa1)) : 0;
         return VTSFeeLinkedLib.afterTouchPositionWithPositiveCaps(s, positionId, positiveCap0, positiveCap1);
     }
 
     //#olympix-ignore-reentrancy
     function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
         external
         returns (TouchPositionResult memory result)
     {
         PoolId poolId = p.poolKey.toId();
         bool isPaused = s.isPaused || s.pools[poolId].isPaused;
         if (isPaused && p.params.liquidityDelta >= 0) {
             revert Errors.EnforcedPause();
         }
         _seedOutsideGrowthForNewlyInitializedTicks(s, ctx.poolManager, poolId, p.params);
 
         result.id = PositionLibrary.generateId(p.owner, p.params);
         Position storage posStorage = s.positions[result.id];
         bool isNewPosition = posStorage.owner == address(0);
         uint256 initialLiquidity = posStorage.liquidity;
         uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));
 
         TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
         BalanceDelta requiredSettlementDelta;
 
         if (isNewPosition) {
             if (p.params.liquidityDelta <= 0) {
                 revert Errors.InvalidPosition(0, 0, result.id);
             }
             // NEW POSITION
             requiredSettlementDelta =
                 _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, liq, hookData);
         } else {
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, result.id, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta =
                         _touchExistingIncrease(s, poolId, result.id, p.params, nextLiquidity, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                     _trackCommitment(s, result.id, liq);
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s, result.id, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
                 );
             }
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         // On any liquidity decrease, cap same-touch positive `pendingFeeAdj` materialisation to the
         // per-leg informational `feesAccrued` slice; excess remains banked in `pendingFeeAdj` (SETTLE-03).
         result.feeAdj = _afterTouchPositionFees(s, result.id, p.feesAccrued, p.params.liquidityDelta < 0);
 
         if (hookData.isMMOperation) {
             VTSPositionMMOpsLib.processMMOperations(s, ctx, p, result, requiredSettlementDelta);
         }
 
         // Refresh from storage after the MM tail. `processMMOperations` is an external linked-library call; mutating
         // `TouchPositionResult` inside it does not update this caller's memory return value.
         result.pos = s.positions[result.id];
     }
 
     /// @notice Update active status based on liquidity transitions
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _updateActiveStatus(
         VTSStorage storage s,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) internal {
         // Update active status based on liquidity
         // Track transitions to update activePositionCount for commits
         uint256 commitId = posStorage.commitId;
 
         if (liq == 0) {
             posStorage.isActive = false;
             // Decrement activePositionCount if transitioning from active(liq > 0) to inactive(liq == 0)
             if (initialLiquidity > 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount--;
             }
         } else {
             posStorage.isActive = true;
             // Increment activePositionCount if transitioning from inactive(liq == 0) to active(liq > 0)
             if (initialLiquidity == 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount++;
             }
         }
     }
 
     /// @dev Runs `_updateActiveStatus` then `Commit.inactiveRemnantCount` sync in a separate stack frame.
     function _updateStatus(
         VTSStorage storage s,
         PositionId positionId,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) private {
         bool wasActive = posStorage.isActive;
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         _syncInactiveRemnantAfterActiveTransition(s, positionId, wasActive, s0, s1);
     }
 
     function _deriveIncreaseTransitionLiquidity(uint128 liq, int256 liquidityDelta)
         internal
         pure
         returns (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity)
     {
         if (liquidityDelta <= 0) {
             return (liq, liq);
         }
 
         uint128 addedLiquidity = uint256(liquidityDelta).toUint128();
         liveLiquidityBeforeAdd = liq > addedLiquidity ? liq - addedLiquidity : 0;
         nextLiquidity = liq;
 
         // Unit harnesses may call touchPosition without pre-mutating PoolManager liquidity first.
         if (nextLiquidity == 0) nextLiquidity = liveLiquidityBeforeAdd + addedLiquidity;
     }
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
+            // FIX: Replace the plain floor conversion with base+carry logic:
+            // rem = mulmod(fgDelta0, liquidityBeforeAdd, Q128);
+            // tot = residualFeeBackingRemainderX128.token0 + rem;
+            // extra = tot / Q128; residualFeeBackingRemainderX128.token0 = tot % Q128;
+            // pendingResidualFeeBacking.token0 += base + extra;
+            // where base = FullMath.mulDiv(fgDelta0, liquidityBeforeAdd, Q128).
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
+        // FIX: Keep advancing feeGrowthInsideLast as today (prevents new liquidity inheriting old windows),
+        // but only after applying the base+carry banking above. The new remainder accumulator is episode-scoped
+        // and must NOT be cleared here (only when the residual episode resolves).
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     ///      For **non-seizure** MM decreases, callers pass the routed export from `VTSPositionMMOpsLib`:
     ///      `settleableDelta + queuedDelta` (vault-immediate plus shortfall-backed queue). For **seizure** MM decreases,
     ///      callers pass the seizure split export per leg: `min(excessSettled, settleableVaultLeg + burn)` where
     ///      `burn = min(principal, excessSettled)` — not `settleable + full queued principal`, so guarantor-queued
     ///      principal does not over-remove live `pa.settled` (SETTLE-03). Any remainder that could not be routed stays
     ///      in `pa.settled` until serviceable; only the vault-immediate slice is mirrored on `OwnerCurrencyDelta`.
     function _applySettlementClampFromExcess(
         VTSStorage storage s,
         PositionId positionId,
         uint256 excess0,
         uint256 excess1
     ) internal {
         if (excess0 > 0) {
             _sUpdateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
         }
         if (excess1 > 0) {
             _sUpdateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
         }
     }
 
     /// @dev Apply the shared liquidity mirror transition logic used by touch/reconcile.
     function _applyLiquidityMirrorTransition(
         VTSStorage storage s,
         PositionId positionId,
         PositionAccounting storage pa,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 nextLiquidity
     ) internal {
         posStorage.liquidity = nextLiquidity;
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
         // Full deactivation: reset the entire commitment-deficit snapshot (amounts, age, severity).
         // Issued commitment is zero once liquidity is fully unwound, so there is nothing left to be insolvent for.
         // Clearing token amounts avoids stale `commitmentDeficit` with `commitmentDeficitSince == 0` after a prior
         // partial reset, which would otherwise block age-gated deficit bypass in `CheckpointLibrary.isSeizable`.
         // Non-seizure MM liquidity changes remain blocked while deficit is non-zero (`CommitmentDeficitBlocksLiquidityChange`);
         // this reset is the semantic cleanup once deactivation is actually reached (including non-MM and seizure paths).
         if (initialLiquidity > 0 && nextLiquidity == 0) {
             pa.commitmentDeficit.set(0, 0);
             pa.commitmentDeficit.set(1, 0);
             pa.commitmentDeficitSince.token0 = 0;
             pa.commitmentDeficitSince.token1 = 0;
             pa.commitmentDeficitBps = 0;
         }
         _updateStatus(s, positionId, posStorage, initialLiquidity, nextLiquidity);
     }
 
     // --------------------------------------------------
     // RFS (Required for Settlement) Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice View helper for computing RFS state and delta for a position
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The settlement delta required/available
     function getRFS(VTSStorage storage s, PositionId positionId)
         public
         view
         returns (bool rfsOpen, BalanceDelta delta)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Get commitments and settled amounts in scoped block
         uint256 c0;
         uint256 c1;
         uint256 s0;
         uint256 s1;
         uint256 req0;
         uint256 req1;
         {
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
             s0 = pa.settled.token0;
             s1 = pa.settled.token1;
         }
 
         // Calculate base requirements
         {
             Position memory pos = s.positions[positionId];
             Pool memory pool = s.pools[pos.poolId];
             MarketVTSConfiguration memory cfg = pool.vtsConfig;
 
             uint256 d0 = pa.cumulativeDeficit.token0;
             uint256 d1 = pa.cumulativeDeficit.token1;
 
             (uint256 base0, uint256 base1) =
                 LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);
 
             // Cap deficits by commitment and gate by base
             uint256 defReq0 = d0 < c0 ? d0 : c0;
             uint256 defReq1 = d1 < c1 ? d1 : c1;
             req0 = base0 > defReq0 ? base0 : defReq0;
             req1 = base1 > defReq1 ? base1 : defReq1;
         }
 
         // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
         {
             uint256 cd0 = pa.commitmentDeficit.token0;
             uint256 cd1 = pa.commitmentDeficit.token1;
             if (cd0 > 0) {
                 uint256 add0 = req0 + cd0;
                 req0 = add0 > c0 ? c0 : add0;
             }
             if (cd1 > 0) {
                 uint256 add1 = req1 + cd1;
                 req1 = add1 > c1 ? c1 : add1;
             }
         }
 
         int128 amount0 = _rfsDeltaRaw(s0, req0);
         int128 amount1 = _rfsDeltaRaw(s1, req1);
 
         // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
         rfsOpen = (amount0 > 0) || (amount1 > 0);
         delta = toBalanceDelta(amount0, amount1);
     }
 
     /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
     /// @param settled Current settled amount
     /// @param need Required amount
     /// @return deltaRaw Signed delta in raw units
     function _rfsDeltaRaw(uint256 settled, uint256 need) internal pure returns (int128 deltaRaw) {
         if (need >= settled) {
             uint256 pos = need - settled; // rfs is the needed minus the already settled
             if (pos > INT128_MAX_U) return type(int128).max;
             return pos.toInt128();
         }
         uint256 neg = settled - need; // withdrawable
         if (neg > INT128_MAX_U) return type(int128).min;
         int128 magnitude = neg.toInt128();
         return -magnitude;
     }
 
     // --------------------------------------------------
     // Settlement Functions (from VTSSettleLib)
     // --------------------------------------------------
     // MM settlement (`executeMMSettleFromParams` / `onMMSettle`) lives in `VTSLifecycleLinkedLib`.
 }
```

## VTSFeeLib.sol

File: `contracts/evm/src/libraries/VTSFeeLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib
 } from "../types/VTS.sol";
 import {PositionId, Position} from "../types/Position.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 
 /// @title VTSFeeLib
 /// @notice Fee processing, slashed pot management, and coverage burn logic for VTS
 /// @author Fiet Protocol
 library VTSFeeLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
 
     /// @dev Internal struct to keep fee-burn helper signatures below stack-too-deep thresholds.
     struct FeesBurnParams {
         PoolId poolId;
         uint8 deficitTokenIndex;
         uint8 feeTokenIndex;
         uint256 burnBase;
         uint128 positionLiquidity;
         uint256 outflowFloor;
         bool consumeResidualFeeBacking;
     }
 
     struct FeesBurnResolution {
         uint256 totalFees;
         uint256 bankedFees;
         uint256 ofDelta;
         uint256 snap;
     }
 
     struct FeesBurnComputation {
         uint256 freshFees;
         uint256 bankedFees;
         uint256 snap;
         uint256 ofDelta;
         uint256 totalFees;
         uint256 bps;
         uint256 consumedBurnBase;
         uint256 consumedTotalFees;
         uint256 feesBurn;
         uint256 consumedBankedFees;
         uint256 consumedFreshFees;
     }
 
     // --------------------------------------------------
     // Fee Adjustment Helpers
     // --------------------------------------------------
 
     /// @dev Queue a bonus for a single token using CISE (Coverage-Indexed Settled Exposure).
     /// @notice CISE replaces selfNet as the primary eligibility gate, fixing the commitmentMax clamp bug.
     ///         Positions accrue exposure when incrementCoverage is called, proportional to their settled liquidity.
     ///         CSI remaining-share factors are used for self-exclusion to ensure positions can receive bonuses
     ///         even after their contributed slashes have been distributed to others.
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param feeTokenIndex The fee token index (0 or 1) - the pot from which bonus is allocated
     /// @param coverageTokenIndex The coverage token index (opposite of feeTokenIndex) - the token whose exposure is used
     /// @param ciseExposure The position's realised CISE exposure since last allocation (from coverageTokenIndex)
     /// @return allocated True iff a non-zero bonus was queued (i.e. pendingFeeAdj was decreased).
     function _queueBonusForToken(
         PositionAccounting storage pa,
         PoolAccounting storage paPool,
         uint8 feeTokenIndex,
         uint8 coverageTokenIndex,
         uint256 ciseExposure
     ) internal returns (bool allocated) {
         // CISE: Use exposure as eligibility gate instead of selfNet
         if (ciseExposure == 0) return false;
 
         // CSI: Sync remaining contribution shares before reading selfRemaining
         _syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);
 
         // Bonuses are allocated only against the materialised slashed pot (positive `pendingFeeAdj` must be
         // materialised in `_processPositionFees` before this runs).
         uint256 pot = paPool.slashedPot.get(feeTokenIndex);
 
         // CSI: feesShared is stored as remaining self-contribution (not lifetime)
         uint256 selfRemaining = pa.feesShared.get(feeTokenIndex);
         uint256 potAvail = pot > selfRemaining ? (pot - selfRemaining) : 0;
 
         if (potAvail == 0) return false;
 
         // CISE: Denominator is the pool-wide allocatable coverage window, updated eagerly on `incrementCoverage`
         // and decremented on allocation; not lazily summed from per-touch position realisations. Coverage exercised
         // while `totalSettled == 0` is excluded upstream because no settled liquidity was live to earn that weight.
         uint256 totalExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
         if (totalExposure == 0) return false;
 
         // bonus = potAvail * ciseExposure / totalExposure (round up so dust does not strand eligible exposure)
         uint256 bonus = FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure);
         if (bonus > potAvail) bonus = potAvail;
         if (bonus == 0) return false;
 
         // CSI: Update the cumulative remaining-share factor for this epoch.
         // Note: Under consistent accounting, total remaining shares == current pot (pre-spend).
         if (pot > 0) _advanceFeesSharedFactor(paPool, feeTokenIndex, pot, bonus);
 
         // Queue negative pending (bonus increases payout at materialisation); `slashedPot` is drained when
         // negative `pendingFeeAdj` is materialised in `_finaliseNegativeFeeAdjustment`.
         int256 currentPending = pa.pendingFeeAdj.get(feeTokenIndex);
         pa.pendingFeeAdj.set(feeTokenIndex, currentPending - bonus.toInt256());
         return true;
     }
 
     /// @dev After bonus allocation, clear/decrement per-position and per-pool CISE windows so future allocations don't double-count.
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param coverageTokenIndex The coverage token index - the token whose exposure was used for allocation
     /// @param ciseExposure The position's CISE exposure for the coverage token
     function _cleanupAfterAllocationForToken(
         PositionAccounting storage pa,
         PoolAccounting storage paPool,
         uint8 coverageTokenIndex,
         uint256 ciseExposure
     ) internal {
         if (ciseExposure == 0) return;
 
         // CISE: Clear position exposure window and decrement pool total
         uint256 curExposure = paPool.totalCISEExposureSinceLastMod.get(coverageTokenIndex);
         paPool.totalCISEExposureSinceLastMod
             .set(coverageTokenIndex, ciseExposure > curExposure ? 0 : (curExposure - ciseExposure));
         pa.ciseExposureSinceLastMod.set(coverageTokenIndex, 0);
     }
 
     // --------------------------------------------------
     // CSI Remaining-Factor Helpers
     // --------------------------------------------------
 
     /// @dev Sync a position's remaining feesShared (self-contribution still embedded in the pot)
     ///      against the pool remaining-share factor for the current spend epoch.
     /// @notice Must be called BEFORE incrementing feesShared (slash) or reading selfRemaining (bonus)
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     function _syncFeesSharedRemainingForToken(
         PositionAccounting storage pa,
         PoolAccounting storage paPool,
         uint8 tokenIndex
     ) internal {
         uint256 epochNow = _currentFeesSharedEpoch(paPool, tokenIndex);
         if (epochNow == 0) return;
 
         uint256 epochLast = pa.feesSharedEpoch.get(tokenIndex);
         uint256 factorNow = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
 
         if (epochLast != epochNow) {
             if (pa.feesShared.get(tokenIndex) != 0) {
                 pa.feesShared.set(tokenIndex, 0);
             }
             pa.feesSharedEpoch.set(tokenIndex, epochNow);
             pa.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
             return;
         }
 
         uint256 factorLast = pa.feesSharedRemainingFactorLastX128.get(tokenIndex);
         if (factorNow == factorLast) return;
 
         uint256 sharesRemaining = pa.feesShared.get(tokenIndex);
         if (sharesRemaining > 0) {
             uint256 updatedShares;
             if (factorLast == 0) {
                 // No spend had been realised against this position in the current epoch yet. A zero pool factor is still
                 // the identity state until the first bonus allocation stores a non-zero remaining-share factor.
                 // Keep remaining shares conservative for tiny balances so self-exclusion does not collapse early.
                 updatedShares = factorNow == 0
                     ? sharesRemaining
                     : FullMath.mulDivRoundingUp(sharesRemaining, factorNow, FixedPoint128.Q128);
             } else {
                 // Round up so partial spend does not floor tiny remaining self-contribution to zero.
                 updatedShares = factorNow == 0 ? 0 : FullMath.mulDivRoundingUp(sharesRemaining, factorNow, factorLast);
             }
 
             if (updatedShares != sharesRemaining) {
                 pa.feesShared.set(tokenIndex, updatedShares);
             }
         }
 
         pa.feesSharedEpoch.set(tokenIndex, epochNow);
         pa.feesSharedRemainingFactorLastX128.set(tokenIndex, factorNow);
     }
 
     function _currentFeesSharedEpoch(PoolAccounting storage paPool, uint8 tokenIndex)
         private
         view
         returns (uint256 epoch)
     {
         epoch = paPool.feesSharedEpoch.get(tokenIndex);
     }
 
     function _beginFeesSharedEpochIfNeeded(PoolAccounting storage paPool, uint8 tokenIndex) internal {
         uint256 epoch = paPool.feesSharedEpoch.get(tokenIndex);
         if (epoch == 0) {
             paPool.feesSharedEpoch.set(tokenIndex, 1);
             return;
         }
 
         uint256 factor = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
         uint256 materialPot = paPool.slashedPot.get(tokenIndex);
         if (factor == 0 && materialPot == 0) {
             paPool.feesSharedEpoch.set(tokenIndex, epoch + 1);
         }
     }
 
     function _advanceFeesSharedFactor(PoolAccounting storage paPool, uint8 tokenIndex, uint256 pot, uint256 bonus)
         private
     {
         if (paPool.feesSharedEpoch.get(tokenIndex) == 0) {
             paPool.feesSharedEpoch.set(tokenIndex, 1);
         }
 
         uint256 currentFactor = paPool.feesSharedRemainingFactorX128.get(tokenIndex);
         uint256 factorBase = currentFactor == 0 ? FixedPoint128.Q128 : currentFactor;
         uint256 nextFactor = FullMath.mulDivRoundingUp(factorBase, pot - bonus, pot);
         paPool.feesSharedRemainingFactorX128.set(tokenIndex, nextFactor);
     }
 
     function _prepareFeeShareMint(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 feeTokenIndex)
         internal
     {
         _beginFeesSharedEpochIfNeeded(paPool, feeTokenIndex);
         _syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);
     }
 
     /// @notice Calculate fees and checkpoint snapshots for coverage burn
     /// @dev Extracted to keep position-side DICE orchestration small.
     function _calculateFeesBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         FeesBurnParams memory params
     ) internal returns (uint256, uint256, uint256, uint256) {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         FeesBurnComputation memory c;
 
         {
             Position memory pos = s.positions[positionId];
             (uint256 fg0, uint256 fg1) =
                 StateLibrary.getFeeGrowthInside(poolManager, params.poolId, pos.tickLower, pos.tickUpper);
             uint256 fg = params.feeTokenIndex == 0 ? fg0 : fg1;
 
             uint256 lastFeeGrowth = pa.feeGrowthInsideLast.get(params.feeTokenIndex);
             if (params.positionLiquidity > 0 && fg > lastFeeGrowth) {
                 c.freshFees = FullMath.mulDiv(fg - lastFeeGrowth, uint256(params.positionLiquidity), FixedPoint128.Q128);
             }
             if (params.consumeResidualFeeBacking) {
                 c.bankedFees = pa.pendingResidualFeeBacking.get(params.feeTokenIndex);
             }
         }
 
         uint256 cumulativeOutflows = pa.cumulativeOutflows.get(params.deficitTokenIndex);
         c.snap = pa.outflowsAtFeeSnap.get(params.deficitTokenIndex);
         if (params.outflowFloor > c.snap) {
             c.snap = params.outflowFloor;
         }
         c.ofDelta = cumulativeOutflows >= c.snap ? (cumulativeOutflows - c.snap) : 0;
 
         c.totalFees = c.freshFees + c.bankedFees;
         if (c.totalFees == 0 || c.ofDelta == 0) {
             return (0, 0, 0, 0);
         }
 
         c.bps = s.pools[params.poolId].vtsConfig.coverageFeeShare;
         if (c.bps == 0) {
             return (0, 0, 0, 0);
         }
         if (c.bps > LiquidityUtils.BPS_DENOMINATOR) {
             c.bps = LiquidityUtils.BPS_DENOMINATOR;
         }
 
         c.consumedBurnBase = params.burnBase <= c.ofDelta ? params.burnBase : c.ofDelta;
         c.consumedTotalFees = FullMath.mulDiv(c.totalFees, c.consumedBurnBase, c.ofDelta);
         c.feesBurn = FullMath.mulDiv(c.consumedTotalFees, c.bps, LiquidityUtils.BPS_DENOMINATOR);
         if (c.feesBurn == 0) {
             return (0, 0, 0, 0);
         }
 
         c.consumedBankedFees = c.consumedTotalFees <= c.bankedFees ? c.consumedTotalFees : c.bankedFees;
         c.consumedFreshFees = c.consumedTotalFees - c.consumedBankedFees;
         pa.outflowsAtFeeSnap.set(params.deficitTokenIndex, c.snap + c.consumedBurnBase);
 
         return (c.feesBurn, c.consumedBurnBase, c.consumedFreshFees, c.consumedBankedFees);
     }
 
     /// @notice Apply a precomputed burn base for a position and return the consumed outflow share
     function _applyBurnBase(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint256 burnBase,
         uint128 positionLiquidity,
         uint256 outflowFloor,
         bool consumeResidualFeeBacking
     ) internal returns (uint256 consumedBurnBase) {
         if (burnBase == 0) return 0;
 
         uint8 feeTokenIndex = tokenIndex == 0 ? 1 : 0;
         uint256 feesBurn;
         uint256 consumedFreshFees;
         uint256 consumedBankedFees;
         FeesBurnParams memory params = FeesBurnParams({
             poolId: poolId,
             deficitTokenIndex: tokenIndex,
             feeTokenIndex: feeTokenIndex,
             burnBase: burnBase,
             positionLiquidity: positionLiquidity,
             outflowFloor: outflowFloor,
             consumeResidualFeeBacking: consumeResidualFeeBacking
         });
         (feesBurn, consumedBurnBase, consumedFreshFees, consumedBankedFees) =
             _calculateFeesBurn(s, poolManager, positionId, params);
 
         if (feesBurn == 0) return 0;
 
         _finaliseBurnAccounting(
             s, positionId, poolId, feeTokenIndex, positionLiquidity, consumedFreshFees, consumedBankedFees, feesBurn
         );
     }
 
     function _finaliseBurnAccounting(
         VTSStorage storage s,
         PositionId positionId,
         PoolId poolId,
         uint8 feeTokenIndex,
         uint128 positionLiquidity,
         uint256 consumedFreshFees,
         uint256 consumedBankedFees,
         uint256 feesBurn
     ) private {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (consumedBankedFees > 0) {
             uint256 currentBacking = pa.pendingResidualFeeBacking.get(feeTokenIndex);
             pa.pendingResidualFeeBacking
                 .set(feeTokenIndex, consumedBankedFees > currentBacking ? 0 : (currentBacking - consumedBankedFees));
         }
 
         if (positionLiquidity > 0 && consumedFreshFees > 0) {
             uint256 liquidity = uint256(positionLiquidity);
             uint256 carryIn = pa.feeBurnGrowthRemainder.get(feeTokenIndex);
             (uint256 growthInc, uint256 newCarry) =
                 LiquidityUtils.feeBurnGrowthIncWithRemainder(consumedFreshFees, liquidity, carryIn);
             pa.feeBurnGrowthRemainder.set(feeTokenIndex, newCarry);
             pa.feeGrowthInsideLast.set(feeTokenIndex, pa.feeGrowthInsideLast.get(feeTokenIndex) + growthInc);
         }
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         _prepareFeeShareMint(pa, paPool, feeTokenIndex);
         pa.feesShared.set(feeTokenIndex, pa.feesShared.get(feeTokenIndex) + feesBurn);
         pa.pendingFeeAdj.set(feeTokenIndex, pa.pendingFeeAdj.get(feeTokenIndex) + feesBurn.toInt256());
     }
 
     // --------------------------------------------------
     // CISE (Coverage-Indexed Settled Exposure) Helpers
     // --------------------------------------------------
 
     /// @notice Peek the current pending fee adjustments for a position without mutating state
     /// @param s The central VTS storage
     /// @param positionId The position ID
     /// @return adj0 The pending fee adjustment for token0 (+slash, -bonus)
     /// @return adj1 The pending fee adjustment for token1 (+slash, -bonus)
     function _peekFeeAdjustment(VTSStorage storage s, PositionId positionId)
         internal
         view
         returns (int256 adj0, int256 adj1)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         adj0 = pa.pendingFeeAdj.token0;
         adj1 = pa.pendingFeeAdj.token1;
     }
 
     /// @notice Increase the slashed pot accounting for a pool/token
     /// @dev Only updates accounting state. Actual ERC6909 mint is handled by CoreHook.settleHookDeltasToPot
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param amount The amount to fund
     function _fundFeePot(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
         if (amount == 0) return;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 currentPot = paPool.slashedPot.get(tokenIndex);
         paPool.slashedPot.set(tokenIndex, currentPot + amount);
     }
 
     /// @notice Decrease the slashed pot accounting when settling bonuses
     /// @dev Only updates accounting state. Actual ERC6909 burn is handled by CoreHook.settleHookDeltasToPot
     /// @param s The central VTS storage
     /// @param poolId The pool ID
     /// @param tokenIndex The token index (0 or 1)
     /// @param amount The amount to drain
     function _drainFeePot(VTSStorage storage s, PoolId poolId, uint8 tokenIndex, uint256 amount) internal {
         if (amount == 0) return;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 pot = paPool.slashedPot.get(tokenIndex);
         // Clamp to available pot to avoid underflow; caller must have already bounded the amount
         if (amount > pot) amount = pot;
         paPool.slashedPot.set(tokenIndex, pot - amount);
     }
 
     /// @notice Materialise positive `pendingFeeAdj` into `slashedPot` up to per-leg caps (SETTLE-03 on decreases).
     function _finalisePositiveFeeAdjustment(
         VTSStorage storage s,
         PositionId positionId,
         PoolId poolId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) internal returns (BalanceDelta adj) {
         (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
         int256 mat0 = 0;
         int256 mat1 = 0;
 
         if (pend0 > 0) {
             uint256 pendPos0 = uint256(pend0);
             uint256 pay0 = pendPos0 < positiveCap0 ? pendPos0 : positiveCap0;
             if (pay0 > 0) {
                 _fundFeePot(s, poolId, 0, pay0);
                 mat0 = pay0.toInt256();
             }
         }
 
         if (pend1 > 0) {
             uint256 pendPos1 = uint256(pend1);
             uint256 pay1 = pendPos1 < positiveCap1 ? pendPos1 : positiveCap1;
             if (pay1 > 0) {
                 _fundFeePot(s, poolId, 1, pay1);
                 mat1 = pay1.toInt256();
             }
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         pa.pendingFeeAdj.token0 = pend0 - mat0;
         pa.pendingFeeAdj.token1 = pend1 - mat1;
 
         adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
     }
 
     /// @notice Materialise negative `pendingFeeAdj` by draining `slashedPot` (bonuses queued after positive phase).
     function _finaliseNegativeFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
         internal
         returns (BalanceDelta adj)
     {
         (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
         int256 mat0 = 0;
         int256 mat1 = 0;
 
         if (pend0 < 0) {
             uint256 need0 = uint256(-pend0);
             PoolAccounting storage paPool = s.poolAccounting[poolId];
             uint256 pot0 = paPool.slashedPot.token0;
             uint256 pay0 = pot0 < need0 ? pot0 : need0;
             if (pay0 > 0) {
                 _drainFeePot(s, poolId, 0, pay0);
                 mat0 = -pay0.toInt256();
             }
         }
 
         if (pend1 < 0) {
             uint256 need1 = uint256(-pend1);
             PoolAccounting storage paPool = s.poolAccounting[poolId];
             uint256 pot1 = paPool.slashedPot.token1;
             uint256 pay1 = pot1 < need1 ? pot1 : need1;
             if (pay1 > 0) {
                 _drainFeePot(s, poolId, 1, pay1);
                 mat1 = -pay1.toInt256();
             }
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         pa.pendingFeeAdj.token0 = pend0 - mat0;
         pa.pendingFeeAdj.token1 = pend1 - mat1;
 
         adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
     }
 
     /// @notice Finalise pending fee adjustments with optional per-leg caps on positive slash materialisation
     /// @dev Positive pending adjustment (`pend > 0`) is materialised at most up to `positiveCap*` for each leg.
     ///      Any unmaterialised remainder stays queued in `pendingFeeAdj` for future touches.
     ///      Negative pending (`pend < 0`) bonus materialisation drains `slashedPot`.
     /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot.
     ///      Positive pending (`pend > 0`) materialises at most `positiveCap*` per leg; pass `type(uint256).max` on both
     ///      legs for uncapped behaviour. Any unmaterialised positive remainder stays in `pendingFeeAdj`.
     /// @dev Not used on the production fee-sharing path: `_processPositionFees` runs Phase 2 (bonus allocation)
     ///      between `_finalisePositiveFeeAdjustment` and `_finaliseNegativeFeeAdjustment`. Exposed for
     ///      `VTSFeeLibHarness` / unit tests that exercise positive+negative materialisation without Phase 2.
     /// @param s The central VTS storage
     /// @param positionId The position ID
     /// @param poolId The pool ID
     /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
     //#olympix-ignore-reentrancy
     function _finaliseFeeAdjustment(
         VTSStorage storage s,
         PositionId positionId,
         PoolId poolId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) internal returns (BalanceDelta adj) {
         BalanceDelta adjPos = _finalisePositiveFeeAdjustment(s, positionId, poolId, positiveCap0, positiveCap1);
         BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(s, positionId, poolId);
         return adjPos + adjNeg;
     }
 
     /// @notice Uncapped finalisation (`positiveCap* = max`).
     function _finaliseFeeAdjustment(VTSStorage storage s, PositionId positionId, PoolId poolId)
         internal
         returns (BalanceDelta adj)
     {
         return _finaliseFeeAdjustment(s, positionId, poolId, type(uint256).max, type(uint256).max);
     }
 
     /// @notice Consolidated fee processing for a position during modification (three phases)
     /// @dev Phase 1: materialise positive `pendingFeeAdj` into `slashedPot` (capped per leg on decreases).
     ///      Phase 2: allocate bonuses from the materialised pot via CISE/CSI (queues negative pending).
     ///      Phase 3: materialise negative pending by draining `slashedPot`.
     ///      Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot.
     ///      Pass `type(uint256).max` for both caps for uncapped positive slash materialisation.
     /// @param s The central VTS storage
     /// @param positionId The position ID
     /// @return adj The materialised fee adjustment delta
     function _processPositionFees(
         VTSStorage storage s,
         PositionId positionId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) internal returns (BalanceDelta adj) {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
 
         // If fee sharing is disabled, skip processing (fees handled natively by Uniswap)
         if (!_isFeeSharingEnabled(s, poolId)) {
             return toBalanceDelta(0, 0);
         }
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         // Phase 1 — fund `slashedPot` from positive pending before bonus allocation.
         BalanceDelta adjPos = _finalisePositiveFeeAdjustment(s, positionId, poolId, positiveCap0, positiveCap1);
 
         // Read CISE exposure for bonus allocation
         // Note: Raw exposure values per coverage token
         uint256 ciseExposure0 = pa.ciseExposureSinceLastMod.token0;
         uint256 ciseExposure1 = pa.ciseExposureSinceLastMod.token1;
 
         // Phase 2 — queue bonuses using CISE exposure (coverage-indexed settled exposure)
         // Token direction mapping: fee pot in token T is funded by deficits in the opposite token.
         // - token0 pot ← token1 deficit coverage → use token1 exposure for token0 bonus
         // - token1 pot ← token0 deficit coverage → use token0 exposure for token1 bonus
         // This fixes the commitmentMax clamp bug where selfNet stays 0 for fully-settled positions
         bool allocated0 = _queueBonusForToken(pa, paPool, 0, 1, ciseExposure1);
         bool allocated1 = _queueBonusForToken(pa, paPool, 1, 0, ciseExposure0);
 
         // Banked exposure:
         // Only clear/decrement the windows if we actually queued a bonus for that token.
         // This ensures contributions remain eligible if potAvail was 0 at touch time.
         if (allocated0) _cleanupAfterAllocationForToken(pa, paPool, 1, ciseExposure1);
         if (allocated1) _cleanupAfterAllocationForToken(pa, paPool, 0, ciseExposure0);
 
         // Phase 3 — drain `slashedPot` for queued bonuses (and any other negative pending).
         BalanceDelta adjNeg = _finaliseNegativeFeeAdjustment(s, positionId, poolId);
         return adjPos + adjNeg;
     }
 
     /// @notice Uncapped fee processing (`positiveCap* = max`).
     function _processPositionFees(VTSStorage storage s, PositionId positionId) internal returns (BalanceDelta adj) {
         return _processPositionFees(s, positionId, type(uint256).max, type(uint256).max);
     }
 
     /// @dev Check if fee sharing is enabled for a pool
     function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) internal view returns (bool) {
         return s.pools[p].vtsConfig.coverageFeeShare > 0;
     }
 
     // --------------------------------------------------
     // Residual / coverage burn orchestration (linked from VTSPositionLib)
     // --------------------------------------------------
 
     /// @dev Residual fee backing is episode-scoped: once the matching burn base is exhausted,
     ///      any leftover backing on the opposite fee lane must not survive into a later residual episode.
     function _clearResolvedResidualFeeBacking(PositionAccounting storage pa, uint8 deficitTokenIndex) internal {
         if (pa.pendingResidualBurnBase.get(deficitTokenIndex) != 0) return;
 
         uint8 feeTokenIndex = deficitTokenIndex == 0 ? 1 : 0;
         pa.pendingResidualFeeBacking.set(feeTokenIndex, 0);
     }
 
     /// @dev Shared residual-backing capture: banks `liquidityScale * (fg - feeGrowthInsideLast)` per fee lane when
     ///      `pendingResidualBurnBase` implies that lane. Uses `getPositionInfo` fee growth (position snapshot after
     ///      modifyLiquidity), which stays authoritative after full removes that clear ticks.
     /// @param advanceFeeGrowthCheckpoint If true (full deactivation), set `feeGrowthInsideLast` to `fg` whenever
     ///        `fg > last`. If false (partial decrease), leave `feeGrowthInsideLast` unchanged for surviving liquidity.
     function _accumulateResidualFeeBackingForLanes(
         PositionAccounting storage pa,
         uint256 fg0,
+        // FIX: Also clear the new episode-scoped Q128 remainder accumulator to prevent cross-episode bleed:
+        // if (feeTokenIndex == 0) {
+        //     pa.residualFeeBackingRemainderX128.token0 = 0;
+        // } else {
+        //     pa.residualFeeBackingRemainderX128.token1 = 0;
+        // }
         uint256 fg1,
         bool needFeeToken0,
         bool needFeeToken1,
         uint256 liquidityScale,
         bool advanceFeeGrowthCheckpoint
     ) private {
         if (needFeeToken0) {
             uint256 last0 = pa.feeGrowthInsideLast.token0;
             if (fg0 > last0) {
+                // FIX: Use base+carry logic to avoid dropping modulo-Q128 remainder:
+                // rem0 = mulmod(fg0 - last0, liquidityScale, Q128);
+                // tot0 = pa.residualFeeBackingRemainderX128.token0 + rem0;
+                // extra0 = tot0 / Q128; pa.residualFeeBackingRemainderX128.token0 = tot0 % Q128;
+                // backing0 = FullMath.mulDiv(fg0 - last0, liquidityScale, Q128) + extra0;
                 uint256 backing0 = FullMath.mulDiv(fg0 - last0, liquidityScale, FixedPoint128.Q128);
                 if (backing0 > 0) pa.pendingResidualFeeBacking.token0 += backing0;
                 if (advanceFeeGrowthCheckpoint) pa.feeGrowthInsideLast.token0 = fg0;
             }
         }
 
         if (needFeeToken1) {
             uint256 last1 = pa.feeGrowthInsideLast.token1;
             if (fg1 > last1) {
+                // FIX: Mirror base+carry logic for token1 as for token0 above.
+                // rem1 = mulmod(fg1 - last1, liquidityScale, Q128);
+                // tot1 = pa.residualFeeBackingRemainderX128.token1 + rem1;
+                // extra1 = tot1 / Q128; pa.residualFeeBackingRemainderX128.token1 = tot1 % Q128;
+                // backing1 = FullMath.mulDiv(fg1 - last1, liquidityScale, Q128) + extra1;
                 uint256 backing1 = FullMath.mulDiv(fg1 - last1, liquidityScale, FixedPoint128.Q128);
                 if (backing1 > 0) pa.pendingResidualFeeBacking.token1 += backing1;
                 if (advanceFeeGrowthCheckpoint) pa.feeGrowthInsideLast.token1 = fg1;
             }
         }
     }
 
     /// @dev Loads pending-residual lanes, reads post-modify position fee growth from PoolManager, then banks backing.
     ///      Prefer `getPositionInfo` over range `getFeeGrowthInside` on full deactivation: after a full remove, Uniswap
     ///      may clear boundary ticks so range-based reads can be wrong; the position snapshot from `modifyLiquidity` is authoritative.
     function _captureResidualFeeBackingForLiquidityScale(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 liquidityScale,
         bool advanceFeeGrowthCheckpoint
     ) private {
         if (liquidityScale == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[id];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position memory pos = s.positions[id];
         (, uint256 fg0, uint256 fg1) = StateLibrary.getPositionInfo(poolManager, pos.poolId, PositionId.unwrap(id));
 
         _accumulateResidualFeeBackingForLanes(
             pa, fg0, fg1, needFeeToken0, needFeeToken1, uint256(liquidityScale), advanceFeeGrowthCheckpoint
         );
     }
 
     /// @notice Freeze unresolved residual-burn fee backing before a position deactivates to zero liquidity.
     /// @dev Captures fee growth accrued up to the remove call on the fee token lanes needed by pending residual burn.
     function _captureResidualFeeBackingOnDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 liquidityBeforeRemove
     ) internal {
         _captureResidualFeeBackingForLiquidityScale(s, poolManager, id, liquidityBeforeRemove, true);
     }
 
     /// @notice Bank fee-token backing for removed liquidity during a partial decrease while a residual episode is open.
     /// @dev Unlike full deactivation, does not advance `feeGrowthInsideLast`: remaining live liquidity keeps the same
     ///      baseline so `freshFees` on later burns still include its share of growth since the last checkpoint.
     function _captureResidualFeeBackingOnPartialDecrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 removedLiquidity
     ) internal {
         _captureResidualFeeBackingForLiquidityScale(s, poolManager, id, removedLiquidity, false);
     }
 
     /// @notice Apply banked residual-derived DICE burn against later outflow windows only
     function _applyBankedResidualBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint128 positionLiquidity
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
         uint256 pendingBurnBase = pa.pendingResidualBurnBase.get(tokenIndex);
         if (pendingBurnBase == 0) return;
 
         uint256 outflowFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
         uint256 consumedBurnBase =
             _applyBurnBase(s, poolManager, id, p, tokenIndex, pendingBurnBase, positionLiquidity, outflowFloor, true);
         if (consumedBurnBase > 0) {
             pa.pendingResidualBurnBase.set(tokenIndex, pendingBurnBase - consumedBurnBase);
             if (pendingBurnBase == consumedBurnBase) {
                 pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, 0);
                 _clearResolvedResidualFeeBacking(pa, tokenIndex);
             }
         }
     }
 
     // --------------------------------------------------
     // DICE / CISE coverage settlement (linked from VTSPositionLib.settlePositionGrowths)
     // --------------------------------------------------
 
     /// @notice Flush any pending deficit-indexed coverage residual into the DICE index
     function _flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         uint256 residual = paPool.coverageResidualDICE.get(tokenIndex);
         uint256 principal = paPool.totalDeficitPrincipal.get(tokenIndex);
 
         if (residual > 0 && principal > 0) {
             uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
             uint256 currentIndex = paPool.coveragePerResidualDeficitIndexX128.get(tokenIndex);
             paPool.coveragePerResidualDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
             paPool.coverageResidualDICE.set(tokenIndex, 0);
         }
     }
 
     function _settleCISEForToken(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 tokenIndex)
         internal
     {
         uint256 indexNow = paPool.coveragePerSettledIndexX128.get(tokenIndex);
         uint256 indexLast = pa.ciseIndexLastX128.get(tokenIndex);
 
         if (indexNow != indexLast) {
             pa.ciseIndexLastX128.set(tokenIndex, indexNow);
         }
 
         uint256 deltaIndex = indexNow - indexLast;
         if (deltaIndex > 0) {
             uint256 settled = pa.settled.get(tokenIndex);
             uint256 exposure = FullMath.mulDiv(settled, deltaIndex, FixedPoint128.Q128);
             if (exposure > 0) {
                 pa.ciseExposureSinceLastMod.set(tokenIndex, pa.ciseExposureSinceLastMod.get(tokenIndex) + exposure);
             }
         }
     }
 
     function _settleDICEForToken(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint128 liq
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 deficitPrincipal = pa.cumulativeDeficit.get(tokenIndex);
 
         _clearResolvedResidualFeeBacking(pa, tokenIndex);
 
         {
             uint256 residualIndexNow = s.poolAccounting[poolId].coveragePerResidualDeficitIndexX128.get(tokenIndex);
             uint256 residualIndexLast = pa.residualCoverageIndexLastX128.get(tokenIndex);
 
             if (residualIndexNow != residualIndexLast) {
                 pa.residualCoverageIndexLastX128.set(tokenIndex, residualIndexNow);
             }
 
             uint256 deltaResidualIndex = residualIndexNow - residualIndexLast;
             if (deltaResidualIndex > 0 && deficitPrincipal > 0) {
                 uint256 residualCov = FullMath.mulDiv(deficitPrincipal, deltaResidualIndex, FixedPoint128.Q128);
                 if (residualCov > 0) {
                     pa.pendingResidualBurnBase.set(tokenIndex, pa.pendingResidualBurnBase.get(tokenIndex) + residualCov);
 
                     uint256 curOutflows = pa.cumulativeOutflows.get(tokenIndex);
                     uint256 existingFloor = pa.pendingResidualBurnOutflowsFloor.get(tokenIndex);
                     if (curOutflows > existingFloor) {
                         pa.pendingResidualBurnOutflowsFloor.set(tokenIndex, curOutflows);
                     }
                 }
             }
         }
 
         {
             uint256 indexNow = s.poolAccounting[poolId].coveragePerDeficitIndexX128.get(tokenIndex);
             uint256 indexLast = pa.coverageIndexLastX128.get(tokenIndex);
 
             if (indexNow != indexLast) {
                 pa.coverageIndexLastX128.set(tokenIndex, indexNow);
             }
 
             uint256 deltaIndex = indexNow - indexLast;
             if (deltaIndex > 0 && deficitPrincipal > 0) {
                 uint256 cov = FullMath.mulDiv(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
                 if (cov > 0) {
                     _applyCoverageBurn(s, poolManager, positionId, poolId, tokenIndex, cov, liq);
                 }
             }
         }
 
         _applyBankedResidualBurn(s, poolManager, positionId, poolId, tokenIndex, liq);
     }
 
     function _settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         _settleDICEForToken(s, poolManager, positionId, poolId, 0, liq);
         _settleDICEForToken(s, poolManager, positionId, poolId, 1, liq);
     }
 
     function _settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) internal {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
 
         _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 0);
         _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 1);
     }
 
     /// @notice Apply coverage burn for a position (deficit-indexed coverage exercise → fee share)
     /// @dev Fees accrue on the input token, not the deficit token.
     function _applyCoverageBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint256 cov,
         uint128 positionLiquidity
     ) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         uint256 burnBase;
         {
             uint256 d = pa.cumulativeDeficit.get(tokenIndex);
             uint256 settled = pa.settled.get(tokenIndex);
             if (d == 0 && settled == 0) return;
 
             uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
             if (d == 0) return;
             burnBase = cEff < d ? cEff : d;
 
             if (burnBase == 0) return;
         }
 
         _applyBurnBase(s, poolManager, id, p, tokenIndex, burnBase, positionLiquidity, 0, false);
     }
 }
 
 /// @title VTSFeeLinkedLib
 /// @notice Library for VTS fee processing
 /// @dev Operates on VTSStorage storage struct via storage pointers
 library VTSFeeLinkedLib {
     /// @notice Prepares CSI state before minting fresh fee-share contributions for a position
     /// @dev Advances the spend epoch if needed, then syncs the position's remaining self-share
     ///      against the current pool factor before the caller increases `pendingFeeAdj` / `feesShared`.
     /// @param pa The position accounting storage reference
     /// @param paPool The pool accounting storage reference
     /// @param feeTokenIndex The fee token index receiving the newly minted contribution
     function beforeFeeShareMint(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 feeTokenIndex)
         external
     {
         VTSFeeLib._prepareFeeShareMint(pa, paPool, feeTokenIndex);
     }
 
     /// @notice Processes the fees for a position after touch
     /// @dev Updates accounting state only. Actual ERC6909 mint/burn is handled by CoreHook.settleHookDeltasToPot
     /// @param s The VTS storage
     /// @param positionId The position ID
     /// @return adj The materialised fee adjustment delta
     function afterTouchPosition(VTSStorage storage s, PositionId positionId) external returns (BalanceDelta adj) {
         return VTSFeeLib._processPositionFees(s, positionId);
     }
 
     /// @notice Processes position fees after touch with optional per-leg caps on positive slash materialisation.
     /// @dev Positive caps limit only the current-touch materialisation (`feeAdj`) for `pendingFeeAdj > 0`. Any excess
     ///      remains queued in `pendingFeeAdj`.
     function afterTouchPositionWithPositiveCaps(
         VTSStorage storage s,
         PositionId positionId,
         uint256 positiveCap0,
         uint256 positiveCap1
     ) external returns (BalanceDelta adj) {
         return VTSFeeLib._processPositionFees(s, positionId, positiveCap0, positiveCap1);
     }
 
     /// @notice Apply the fee-burn pipeline for a position and return the consumed outflow share
     function applyBurnBase(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         PoolId poolId,
         uint8 tokenIndex,
         uint256 burnBase,
         uint128 positionLiquidity,
         uint256 outflowFloor,
         bool consumeResidualFeeBacking
     ) external returns (uint256 consumedBurnBase) {
         return VTSFeeLib._applyBurnBase(
             s,
             poolManager,
             positionId,
             poolId,
             tokenIndex,
             burnBase,
             positionLiquidity,
             outflowFloor,
             consumeResidualFeeBacking
         );
     }
 
     /// @notice Episode-scoped cleanup when pending residual burn base is zero (DICE settle path)
     function clearResolvedResidualFeeBacking(PositionAccounting storage pa, uint8 deficitTokenIndex) external {
         VTSFeeLib._clearResolvedResidualFeeBacking(pa, deficitTokenIndex);
     }
 
     /// @notice Freeze unresolved residual-burn fee backing before deactivation to zero liquidity
     function captureResidualFeeBackingOnDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 liquidityBeforeRemove
     ) external {
         VTSFeeLib._captureResidualFeeBackingOnDeactivation(s, poolManager, id, liquidityBeforeRemove);
     }
 
     /// @notice Bank historical fee backing for the removed liquidity slice on partial decrease (residual episode open)
     function captureResidualFeeBackingOnPartialDecrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         uint128 removedLiquidity
     ) external {
         VTSFeeLib._captureResidualFeeBackingOnPartialDecrease(s, poolManager, id, removedLiquidity);
     }
 
     /// @notice Apply banked residual-derived burn against eligible outflow windows
     function applyBankedResidualBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint128 positionLiquidity
     ) external {
         VTSFeeLib._applyBankedResidualBurn(s, poolManager, id, p, tokenIndex, positionLiquidity);
     }
 
     /// @notice Apply coverage burn from deficit-indexed coverage exercise
     function applyCoverageBurn(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId id,
         PoolId p,
         uint8 tokenIndex,
         uint256 cov,
         uint128 positionLiquidity
     ) external {
         VTSFeeLib._applyCoverageBurn(s, poolManager, id, p, tokenIndex, cov, positionLiquidity);
     }
 
     /// @notice Flush pending deficit-indexed coverage residual into the DICE index when principal becomes non-zero
     function flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) external {
         VTSFeeLib._flushCoverageResidualIfNeeded(s, poolId, tokenIndex);
     }
 
     /// @notice Settle settled-indexed coverage usage (CISE) for both tokens
     function settleSettledIndexedCoverageUsage(VTSStorage storage s, PositionId positionId) external {
         VTSFeeLib._settleSettledIndexedCoverageUsage(s, positionId);
     }
 
     /// @notice Settle deficit-indexed coverage usage (DICE) for both tokens
     function settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         external
     {
         VTSFeeLib._settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
     }
 }
```

# Related findings

## [Informational] Per-call floor-without-remainder in residual fee-backing capture in VTSFeeLib during partial decreases causes dust-level underfunding of slashed pot/bonuses

### Description

Residual fee-backing capture on partial liquidity decreases floors each conversion from Q128 fee growth to raw tokens without a remainder carry. Splitting one removal into many partial decreases can reduce the total banked residual-backing versus a one-shot removal at the same fee-growth snapshot, slightly decreasing later feesBurn and slashed-pot funding. The effect is real but dust-level.

When a residual-burn episode is open, VTSFeeLib._captureResidualFeeBackingOnPartialDecrease → _captureResidualFeeBackingForLiquidityScale → _accumulateResidualFeeBackingForLanes [computes backing as floor((fg - last) * removedLiquidity / Q128) and adds it to pa.pendingResidualFeeBacking](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol#L619-L621) for the opposite fee-token lane. For partial decreases, [advanceFeeGrowthCheckpoint=false, so feeGrowthInsideLast remains unchanged for the surviving liquidity](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol#L666-L674), and the removed slice’s fractional remainder cannot reappear later as freshFees. Because the conversion floors per step without preserving a remainder, sum of per-step floors can be less than a single one-shot floor for the same total removedLiquidity at an identical fee-growth snapshot. Later, residual-derived burn [consumes pa.pendingResidualFeeBacking via _applyBankedResidualBurn → _applyBurnBase → _calculateFeesBurn](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol#L689-L694), so a slightly smaller banked amount marginally reduces feesBurn and thus slashed-pot funding (and pot-funded bonuses). The shortfall is dust-level and further diluted by coverageFeeShare bps and by the (consumedBurnBase/ofDelta) fraction.

### Severity

**Impact Explanation:** [Low] The effect underfunds the slashed pot by dust-level amounts per partial decrease; any shortfall is further reduced by coverageFeeShare bps and outflow consumption fractions, resulting in negligible asset impact.

**Likelihood Explanation:** [Low] Exploitation requires an open residual episode, RFS closed, quiet fee-growth windows, and many partial decreases; gas and operational costs outweigh the dust-level benefit.

### Exploitation

## Exploitation Scenarios:

### Scenario 1.
Many small partial decreases at nearly identical fee-growth: the position owner splits a total intended removal into many small [partial decreases](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol#L1153-L1158) during an open residual episode and a quiet fee window. Each step captures [floor((fg - last) * Li / Q128)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSFeeLib.sol#L619-L621) without remainder carry, making the sum of floors strictly less than the one-shot floor at the same fg. The removed slice’s dust cannot reappear as fresh fees, so pendingResidualFeeBacking is marginally smaller and later feesBurn/slashed-pot funding is slightly reduced.
#### Preconditions / Assumptions
- (a). An open residual-burn episode on one deficit lane (pa.pendingResidualBurnBase[token] > 0).
- (b). RFS is closed for the position or the caller operates in an authorized seizure context.
- (c). Fee growth inside (fg - last) remains effectively constant across the quick sequence (quiet window).
- (d). The position owner can perform multiple partial decreases.

### Scenario 2.
Calibrated zero-per-step captures: choose a tiny per-step removal Lunit so floor((fg - last) * Lunit / Q128) = 0, but floor((fg - last) * (N * Lunit) / Q128) ≥ 1. Performing N such partial decreases banks zero, whereas a one-shot removal at the same fg would bank at least one minimal token unit. Later residual-derived burn therefore underfunds by at least this minimal unit, reduced by coverage fee share and outflow consumption fractions.
#### Preconditions / Assumptions
- (a). All preconditions from Scenario 1.
- (b). Per-step removal size Lunit chosen so floor((fg - last) * Lunit / Q128) = 0 while floor((fg - last) * (N * Lunit) / Q128) ≥ 1.
- (c). Executions occur closely enough that the fee-growth snapshot is effectively the same for comparison.

### Scenario 3.
Cross-lane effect: with a token0 residual episode open (so token1 fee lane is captured), the owner splits decreases during a quiet window. Each partial decrease floors the token1 residual-backing without carry, marginally reducing token1 slashed pot and CISE/CSI bonuses that would be funded from it, letting the position retain slightly more net fees than under a one-shot removal at the same fg.
#### Preconditions / Assumptions
- (a). An open residual-burn episode on token0 (so the needed fee lane is token1), or vice versa.
- (b). RFS is closed for the position or the caller operates in an authorized seizure context.
- (c). Quiet fee-growth window to make the comparison fair to a one-shot at the same fg.
- (d). The position owner can perform multiple partial decreases.

### Proposed fix

#### VTSPositionLib.sol

File: `contracts/evm/src/libraries/VTSPositionLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/VTSPositionLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
 import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
 import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
 import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
 import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
 import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
 import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
 import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
 import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
 import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
 import {RFSCheckpoint} from "../types/Checkpoint.sol";
 import {
     VTSStorage,
     PositionAccounting,
     PoolAccounting,
     GrowthPair,
     MarketVTSConfiguration,
     TokenPairUint,
     TokenPairInt,
     TokenPairLib,
     PositionContext,
     TouchPositionParams,
     TouchPositionResult
 } from "../types/VTS.sol";
 import {
     PositionId,
     Position,
     PositionLibrary,
     PositionModificationHookData,
     PositionModificationHookDataLib
 } from "../types/Position.sol";
 import {Pool} from "../types/Pool.sol";
 import {LiquidityUtils} from "./LiquidityUtils.sol";
 import {Errors} from "./Errors.sol";
 import {VTSFeeLinkedLib} from "./VTSFeeLib.sol";
 import {VTSCommitLib} from "./VTSCommitLib.sol";
 import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
 import {IMarketVault} from "../interfaces/IMarketVault.sol";
 
 /// @title VTSPositionLib
 /// @notice Position lifecycle, registration, RFS, settlement, seizure, and growth accounting for VTS
 /// @dev External functions (called via VTSPositionLib.func()) have no underscore prefix.
 ///      Internal functions (called only within this library) have underscore prefix.
 /// @author Fiet Protocol
 library VTSPositionLib {
     using SafeCast for uint256;
     using SafeCast for int256;
     using SafeCast for int128;
     using TokenPairLib for TokenPairUint;
     using TokenPairLib for TokenPairInt;
     using StateLibrary for IPoolManager;
     using PoolIdLibrary for PoolKey;
 
     // ============ INTERNAL STRUCTS ============
 
     /// @dev Internal struct to reduce stack depth in `VTSPositionMMOpsLib` liquidity increase.
     struct LiquidityIncreaseParams {
         address owner;
         uint256 commitId;
         PositionId positionId;
         BalanceDelta principalDelta;
     }
 
     /// @dev Internal struct to reduce stack depth in _deltaAndCheckpointGrowth
     struct GrowthParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
         uint128 liquidity;
         uint256 global0;
         uint256 global1;
         bool isInflow;
     }
 
     // Maximum positive magnitude representable in int128
     uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
 
     // --------------------------------------------------
     // Commitment Tracking
     // --------------------------------------------------
 
     /// @notice Sets `commitmentMax` from live Uniswap position liquidity (single source of truth).
     /// @dev Per-delta rounded add/subtract bookkeeping is not equivalent to rounding once on the total;
     ///      incremental `ceil` arithmetic can drift below the true maxima for the remaining range.
     ///      Always derive from `liveLiquidity` after any modify that changes pool position liquidity.
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @param liveLiquidity Current position liquidity from PoolManager after the modify
     function _trackCommitment(VTSStorage storage s, PositionId positionId, uint128 liveLiquidity) internal {
         PositionAccounting storage pa = s.positionAccounting[positionId];
         if (liveLiquidity == 0) {
             pa.commitmentMax.token0 = 0;
             pa.commitmentMax.token1 = 0;
             return;
         }
         Position memory pos = s.positions[positionId];
         (uint256 c0, uint256 c1) = LiquidityUtils.calculateCommitmentMaxima(pos.tickLower, pos.tickUpper, liveLiquidity);
         pa.commitmentMax.token0 = c0;
         pa.commitmentMax.token1 = c1;
     }
 
     // --------------------------------------------------
     // Settlement Updates
     // --------------------------------------------------
 
     /// @notice Applies a settled delta to the pool-wide `totalSettled` aggregate
     /// @param paPool The pool accounting storage reference
     /// @param tokenIndex The token index (0 or 1)
     /// @param settledDelta The signed settled delta to apply
     function _applyPoolTotalSettledDelta(PoolAccounting storage paPool, uint8 tokenIndex, int256 settledDelta) private {
         if (settledDelta == 0) return;
 
         uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
 
         if (settledDelta >= 0) {
             paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
         } else {
             uint256 decSettled = uint256(-settledDelta);
             if (decSettled > currentTotalSettled) {
                 revert Errors.InvariantViolated("pool totalSettled underflow");
             }
             paPool.totalSettled.set(tokenIndex, currentTotalSettled - decSettled);
         }
     }
 
     /// @notice Updates pool accounting for settlement changes
     /// @dev Extracted to reduce stack depth in _updateSettlement
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param cur The previous settled amount
     /// @param next The new settled amount
     /// @param cumulativeDeficitCoverage The amount of cumulativeDeficit that was covered
     /// @return applied The helper-applied amount (cumulativeDeficit coverage + settled change)
     function _updatePoolAccounting(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         uint256 cur,
         uint256 next,
         uint256 cumulativeDeficitCoverage
     ) private returns (int256 applied) {
         Position memory pos = s.positions[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         int256 settledDelta = next.toInt256() - cur.toInt256();
 
         // DICE: Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
         // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
         if (cumulativeDeficitCoverage > 0) {
             uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
             // Safely decrement (should not underflow if accounting is consistent)
             uint256 newPrincipal =
                 cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
             paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
         }
 
         // CISE: Track pool-wide totalSettled aggregate
         _applyPoolTotalSettledDelta(paPool, tokenIndex, settledDelta);
 
         // Return helper-consumed amount: cumulativeDeficit coverage + settled change
         // Deposits (positive delta to _updateSettlement): returns positive value
         // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
         applied = cumulativeDeficitCoverage.toInt256() + settledDelta;
     }
 
     /// @notice "Silent" update settlement helper wrapper for contexts where we deliberately don't need the applied return value
     /// @dev Consumes the return value so static analysers don't flag ignored returns.
     function _sUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta) internal {
         int256 applied = _updateSettlement(s, id, tokenIndex, delta);
         applied;
     }
 
     /// @dev Nets a positive settlement delta against `commitmentDeficit` for one lane; isolated to reduce stack depth in `_vUpdateSettlement`.
     function _netCommitmentDeficitOnPositiveDelta(PositionAccounting storage pa, uint8 tokenIndex, int256 delta)
         private
         returns (int256 newDelta, uint256 commitmentDeficitCovered)
     {
         uint256 cd = pa.commitmentDeficit.get(tokenIndex);
         if (delta <= 0 || cd == 0) return (delta, 0);
 
         uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
         if (coverCd == 0) return (delta, 0);
 
         uint256 nextCd = cd - coverCd;
         pa.commitmentDeficit.set(tokenIndex, nextCd);
         if (nextCd == 0) {
             pa.commitmentDeficitSince.set(tokenIndex, 0);
         }
         return (delta - int256(coverCd), coverCd);
     }
 
     /// @notice Verbose settlement update: returns total economic consumption and the `pa.settled` lane delta separately.
     /// @dev `totalApplied` matches legacy `_updateSettlement` return (deficit coverage + settled change).
     ///      `settledDeltaOnly` is `next - cur` on `pa.settled` for this lane only; amounts that cure
     ///      `cumulativeDeficit` / `commitmentDeficit` without increasing settled appear only in `totalApplied`.
     function _vUpdateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 totalApplied, int256 settledDeltaOnly)
     {
         if (delta == 0) return (0, 0);
 
         PositionAccounting storage pa = s.positionAccounting[id];
         (uint256 oldRemnantS0, uint256 oldRemnantS1) = (pa.settled.token0, pa.settled.token1);
         (totalApplied, settledDeltaOnly) = _vUpdateSettlementCore(s, id, tokenIndex, delta, pa);
         _syncInactiveRemnantAfterSettledPairChange(s, id, oldRemnantS0, oldRemnantS1);
     }
 
     /// @dev Core settlement mutation split from `_vUpdateSettlement` to avoid stack-too-deep in the outer wrapper.
     function _vUpdateSettlementCore(
         VTSStorage storage s,
         PositionId id,
         uint8 tokenIndex,
         int256 delta,
         PositionAccounting storage pa
     ) private returns (int256 totalApplied, int256 settledDeltaOnly) {
         // Read current values in scoped block
         uint256 cur;
         uint256 c;
         uint256 cumulativeDef;
         {
             cur = pa.settled.get(tokenIndex);
             c = pa.commitmentMax.get(tokenIndex);
             cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
         }
 
         uint256 next = cur;
         // Track deficit netting by source:
         // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal (DICE denominator)
         // - totalDeficitCoverage: used for applied return semantics
         uint256 cumulativeDeficitCoverage = 0;
         uint256 totalDeficitCoverage = 0;
 
         if (delta > 0) {
             // Auto-net any lingering deficit first
             if (cumulativeDef > 0) {
                 uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                 if (cover > 0) {
                     cumulativeDef -= cover;
                     delta -= int256(cover);
                     cumulativeDeficitCoverage += cover;
                     totalDeficitCoverage += cover;
                 }
             }
 
             {
                 uint256 coveredCd;
                 (delta, coveredCd) = _netCommitmentDeficitOnPositiveDelta(pa, tokenIndex, delta);
                 totalDeficitCoverage += coveredCd;
             }
 
             // If position-level commitment deficit is fully cured, clear any stored severity bps.
             if (pa.commitmentDeficit.token0 == 0 && pa.commitmentDeficit.token1 == 0) {
                 pa.commitmentDeficitBps = 0;
             }
 
             if (delta > 0) {
                 next = cur + uint256(delta);
                 if (next > c) {
                     // clamp to commitment maxima
                     next = c;
                 }
             }
         } else {
             // Negative delta: reduce settled, never create deficit here
             uint256 subtract = uint256(-delta);
             if (cur < subtract) {
                 subtract = cur;
             }
             next = cur - subtract;
         }
 
         // Write back updated settlement
         pa.settled.set(tokenIndex, next);
         pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
 
         settledDeltaOnly = next.toInt256() - cur.toInt256();
 
         // Update pool accounting via helper function.
         // This returns cumulativeDeficitCoverage + settledDelta.
         totalApplied = _updatePoolAccounting(s, id, tokenIndex, cur, next, cumulativeDeficitCoverage);
 
         // Preserve existing semantics: include both cumulativeDeficit and commitmentDeficit netting in applied.
         if (totalDeficitCoverage > cumulativeDeficitCoverage) {
             totalApplied += SafeCast.toInt256(totalDeficitCoverage - cumulativeDeficitCoverage);
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when `isActive` flips but settled pair is unchanged
     ///      (liquidity mirror transition). O(1); no commit-wide scan.
     function _syncInactiveRemnantAfterActiveTransition(
         VTSStorage storage s,
         PositionId positionId,
         bool wasActive,
         uint256 settled0,
         uint256 settled1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         bool hasSettled = settled0 > 0 || settled1 > 0;
         bool oldShould = !wasActive && hasSettled;
         bool newShould = !pos.isActive && hasSettled;
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @dev Increments/decrements `Commit.inactiveRemnantCount` when only the settled pair changes while inactive.
     function _syncInactiveRemnantAfterSettledPairChange(
         VTSStorage storage s,
         PositionId positionId,
         uint256 oldS0,
         uint256 oldS1
     ) private {
         Position storage pos = s.positions[positionId];
         uint256 commitId = pos.commitId;
         if (commitId == 0) return;
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool inactive = !pos.isActive;
         bool oldShould = inactive && (oldS0 > 0 || oldS1 > 0);
         bool newShould = inactive && (pa.settled.token0 > 0 || pa.settled.token1 > 0);
         if (oldShould == newShould) return;
 
         if (newShould) {
             unchecked {
                 s.commits[commitId].inactiveRemnantCount++;
             }
         } else {
             uint256 cnt = s.commits[commitId].inactiveRemnantCount;
             if (cnt == 0) {
                 revert Errors.InvariantViolated("inactive remnant count underflow");
             }
             unchecked {
                 s.commits[commitId].inactiveRemnantCount = cnt - 1;
             }
         }
     }
 
     /// @notice Updates the settlement amount by a delta which could be positive or negative
     /// @dev Shared by both local settlement flows and `VTSLifecycleLinkedLib`'s MM settlement path.
     ///      Nets against cumulative deficit, then derived commit deficit, then applies to settled.
     /// @param s The central VTS storage
     /// @param id The position id
     /// @param tokenIndex The token index (0 or 1)
     /// @param delta The delta of the settlement
     /// @return applied The total amount applied (deficit coverage + settled increase)
     function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
         internal
         returns (int256 applied)
     {
         (applied,) = _vUpdateSettlement(s, id, tokenIndex, delta);
     }
 
     // --------------------------------------------------
     // Growth Accounting Helper Functions
     // --------------------------------------------------
 
     /// @notice Compute inside growth for a position range using Uniswap-style "global/outside" accounting.
     /// @dev This mirrors Uniswap v4 core fee accounting:
     ///      - Branching formula: `Pool.getFeeGrowthInside()` in
     ///        `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`
     ///      - Unchecked arithmetic is used intentionally to match Uniswap's modulo \(2^{256}\) behaviour.
     ///
     ///      Intuition:
     ///      - `global*` accumulators are "amount-per-liquidity-unit" in Q128.
     ///      - `outsideMap[poolId][tick]` stores growth on the _other_ side of that tick relative to the current tick,
     ///        maintained by flipping on each tick cross (see `VTSSwapLib._flipOutside`, derived from `Pool.crossTick`).
     ///      - "inside growth" for [tickLower, tickUpper) depends on where the current tick sits relative to the range.
     /// @param poolId The pool ID
     /// @param tickLower The lower tick
     /// @param tickUpper The upper tick
     /// @param tickCurrent The current pool tick
     /// @param global0 The global growth for token0
     /// @param global1 The global growth for token1
     /// @param outsideMap The outside growth mapping (deficitGrowthOutside or inflowGrowthOutside)
     /// @return inside0 The inside growth for token0
     /// @return inside1 The inside growth for token1
     function _growthInside(
         PoolId poolId,
         int24 tickLower,
         int24 tickUpper,
         int24 tickCurrent,
         uint256 global0,
         uint256 global1,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
     ) private view returns (uint256 inside0, uint256 inside1) {
         GrowthPair memory lower = outsideMap[poolId][tickLower];
         GrowthPair memory upper = outsideMap[poolId][tickUpper];
         inside0 = _growthInsideSingle(global0, lower.token0, upper.token0, tickCurrent, tickLower, tickUpper);
         inside1 = _growthInsideSingle(global1, lower.token1, upper.token1, tickCurrent, tickLower, tickUpper);
     }
 
     /// @notice Compute inside growth for a single token, branching on current tick (Uniswap-style)
     /// @dev Derived from Uniswap v4 core `Pool.getFeeGrowthInside()`:
     ///      `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
     ///
     ///      Why branching matters:
     ///      - Growth accrues to the active tick/liquidity at the moment it occurs (in our case, per swap segment).
     ///      - A position should only accrue growth while it is in-range (i.e. while current tick is within its bounds).
     ///      - When out-of-range, the position's "inside growth" should remain stable until price re-enters the range.
     ///
     ///      Why `unchecked`:
     ///      - Uniswap treats these accumulators as values modulo \(2^{256}\) (wraparound is acceptable and expected).
     function _growthInsideSingle(
         uint256 global,
         uint256 outsideLower,
         uint256 outsideUpper,
         int24 tickCurrent,
         int24 tickLower,
         int24 tickUpper
     ) private pure returns (uint256 inside) {
         unchecked {
             if (tickCurrent < tickLower) {
                 // Current tick below range: inside = outsideLower - outsideUpper
                 inside = outsideLower - outsideUpper;
             } else if (tickCurrent >= tickUpper) {
                 // Current tick at/above range: inside = outsideUpper - outsideLower
                 inside = outsideUpper - outsideLower;
             } else {
                 // Current tick inside range: inside = global - outsideLower - outsideUpper
                 inside = global - outsideLower - outsideUpper;
             }
         }
     }
 
     /// @notice Compute delta and checkpoint for growth settlement
     /// @dev This is the exact same pattern as Uniswap fees:
     ///      owed = (growthInsideNow - growthInsideLast) * liquidity / Q128, then checkpoint growthInsideLast = growthInsideNow.
     ///
     ///      We checkpoint *before* liquidity changes (see `CoreHook._beforeAddLiquidity/_beforeRemoveLiquidity`) to ensure:
     ///      - no retroactive capture (new liquidity cannot claim historical accrual), and
     ///      - fair attribution across partial adds/removes.
     /// @param pa The position accounting storage reference
     /// @param outsideMap The outside growth mapping
     /// @param p Growth parameters bundled in a struct (poolId, ticks, liquidity, globals, growthType)
     /// @return add0 The attributed growth delta for token0
     /// @return add1 The attributed growth delta for token1
     function _deltaAndCheckpointGrowth(
         PositionAccounting storage pa,
         mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
         GrowthParams memory p
     ) private returns (uint256 add0, uint256 add1) {
         (uint256 inside0, uint256 inside1) = _growthInside(
             p.poolId, p.tickLower, p.tickUpper, p.tickCurrent, p.global0, p.global1, outsideMap
         );
 
         // Read last snapshots based on field identifier
         uint256 lastSnap0;
         uint256 lastSnap1;
         if (!p.isInflow) {
             lastSnap0 = pa.deficitGrowthInsideLast.token0;
             lastSnap1 = pa.deficitGrowthInsideLast.token1;
             pa.deficitGrowthInsideLast.token0 = inside0;
             pa.deficitGrowthInsideLast.token1 = inside1;
         } else {
             lastSnap0 = pa.inflowGrowthInsideLast.token0;
             lastSnap1 = pa.inflowGrowthInsideLast.token1;
             pa.inflowGrowthInsideLast.token0 = inside0;
             pa.inflowGrowthInsideLast.token1 = inside1;
         }
 
         unchecked {
             uint256 d0 = inside0 - lastSnap0;
             uint256 d1 = inside1 - lastSnap1;
             if (p.liquidity > 0) {
                 if (d0 > 0) {
                     add0 = FullMath.mulDiv(d0, uint256(p.liquidity), FixedPoint128.Q128);
                 }
                 if (d1 > 0) {
                     add1 = FullMath.mulDiv(d1, uint256(p.liquidity), FixedPoint128.Q128);
                 }
             }
         }
     }
 
     /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Calculate growth delta in scoped block
         uint256 add0;
         uint256 add1;
         {
             (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
             uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
             (add0, add1) = _deltaAndCheckpointGrowth(
                 pa,
                 s.deficitGrowthOutside,
                 GrowthParams({
                     poolId: poolId,
                     tickLower: pos.tickLower,
                     tickUpper: pos.tickUpper,
                     tickCurrent: tickCurrent,
                     liquidity: liq,
                     global0: paPool.deficitGrowthGlobal.token0,
                     global1: paPool.deficitGrowthGlobal.token1,
                     isInflow: false
                 })
             );
         }
 
         // Process token0 deficit in scoped block
         if (add0 > 0) {
             // Track full attributed outflows for fee sharing normalisation window
             pa.cumulativeOutflows.token0 += add0;
 
             // Consume settled coverage first, then accrue shortfall to deficit
             uint256 s0 = pa.settled.token0;
             if (s0 >= add0) {
                 _sUpdateSettlement(s, positionId, 0, -add0.toInt256());
             } else {
                 uint256 deficitIncrease = add0 - s0;
                 pa.cumulativeDeficit.token0 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 0);
                 _sUpdateSettlement(s, positionId, 0, -s0.toInt256());
             }
         }
 
         // Process token1 deficit in scoped block
         if (add1 > 0) {
             pa.cumulativeOutflows.token1 += add1;
             uint256 s1 = pa.settled.token1;
             if (s1 >= add1) {
                 _sUpdateSettlement(s, positionId, 1, -add1.toInt256());
             } else {
                 uint256 deficitIncrease = add1 - s1;
                 pa.cumulativeDeficit.token1 += deficitIncrease;
                 // DICE: Track pool-wide deficit principal increase
                 paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                 // DICE: Flush any pending coverage residual now that principal exists
                 VTSFeeLinkedLib.flushCoverageResidualIfNeeded(s, poolId, 1);
                 _sUpdateSettlement(s, positionId, 1, -s1.toInt256());
             }
         }
     }
 
     /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
         internal
     {
         Position memory pos = s.positions[positionId];
         PoolId poolId = pos.poolId;
         // Current tick is required for correct inside-growth branching (Uniswap-style).
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));
 
         PoolAccounting storage paPool = s.poolAccounting[poolId];
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
             pa,
             s.inflowGrowthOutside,
             GrowthParams({
                 poolId: poolId,
                 tickLower: pos.tickLower,
                 tickUpper: pos.tickUpper,
                 tickCurrent: tickCurrent,
                 liquidity: liq,
                 global0: paPool.inflowGrowthGlobal.token0,
                 global1: paPool.inflowGrowthGlobal.token1,
                 isInflow: true
             })
         );
 
         // Token0: net against deficit first
         if (add0 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 0, add0.toInt256());
         }
 
         // Token1: net against deficit first
         if (add1 > 0) {
             // Auto-net and apply via centralised updater
             _sUpdateSettlement(s, positionId, 1, add1.toInt256());
         }
     }
 
     /// @dev If Uniswap position liquidity changed without `touchPosition` (e.g. paused remove-liquidity in CoreHook),
     ///      `feeBurnGrowthRemainder` is invalid for the new denominator; clear it.
     ///      We do not overwrite `pos.liquidity` here: harness-only setups may diverge from PoolManager reads; the next
     ///      `touchPosition` still updates the mirror. DICE/coverage burn uses `StateLibrary.getPositionLiquidity` for L.
     function _reconcileLiquidityMirrorAndFeeBurnRemainder(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId
     ) private {
         Position storage pos = s.positions[positionId];
         if (pos.owner == address(0)) return;
 
         uint128 liqLive = StateLibrary.getPositionLiquidity(poolManager, pos.poolId, PositionId.unwrap(positionId));
         if (uint256(pos.liquidity) != uint256(liqLive)) {
             PositionAccounting storage pa = s.positionAccounting[positionId];
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
     }
 
     /// @notice Settle both deficit, inflow, and coverage growth for a position
     /// @param s The central VTS storage
     /// @param poolManager The pool manager contract
     /// @param positionId The position ID
     //#olympix-ignore-reentrancy
     function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
         _reconcileLiquidityMirrorAndFeeBurnRemainder(s, poolManager, positionId);
 
         VTSFeeLinkedLib.settleSettledIndexedCoverageUsage(s, positionId);
 
         _settlePositionDeficitGrowth(s, poolManager, positionId);
         // DICE ordering invariant:
         // Before decreasing cumulativeDeficit, we must reconcile the position up to the current
         // coverage-per-deficit index. If inflow netting runs first, the position shrinks principal
         // before we apply already-exercised coverage, understating burn and letting it evade charges
         // incurred while that principal was outstanding.
         VTSFeeLinkedLib.settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
         // Only after DICE has been settled may inflow repay/net principal.
         _settlePositionInflowGrowth(s, poolManager, positionId);
     }
 
     // --------------------------------------------------
     // Position Registration and Management
     // --------------------------------------------------
 
     /// @notice Register a new position in VTSStorage
     /// @param s The VTS storage
     /// @param owner The owner of the position
     /// @param poolId The pool id
     /// @param params The modify liquidity params
     function _registerPosition(
         VTSStorage storage s,
         address owner,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) internal {
         // Derive position id consistent with Uniswap position keying
         PositionId id = PositionLibrary.generateId(owner, params);
 
         // Check if already registered
         if (s.positions[id].owner != address(0)) {
             revert Errors.AlreadyRegistered(id);
         }
 
         // Register the position in VTSStorage
         s.positions[id] = Position({
             owner: owner,
             poolId: poolId,
             commitId: 0, // Will be set when position is associated with a commit
             tickLower: params.tickLower,
             tickUpper: params.tickUpper,
             liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
             isActive: true,
             salt: params.salt,
             checkpoint: RFSCheckpoint({
                 openMask: 0, openSince0: 0, openSince1: 0, gracePeriodExtension0: 0, gracePeriodExtension1: 0
             })
         });
     }
 
     function _rfsOpenMask(BalanceDelta delta) internal pure returns (uint8 openMask) {
         if (delta.amount0() > 0) {
             openMask |= 1;
         }
         if (delta.amount1() > 0) {
             openMask |= 2;
         }
     }
 
     /// @notice Link a position to a commit
     /// @param s The VTS storage
     /// @param positionId The position id
     /// @param commitId The token id (commit id)
     function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
         // validate there is an existing commit for the token id
         if (s.commits[commitId].expiresAt <= block.timestamp) {
             revert Errors.InvalidSignal(commitId);
         }
 
         // Get current position count to use as index for the new position
         uint256 currentPositionCount = s.commits[commitId].positionCount;
 
         // modify the commit to include the position and update the position count
         s.commits[commitId].positions[currentPositionCount] = positionId;
         s.commits[commitId].positionCount++;
 
         // update the commitId of the position i.e associate the position with the commit
         s.positions[positionId].commitId = commitId;
     }
 
     /// @notice Calculate RFS (Required for Settlement) for a position
     /// @param s The VTS storage
     /// @param poolManager The pool manager
     /// @param id The position id
     /// @param requireClosedRfS Whether to require the RFS to be closed
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The RFS delta
     function calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
         public
         returns (bool rfsOpen, BalanceDelta delta)
     {
         // Settle position growths before calculating RFS
         settlePositionGrowths(s, poolManager, id);
 
         (rfsOpen, delta) = getRFS(s, id);
         if (requireClosedRfS && rfsOpen) {
             revert Errors.RFSOpenForPosition(id);
         }
     }
 
     /// @dev Snapshot parameters for init position
     struct SnapshotParams {
         PoolId poolId;
         int24 tickLower;
         int24 tickUpper;
         int24 tickCurrent;
     }
 
     /// @dev Initialise deficit growth snapshot
     function _initDeficitSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 d0, uint256 d1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.deficitGrowthGlobal.token0,
             paPool.deficitGrowthGlobal.token1,
             s.deficitGrowthOutside
         );
         pa.deficitGrowthInsideLast.token0 = d0;
         pa.deficitGrowthInsideLast.token1 = d1;
     }
 
     /// @dev Initialise inflow growth snapshot
     function _initInflowSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         (uint256 i0, uint256 i1) = _growthInside(
             sp.poolId,
             sp.tickLower,
             sp.tickUpper,
             sp.tickCurrent,
             paPool.inflowGrowthGlobal.token0,
             paPool.inflowGrowthGlobal.token1,
             s.inflowGrowthOutside
         );
         pa.inflowGrowthInsideLast.token0 = i0;
         pa.inflowGrowthInsideLast.token1 = i1;
     }
 
     /// @dev Initialise fee growth snapshot
     function _initFeeSnapshot(IPoolManager poolManager, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, sp.poolId, sp.tickLower, sp.tickUpper);
         pa.feeGrowthInsideLast.token0 = fg0;
         pa.feeGrowthInsideLast.token1 = fg1;
         pa.feeBurnGrowthRemainder.token0 = 0;
         pa.feeBurnGrowthRemainder.token1 = 0;
     }
 
     /// @dev Initialise DICE coverage index snapshot
     /// @notice Sets coverageIndexLastX128 to current pool coveragePerDeficitIndexX128
     ///         to prevent new positions from inheriting historical coverage charges
     function _initCoverageSnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp)
         private
     {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         // DICE: Initialize coverage index checkpoint to current pool index
         // This ensures new positions don't inherit historical coverage charges
         pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
         pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
         pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
     }
 
     /// @dev Initialise CISE coverage index snapshot
     /// @notice Sets ciseIndexLastX128 to current pool coveragePerSettledIndexX128
     ///         to prevent new positions from inheriting historical settled-indexed coverage
     function _initCISESnapshot(VTSStorage storage s, PositionAccounting storage pa, SnapshotParams memory sp) private {
         PoolAccounting storage paPool = s.poolAccounting[sp.poolId];
         pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
     }
 
     /// @dev Seed per-tick outside growth snapshots when a tick is initialised by this liquidity add.
     ///      This moves first-write cost from swap-time tick crossing to modify-liquidity time.
     ///      Mirrors Uniswap initialisation semantics: if tick <= currentTick, outside starts at global, else 0.
     function _seedOutsideGrowthForNewlyInitializedTicks(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         ModifyLiquidityParams calldata params
     ) private {
         if (params.liquidityDelta <= 0) return;
 
         uint128 addLiq = uint256(params.liquidityDelta).toUint128();
         (uint128 lowerGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickLower);
         (uint128 upperGross,) = StateLibrary.getTickLiquidity(poolManager, poolId, params.tickUpper);
 
         bool lowerInitializedByThisAdd = lowerGross == addLiq;
         bool upperInitializedByThisAdd = upperGross == addLiq;
         if (!lowerInitializedByThisAdd && !upperInitializedByThisAdd) return;
 
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, poolId);
         PoolAccounting storage paPool = s.poolAccounting[poolId];
 
         if (lowerInitializedByThisAdd) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickLower, tickCurrent);
         }
         if (upperInitializedByThisAdd && params.tickUpper != params.tickLower) {
             _seedOutsideAtInitializedTick(s, paPool, poolId, params.tickUpper, tickCurrent);
         }
     }
 
     function _seedOutsideAtInitializedTick(
         VTSStorage storage s,
         PoolAccounting storage paPool,
         PoolId poolId,
         int24 tick,
         int24 tickCurrent
     ) private {
         if (tick > tickCurrent) return;
 
         s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
         s.deficitGrowthOutside[poolId][tick].token1 = paPool.deficitGrowthGlobal.token1;
         s.inflowGrowthOutside[poolId][tick].token0 = paPool.inflowGrowthGlobal.token0;
         s.inflowGrowthOutside[poolId][tick].token1 = paPool.inflowGrowthGlobal.token1;
     }
 
     /// @notice Checkpoint the tick-indexed growth snapshots at the current pool state.
     /// @dev Used for both first-time registration and inactive-position reactivation so zero-liquidity intervals
     ///      cannot be retroactively attributed to freshly added liquidity.
     function _checkpointTickIndexedSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         PositionAccounting storage pa = s.positionAccounting[id];
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
 
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initDeficitSnapshot(s, pa, sp);
         _initInflowSnapshot(s, pa, sp);
         _initFeeSnapshot(poolManager, pa, sp);
     }
 
     /// @notice Rebase zero-principal settlement snapshots during inactive-position reactivation.
     /// @dev Only lanes with no current settled / deficit principal are checkpointed to current pool indices.
     ///      Non-zero lanes keep their historical checkpoints so previously-earned DICE / CISE state is preserved.
     function _checkpointZeroPrincipalSettlementSnapshots(VTSStorage storage s, PositionId id) internal {
         Position memory pos = s.positions[id];
         PositionAccounting storage pa = s.positionAccounting[id];
         PoolAccounting storage paPool = s.poolAccounting[pos.poolId];
 
         if (pa.cumulativeDeficit.token0 == 0) {
             pa.coverageIndexLastX128.token0 = paPool.coveragePerDeficitIndexX128.token0;
             pa.residualCoverageIndexLastX128.token0 = paPool.coveragePerResidualDeficitIndexX128.token0;
         }
         if (pa.cumulativeDeficit.token1 == 0) {
             pa.coverageIndexLastX128.token1 = paPool.coveragePerDeficitIndexX128.token1;
             pa.residualCoverageIndexLastX128.token1 = paPool.coveragePerResidualDeficitIndexX128.token1;
         }
         if (pa.settled.token0 == 0) {
             pa.ciseIndexLastX128.token0 = paPool.coveragePerSettledIndexX128.token0;
         }
         if (pa.settled.token1 == 0) {
             pa.ciseIndexLastX128.token1 = paPool.coveragePerSettledIndexX128.token1;
         }
     }
 
     /**
      * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
      * @param s The central VTS storage
      * @param poolManager The pool manager contract
      * @param id The id of the position
      */
     function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
         PositionAccounting storage pa = s.positionAccounting[id];
 
         _checkpointTickIndexedSnapshots(s, poolManager, id);
 
         Position memory pos = s.positions[id];
         PoolId p = pos.poolId;
         (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);
         SnapshotParams memory sp =
             SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});
 
         _initCoverageSnapshot(s, pa, sp);
         _initCISESnapshot(s, pa, sp);
     }
 
     /// @notice Touch a position to update its state, process fees, and handle MM-specific operations
     /// @dev Single entry point for position processing - handles registration, linking, fee processing,
     ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
     /// @param s The VTS storage
     /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
     /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
     /// @return result The touchPosition result (pos, id, feeAdj)
     /// @notice Decoded hook data for touch position operations
     struct TouchPositionHookData {
         bool isMMOperation;
         bool isSeizing;
         uint256 commitId;
     }
 
     /// @notice Decodes and validates hook data for touch position
     /// @dev Effective `isSeizing` is only true for MM operations (`commitId > 0`) with `seizure.isSeizing`.
     ///      Non-MM callers cannot grant seizure semantics by forging hook bytes.
     /// @param hookData The raw hook data bytes
     /// @return data The decoded hook data struct
     function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
         PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
         data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
         data.commitId = mmData.commitId;
         data.isSeizing = data.isMMOperation && mmData.seizure.isSeizing;
     }
 
     /// @notice Handles new position initialization and returns required settlement delta
     function _touchNewPosition(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         address owner,
         ModifyLiquidityParams calldata params,
         PositionId positionId,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         if (hookData.isMMOperation && hookData.isSeizing) {
             revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
         }
 
         _registerPosition(s, owner, poolId, params);
 
         if (hookData.isMMOperation && hookData.commitId > 0) {
             _linkPositionToCommit(s, positionId, hookData.commitId);
         }
 
         _initPositionSnapshots(s, poolManager, positionId);
         if (uint256(params.liquidityDelta).toUint128() != liveLiquidityAfterModify) {
             revert Errors.InvariantViolated("live liquidity mismatch on new position touch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         TokenPairUint memory commitmentMaxima = s.positionAccounting[positionId].commitmentMax;
 
         if (hookData.isMMOperation) {
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position decrease: RFS gate, commitment tracking, settled clamp / MM excess delta.
     /// @param currentLiq Live PoolManager liquidity after the remove (same as unpaused `touchPosition` decrease path).
     /// @dev RFS uses `getRFS` only; growth is already settled in CoreHook `_beforeRemoveLiquidity` — avoid `calcRFS` here
     ///      so we do not re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
     function _touchExistingDecrease(
         VTSStorage storage s,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 currentLiq,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posDec = s.positions[positionId];
         if (params.tickLower != posDec.tickLower || params.tickUpper != posDec.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         // Growth is already settled in CoreHook `_beforeRemoveLiquidity`; avoid `calcRFS` here so we do not
         // re-enter `settlePositionGrowths` (would double-apply CISE / growth side-effects in the same modify).
         // RFS-open removes revert unless this is an authorised MM seizure decrease (`isMMOperation && isSeizing`);
         // non-MM forged `seizure.isSeizing` is cleared in `_decodeHookData`.
         if (!(hookData.isMMOperation && hookData.isSeizing)) {
             (bool rfsOpen,) = getRFS(s, positionId);
             if (rfsOpen) {
                 revert Errors.RFSOpenForPosition(positionId);
             }
         }
         _trackCommitment(s, positionId, currentLiq);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         (uint256 excess0, uint256 excess1) = _computeSettledExcessAgainstCommitmentMax(pa, currentLiq);
 
         if (hookData.isMMOperation) {
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
         } else {
             _applySettlementClampFromExcess(s, positionId, excess0, excess1);
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @notice Handles existing position increase and returns required settlement delta
     function _touchExistingIncrease(
         VTSStorage storage s,
         PoolId poolId,
         PositionId positionId,
         ModifyLiquidityParams calldata params,
         uint128 liveLiquidityAfterModify,
         TouchPositionHookData memory hookData
     ) private returns (BalanceDelta requiredSettlementDelta) {
         Position memory posInc = s.positions[positionId];
         if (params.tickLower != posInc.tickLower || params.tickUpper != posInc.tickUpper) {
             revert Errors.InvariantViolated("modify tick mismatch");
         }
         _trackCommitment(s, positionId, liveLiquidityAfterModify);
 
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
 
         if (hookData.isMMOperation) {
             if (hookData.isSeizing) {
                 revert Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs");
             }
 
             MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
             (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                 commitmentMaxima.token0,
                 commitmentMaxima.token1,
                 vtsConfiguration.token0.baseVTSRate,
                 vtsConfiguration.token1.baseVTSRate
             );
             uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
             uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;
             requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
         } else {
             _sUpdateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
             _sUpdateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
             requiredSettlementDelta = BalanceDelta.wrap(0);
         }
     }
 
     /// @dev Extracted to keep `touchPosition` stack-safe when branching on fee-cap policy.
     function _afterTouchPositionFees(
         VTSStorage storage s,
         PositionId positionId,
         BalanceDelta feesAccrued,
         bool capPositiveSlashToFeesAccrued
     ) private returns (BalanceDelta feeAdj) {
         if (!capPositiveSlashToFeesAccrued) {
             return VTSFeeLinkedLib.afterTouchPosition(s, positionId);
         }
         int128 fa0 = feesAccrued.amount0();
         int128 fa1 = feesAccrued.amount1();
         uint256 positiveCap0 = fa0 > 0 ? uint256(uint128(fa0)) : 0;
         uint256 positiveCap1 = fa1 > 0 ? uint256(uint128(fa1)) : 0;
         return VTSFeeLinkedLib.afterTouchPositionWithPositiveCaps(s, positionId, positiveCap0, positiveCap1);
     }
 
     //#olympix-ignore-reentrancy
     function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
         external
         returns (TouchPositionResult memory result)
     {
         PoolId poolId = p.poolKey.toId();
         bool isPaused = s.isPaused || s.pools[poolId].isPaused;
         if (isPaused && p.params.liquidityDelta >= 0) {
             revert Errors.EnforcedPause();
         }
         _seedOutsideGrowthForNewlyInitializedTicks(s, ctx.poolManager, poolId, p.params);
 
         result.id = PositionLibrary.generateId(p.owner, p.params);
         Position storage posStorage = s.positions[result.id];
         bool isNewPosition = posStorage.owner == address(0);
         uint256 initialLiquidity = posStorage.liquidity;
         uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));
 
         TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
         BalanceDelta requiredSettlementDelta;
 
         if (isNewPosition) {
             if (p.params.liquidityDelta <= 0) {
                 revert Errors.InvalidPosition(0, 0, result.id);
             }
             // NEW POSITION
             requiredSettlementDelta =
                 _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, liq, hookData);
         } else {
             // EXISTING POSITION (active or previously inactive)
 
             // Validate no mismatch if commit ID present.
             if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                 revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
             }
 
             // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
             // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
             if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
                 PositionAccounting storage paGuard = s.positionAccounting[result.id];
                 if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                     revert Errors.CommitmentDeficitBlocksLiquidityChange(result.id);
                 }
             }
 
             if (p.params.liquidityDelta < 0) {
                 // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                 if (!posStorage.isActive) revert Errors.NotActive(result.id);
                 requiredSettlementDelta = _touchExistingDecrease(s, result.id, p.params, liq, hookData);
                 // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
                 PositionAccounting storage paDec = s.positionAccounting[result.id];
                 if (liq == 0) {
                     _captureResidualFeeBackingOnFullDeactivation(
                         s, ctx.poolManager, result.id, liq, p.params.liquidityDelta
                     );
                 } else {
                     uint128 removedLiquidity = uint256(-p.params.liquidityDelta).toUint128();
                     VTSFeeLinkedLib.captureResidualFeeBackingOnPartialDecrease(
                         s, ctx.poolManager, result.id, removedLiquidity
                     );
                 }
                 _applyLiquidityMirrorTransition(s, result.id, paDec, posStorage, initialLiquidity, liq);
             } else {
                 (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                     _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
                 if (p.params.liquidityDelta > 0) {
                     // Allow re-activating a previously inactive position by adding liquidity.
                     // Logically required to build on value routing while collecting fees on inactive positions.
                     // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                     // the newly reactivated liquidity.
                     if (liveLiquidityBeforeAdd == 0) {
                         _checkpointTickIndexedSnapshots(s, ctx.poolManager, result.id);
                         _checkpointZeroPrincipalSettlementSnapshots(s, result.id);
                     }
                     requiredSettlementDelta =
                         _touchExistingIncrease(s, poolId, result.id, p.params, nextLiquidity, hookData);
                     if (liveLiquidityBeforeAdd > 0) {
                         _rebaseResidualFeeGrowthOnActiveIncrease(
                             s, ctx.poolManager, poolId, result.id, liveLiquidityBeforeAdd
                         );
                     }
                 } else {
                     // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                     // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                     // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                     _trackCommitment(s, result.id, liq);
                     requiredSettlementDelta = BalanceDelta.wrap(0);
                 }
                 PositionAccounting storage paRem = s.positionAccounting[result.id];
                 _applyLiquidityMirrorTransition(
                     s, result.id, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
                 );
             }
         }
 
         if (isNewPosition) {
             _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
         }
 
         // On any liquidity decrease, cap same-touch positive `pendingFeeAdj` materialisation to the
         // per-leg informational `feesAccrued` slice; excess remains banked in `pendingFeeAdj` (SETTLE-03).
         result.feeAdj = _afterTouchPositionFees(s, result.id, p.feesAccrued, p.params.liquidityDelta < 0);
 
         if (hookData.isMMOperation) {
             VTSPositionMMOpsLib.processMMOperations(s, ctx, p, result, requiredSettlementDelta);
         }
 
         // Refresh from storage after the MM tail. `processMMOperations` is an external linked-library call; mutating
         // `TouchPositionResult` inside it does not update this caller's memory return value.
         result.pos = s.positions[result.id];
     }
 
     /// @notice Update active status based on liquidity transitions
     /// @dev Extracted to reduce stack pressure in touchPosition
     function _updateActiveStatus(
         VTSStorage storage s,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) internal {
         // Update active status based on liquidity
         // Track transitions to update activePositionCount for commits
         uint256 commitId = posStorage.commitId;
 
         if (liq == 0) {
             posStorage.isActive = false;
             // Decrement activePositionCount if transitioning from active(liq > 0) to inactive(liq == 0)
             if (initialLiquidity > 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount--;
             }
         } else {
             posStorage.isActive = true;
             // Increment activePositionCount if transitioning from inactive(liq == 0) to active(liq > 0)
             if (initialLiquidity == 0 && commitId > 0) {
                 s.commits[commitId].activePositionCount++;
             }
         }
     }
 
     /// @dev Runs `_updateActiveStatus` then `Commit.inactiveRemnantCount` sync in a separate stack frame.
     function _updateStatus(
         VTSStorage storage s,
         PositionId positionId,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 liq
     ) private {
         bool wasActive = posStorage.isActive;
         PositionAccounting storage pa = s.positionAccounting[positionId];
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         _updateActiveStatus(s, posStorage, initialLiquidity, liq);
         _syncInactiveRemnantAfterActiveTransition(s, positionId, wasActive, s0, s1);
     }
 
     function _deriveIncreaseTransitionLiquidity(uint128 liq, int256 liquidityDelta)
         internal
         pure
         returns (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity)
     {
         if (liquidityDelta <= 0) {
             return (liq, liq);
         }
 
         uint128 addedLiquidity = uint256(liquidityDelta).toUint128();
         liveLiquidityBeforeAdd = liq > addedLiquidity ? liq - addedLiquidity : 0;
         nextLiquidity = liq;
 
         // Unit harnesses may call touchPosition without pre-mutating PoolManager liquidity first.
         if (nextLiquidity == 0) nextLiquidity = liveLiquidityBeforeAdd + addedLiquidity;
     }
 
     /// @dev Rebase fee-growth checkpoints for fee lanes that still have unresolved residual burn base when adding
     ///      liquidity to an already-active position. This prevents newly added liquidity from inheriting the pre-add
     ///      fee window and double counting against already-banked historical residual backing.
     /// @param liquidityBeforeAdd Live position liquidity before this increase (pre-modify units); used to bank any
     ///        fee growth accrued on the surviving slice since `feeGrowthInsideLast` when settlement could not yet
     ///        materialise a burn (e.g. zero outflow window), so rebasing does not erase that window.
     function _rebaseResidualFeeGrowthOnActiveIncrease(
         VTSStorage storage s,
         IPoolManager poolManager,
         PoolId poolId,
         PositionId positionId,
         uint128 liquidityBeforeAdd
     ) internal {
+        // FIXME: When adding per-lane Q128 remainder for residual-backing, use the same carry-accumulator here
+        // and zero the remainder on lanes where feeGrowthInsideLast is advanced.
         PositionAccounting storage pa = s.positionAccounting[positionId];
         bool needFeeToken0 = pa.pendingResidualBurnBase.token1 > 0;
         bool needFeeToken1 = pa.pendingResidualBurnBase.token0 > 0;
         if (!needFeeToken0 && !needFeeToken1) return;
 
         Position storage pos = s.positions[positionId];
         (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
 
         if (needFeeToken0 && liquidityBeforeAdd > 0 && fg0 > pa.feeGrowthInsideLast.token0) {
             pa.pendingResidualFeeBacking
             .token0 += FullMath.mulDiv(
                 fg0 - pa.feeGrowthInsideLast.token0, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
         if (needFeeToken1 && liquidityBeforeAdd > 0 && fg1 > pa.feeGrowthInsideLast.token1) {
             pa.pendingResidualFeeBacking
             .token1 += FullMath.mulDiv(
                 fg1 - pa.feeGrowthInsideLast.token1, uint256(liquidityBeforeAdd), FixedPoint128.Q128
             );
         }
 
         if (needFeeToken0) pa.feeGrowthInsideLast.token0 = fg0;
         if (needFeeToken1) pa.feeGrowthInsideLast.token1 = fg1;
     }
 
     function _captureResidualFeeBackingOnFullDeactivation(
         VTSStorage storage s,
         IPoolManager poolManager,
         PositionId positionId,
         uint128 liq,
         int256 liquidityDelta
     ) internal {
         uint128 removedLiquidity = uint256(-liquidityDelta).toUint128();
         uint128 liveLiquidityBeforeRemove = (uint256(liq) + uint256(removedLiquidity)).toUint128();
         VTSFeeLinkedLib.captureResidualFeeBackingOnDeactivation(s, poolManager, positionId, liveLiquidityBeforeRemove);
     }
 
     /// @dev Compute settled excess over current commitment maxima after a decrease.
     ///      If live liquidity is zero, all settled is excess.
     function _computeSettledExcessAgainstCommitmentMax(PositionAccounting storage pa, uint128 currentLiq)
         internal
         view
         returns (uint256 excess0, uint256 excess1)
     {
         uint256 s0 = pa.settled.token0;
         uint256 s1 = pa.settled.token1;
         if (currentLiq == 0) {
             return (s0, s1);
         }
         TokenPairUint memory commitmentMaxima = pa.commitmentMax;
         excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
         excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
     }
 
     /// @dev Clamp settled balances downward by precomputed excess values.
     ///      For **non-seizure** MM decreases, callers pass the routed export from `VTSPositionMMOpsLib`:
     ///      `settleableDelta + queuedDelta` (vault-immediate plus shortfall-backed queue). For **seizure** MM decreases,
     ///      callers pass the seizure split export per leg: `min(excessSettled, settleableVaultLeg + burn)` where
     ///      `burn = min(principal, excessSettled)` — not `settleable + full queued principal`, so guarantor-queued
     ///      principal does not over-remove live `pa.settled` (SETTLE-03). Any remainder that could not be routed stays
     ///      in `pa.settled` until serviceable; only the vault-immediate slice is mirrored on `OwnerCurrencyDelta`.
     function _applySettlementClampFromExcess(
         VTSStorage storage s,
         PositionId positionId,
         uint256 excess0,
         uint256 excess1
     ) internal {
         if (excess0 > 0) {
             _sUpdateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
         }
         if (excess1 > 0) {
             _sUpdateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
         }
     }
 
     /// @dev Apply the shared liquidity mirror transition logic used by touch/reconcile.
     function _applyLiquidityMirrorTransition(
         VTSStorage storage s,
         PositionId positionId,
         PositionAccounting storage pa,
         Position storage posStorage,
         uint256 initialLiquidity,
         uint128 nextLiquidity
     ) internal {
         posStorage.liquidity = nextLiquidity;
         if (initialLiquidity != uint256(nextLiquidity)) {
             // Remainder is defined for a fixed liquidity denominator; reset on liquidity changes.
             pa.feeBurnGrowthRemainder.token0 = 0;
             pa.feeBurnGrowthRemainder.token1 = 0;
         }
         // Full deactivation: reset the entire commitment-deficit snapshot (amounts, age, severity).
         // Issued commitment is zero once liquidity is fully unwound, so there is nothing left to be insolvent for.
         // Clearing token amounts avoids stale `commitmentDeficit` with `commitmentDeficitSince == 0` after a prior
         // partial reset, which would otherwise block age-gated deficit bypass in `CheckpointLibrary.isSeizable`.
         // Non-seizure MM liquidity changes remain blocked while deficit is non-zero (`CommitmentDeficitBlocksLiquidityChange`);
         // this reset is the semantic cleanup once deactivation is actually reached (including non-MM and seizure paths).
         if (initialLiquidity > 0 && nextLiquidity == 0) {
             pa.commitmentDeficit.set(0, 0);
             pa.commitmentDeficit.set(1, 0);
             pa.commitmentDeficitSince.token0 = 0;
             pa.commitmentDeficitSince.token1 = 0;
             pa.commitmentDeficitBps = 0;
         }
         _updateStatus(s, positionId, posStorage, initialLiquidity, nextLiquidity);
     }
 
     // --------------------------------------------------
     // RFS (Required for Settlement) Functions (from VTSSettleLib)
     // --------------------------------------------------
 
     /// @notice View helper for computing RFS state and delta for a position
     /// @param s The central VTS storage
     /// @param positionId The position id
     /// @return rfsOpen Whether the RFS is open
     /// @return delta The settlement delta required/available
     function getRFS(VTSStorage storage s, PositionId positionId)
         public
         view
         returns (bool rfsOpen, BalanceDelta delta)
     {
         PositionAccounting storage pa = s.positionAccounting[positionId];
 
         // Get commitments and settled amounts in scoped block
         uint256 c0;
         uint256 c1;
         uint256 s0;
         uint256 s1;
         uint256 req0;
         uint256 req1;
         {
             c0 = pa.commitmentMax.token0;
             c1 = pa.commitmentMax.token1;
             s0 = pa.settled.token0;
             s1 = pa.settled.token1;
         }
 
         // Calculate base requirements
         {
             Position memory pos = s.positions[positionId];
             Pool memory pool = s.pools[pos.poolId];
             MarketVTSConfiguration memory cfg = pool.vtsConfig;
 
             uint256 d0 = pa.cumulativeDeficit.token0;
             uint256 d1 = pa.cumulativeDeficit.token1;
 
             (uint256 base0, uint256 base1) =
                 LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);
 
             // Cap deficits by commitment and gate by base
             uint256 defReq0 = d0 < c0 ? d0 : c0;
             uint256 defReq1 = d1 < c1 ? d1 : c1;
             req0 = base0 > defReq0 ? base0 : defReq0;
             req1 = base1 > defReq1 ? base1 : defReq1;
         }
 
         // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
         {
             uint256 cd0 = pa.commitmentDeficit.token0;
             uint256 cd1 = pa.commitmentDeficit.token1;
             if (cd0 > 0) {
                 uint256 add0 = req0 + cd0;
                 req0 = add0 > c0 ? c0 : add0;
             }
             if (cd1 > 0) {
                 uint256 add1 = req1 + cd1;
                 req1 = add1 > c1 ? c1 : add1;
             }
         }
 
         int128 amount0 = _rfsDeltaRaw(s0, req0);
         int128 amount1 = _rfsDeltaRaw(s1, req1);
 
         // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
         rfsOpen = (amount0 > 0) || (amount1 > 0);
         delta = toBalanceDelta(amount0, amount1);
     }
 
     /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
     /// @param settled Current settled amount
     /// @param need Required amount
     /// @return deltaRaw Signed delta in raw units
     function _rfsDeltaRaw(uint256 settled, uint256 need) internal pure returns (int128 deltaRaw) {
         if (need >= settled) {
             uint256 pos = need - settled; // rfs is the needed minus the already settled
             if (pos > INT128_MAX_U) return type(int128).max;
             return pos.toInt128();
         }
         uint256 neg = settled - need; // withdrawable
         if (neg > INT128_MAX_U) return type(int128).min;
         int128 magnitude = neg.toInt128();
         return -magnitude;
     }
 
     // --------------------------------------------------
     // Settlement Functions (from VTSSettleLib)
     // --------------------------------------------------
     // MM settlement (`executeMMSettleFromParams` / `onMMSettle`) lives in `VTSLifecycleLinkedLib`.
 }
```
