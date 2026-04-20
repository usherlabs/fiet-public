// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
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
import {VTSCommitLib} from "./VTSCommitLib.sol";
import {VTSPositionMMOpsLib} from "./VTSPositionMMOpsLib.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";

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

        // Track pool-wide cumulative deficit principal decrease when cumulativeDeficit is netted.
        // commitmentDeficit is an insolvency gate and is intentionally excluded from totalDeficitPrincipal.
        if (cumulativeDeficitCoverage > 0) {
            uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
            // Safely decrement (should not underflow if accounting is consistent)
            uint256 newPrincipal =
                cumulativeDeficitCoverage > currentPrincipal ? 0 : currentPrincipal - cumulativeDeficitCoverage;
            paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
        }

        // Track pool-wide totalSettled aggregate
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
        // - cumulativeDeficitCoverage: decrements pool totalDeficitPrincipal
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
                paPool.totalDeficitPrincipal.token0 += deficitIncrease;
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
                paPool.totalDeficitPrincipal.token1 += deficitIncrease;
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

    /// @notice Settle both deficit and inflow growth for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    //#olympix-ignore-reentrancy
    function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
        _settlePositionDeficitGrowth(s, poolManager, positionId);
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
    }

    /**
     * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
     * @param s The central VTS storage
     * @param poolManager The pool manager contract
     * @param id The id of the position
     */
    function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
        _checkpointTickIndexedSnapshots(s, poolManager, id);
    }

    /// @notice Touch a position to update its state and handle MM-specific operations
    /// @dev Single entry point for position processing - handles registration, linking, fee processing,
    ///      delta accounting, LCC issuance/cancellation, and checkpoint marking
    /// @param s The VTS storage
    /// @param ctx The position context containing dependency references (poolManager, liquidityHub, etc.)
    /// @param p The touchPosition parameters (owner, poolKey, params, callerDelta, feesAccrued, hookData)
    /// @return result The touchPosition result (pos, id)
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

    /// @dev Isolates the existing-position branch of `touchPosition` in its own stack frame (avoids "stack too deep"
    ///      when composed with mirror transitions).
    function _touchExistingPositionPath(
        VTSStorage storage s,
        PositionContext memory ctx,
        PoolId poolId,
        TouchPositionParams calldata p,
        PositionId positionId,
        Position storage posStorage,
        uint256 initialLiquidity,
        uint128 liq,
        TouchPositionHookData memory hookData
    ) private returns (BalanceDelta requiredSettlementDelta) {
        // EXISTING POSITION (active or previously inactive)

        // Validate no mismatch if commit ID present.
        if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
            revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
        }

        // Insolvency freeze: do not allow non-seizure MM liquidity changes while commitment deficit persists.
        // Settlement, checkpoint(withCommitment), and seizure paths remain the intended cure/formalise surfaces.
        if (hookData.isMMOperation && !hookData.isSeizing && p.params.liquidityDelta != 0) {
            PositionAccounting storage paGuard = s.positionAccounting[positionId];
            if (paGuard.commitmentDeficit.token0 > 0 || paGuard.commitmentDeficit.token1 > 0) {
                revert Errors.CommitmentDeficitBlocksLiquidityChange(positionId);
            }
        }

        if (p.params.liquidityDelta < 0) {
            // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
            if (!posStorage.isActive) revert Errors.NotActive(positionId);
            requiredSettlementDelta = _touchExistingDecrease(s, positionId, p.params, liq, hookData);
            // Mirror using live PoolManager liquidity post-modify for both paused and unpaused removes.
            PositionAccounting storage paDec = s.positionAccounting[positionId];
            _applyLiquidityMirrorTransition(s, positionId, paDec, posStorage, initialLiquidity, liq);
        } else {
            (uint128 liveLiquidityBeforeAdd, uint128 nextLiquidity) =
                _deriveIncreaseTransitionLiquidity(liq, p.params.liquidityDelta);
            if (p.params.liquidityDelta > 0) {
                // Allow re-activating a previously inactive position by adding liquidity.
                // Logically required to build on value routing while collecting fees on inactive positions.
                // Rebase tick-indexed snapshots first so the zero-liquidity interval is not charged/credited to
                // the newly reactivated liquidity.
                if (liveLiquidityBeforeAdd == 0) {
                    _checkpointTickIndexedSnapshots(s, ctx.poolManager, positionId);
                }
                requiredSettlementDelta =
                    _touchExistingIncrease(s, poolId, positionId, p.params, nextLiquidity, hookData);
            } else {
                // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                // Refresh commitment maxima from live liquidity (e.g. mirror desync or post-migration).
                _trackCommitment(s, positionId, liq);
                requiredSettlementDelta = BalanceDelta.wrap(0);
            }
            PositionAccounting storage paRem = s.positionAccounting[positionId];
            _applyLiquidityMirrorTransition(
                s, positionId, paRem, posStorage, uint256(liveLiquidityBeforeAdd), nextLiquidity
            );
        }
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
            requiredSettlementDelta =
                _touchExistingPositionPath(s, ctx, poolId, p, result.id, posStorage, initialLiquidity, liq, hookData);
        }

        if (isNewPosition) {
            _updateStatus(s, result.id, posStorage, initialLiquidity, liq);
        }

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
