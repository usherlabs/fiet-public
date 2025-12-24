// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
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
import {console} from "forge-std/console.sol";
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
    TouchPositionResult,
    SettleParams,
    SettleResult
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
import {VTSFeeLinkedLib, VTSFeeLib} from "./VTSFeeLib.sol";
import {DynamicCurrencyDelta} from "./DynamicCurrencyDelta.sol";
import {VTSCommitLib} from "./VTSCommitLib.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";
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

    // ============ INTERNAL STRUCTS ============

    /// @dev Internal struct to reduce stack depth in _handleLiquidityIncrease
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
        uint8 growthType;
    }

    // Maximum positive magnitude representable in int128
    uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;

    // --------------------------------------------------
    // Commitment Tracking
    // --------------------------------------------------

    /// @notice Tracks the maximum potential commitment for both tokens in a position
    /// @dev Tracks per-position maxima only (no commit-level aggregation)
    /// @param s The central VTS storage
    /// @param positionId The ascribed id of the position
    /// @param params The parameters of the transaction
    function _trackCommitment(VTSStorage storage s, PositionId positionId, ModifyLiquidityParams calldata params)
        internal
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Current tracked maxima for this position
        uint256 currentC0 = pa.commitmentMax.token0;
        uint256 currentC1 = pa.commitmentMax.token1;

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            // Cast int256 -> uint256 -> uint128 to preserve full uint128 range (not limited by int128 max)
            uint128 liquidityAdded = uint256(params.liquidityDelta).toUint128();
            (uint256 addC0, uint256 addC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            pa.commitmentMax.token0 = currentC0 + addC0;
            pa.commitmentMax.token1 = currentC1 + addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = uint256(-params.liquidityDelta).toUint128();
            (uint256 subC0, uint256 subC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            pa.commitmentMax.token0 = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            pa.commitmentMax.token1 = currentC1 > subC1 ? (currentC1 - subC1) : 0;
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    // --------------------------------------------------
    // Settlement Updates
    // --------------------------------------------------

    /// @notice Updates pool accounting for settlement changes
    /// @dev Extracted to reduce stack depth in _updateSettlement
    /// @param s The central VTS storage
    /// @param id The position id
    /// @param tokenIndex The token index (0 or 1)
    /// @param cur The previous settled amount
    /// @param next The new settled amount
    /// @param deficitCoverage The amount of deficit that was covered
    /// @return applied The total amount applied (deficit coverage + settled change)
    function _updatePoolAccounting(
        VTSStorage storage s,
        PositionId id,
        uint8 tokenIndex,
        uint256 cur,
        uint256 next,
        uint256 deficitCoverage
    ) private returns (int256 applied) {
        Position memory pos = s.positions[id];
        PoolAccounting storage paPool = s.poolAccounting[pos.poolId];

        int256 settledDelta = next.toInt256() - cur.toInt256();

        // DICE: Track pool-wide deficit principal decrease when deficits are netted
        // deficitCoverage tracks amount of cumulativeDeficit that was netted (excludes commitmentDeficit)
        // We only track cumulativeDeficit netting here; commitmentDeficit is a separate insolvency gate
        if (deficitCoverage > 0) {
            uint256 currentPrincipal = paPool.totalDeficitPrincipal.get(tokenIndex);
            // Safely decrement (should not underflow if accounting is consistent)
            uint256 newPrincipal = deficitCoverage > currentPrincipal ? 0 : currentPrincipal - deficitCoverage;
            paPool.totalDeficitPrincipal.set(tokenIndex, newPrincipal);
        }

        // CISE: Track pool-wide totalSettled aggregate
        {
            uint256 currentTotalSettled = paPool.totalSettled.get(tokenIndex);
            bool wasZero = currentTotalSettled == 0;

            if (settledDelta >= 0) {
                paPool.totalSettled.set(tokenIndex, currentTotalSettled + uint256(settledDelta));
            } else {
                uint256 decSettled = uint256(-settledDelta);
                paPool.totalSettled
                    .set(tokenIndex, decSettled > currentTotalSettled ? 0 : (currentTotalSettled - decSettled));
            }

            // CISE: Flush residual if totalSettled transitions from 0 to >0
            uint256 newTotalSettled = paPool.totalSettled.get(tokenIndex);
            if (wasZero && newTotalSettled > 0) {
                _flushCISEResidualIfNeeded(s, pos.poolId, tokenIndex);
            }
        }

        // Return total consumed: deficit coverage + settled change
        // Deposits (positive delta to _updateSettlement): returns positive value (deficitCoverage + settledDelta, both ≥ 0)
        // Withdrawals (negative delta to _updateSettlement): returns negative value (0 + negative settledDelta)
        applied = int256(deficitCoverage) + settledDelta;
    }

    /// @notice Updates the settlement amount by a delta which could be positive or negative
    /// @dev Nets against cumulative deficit, then derived commit deficit, then applies to settled
    /// @param s The central VTS storage
    /// @param id The position id
    /// @param tokenIndex The token index (0 or 1)
    /// @param delta The delta of the settlement
    /// @return applied The total amount applied (deficit coverage + settled increase)
    function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
        internal
        returns (int256 applied)
    {
        if (delta == 0) return 0;

        PositionAccounting storage pa = s.positionAccounting[id];

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
        uint256 deficitCoverage = 0; // Track total amount used for deficit netting

        if (delta > 0) {
            // Auto-net any lingering deficit first
            if (cumulativeDef > 0) {
                uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                if (cover > 0) {
                    cumulativeDef -= cover;
                    delta -= int256(cover);
                    deficitCoverage += cover;
                }
            }

            // Net against position-level commitment deficit in scoped block
            {
                uint256 cd = pa.commitmentDeficit.get(tokenIndex);
                if (delta > 0 && cd > 0) {
                    uint256 coverCd = uint256(delta) > cd ? cd : uint256(delta);
                    if (coverCd > 0) {
                        pa.commitmentDeficit.set(tokenIndex, cd - coverCd);
                        delta -= int256(coverCd);
                        deficitCoverage += coverCd;
                    }
                }
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

        // Update pool accounting via helper function
        applied = _updatePoolAccounting(s, id, tokenIndex, cur, next, deficitCoverage);
    }

    // --------------------------------------------------
    // DICE (Deficit-Indexed Coverage Exercise) Helpers
    // --------------------------------------------------

    /// @notice Flush any pending deficit-indexed coverage residual into the DICE index
    /// @dev Called when totalDeficitPrincipal increases from 0 to >0.
    ///      Residual is socialised across current deficit holders without epoch gating.
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    function _flushCoverageResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 residual = paPool.coverageResidualDICE.get(tokenIndex);
        uint256 principal = paPool.totalDeficitPrincipal.get(tokenIndex);

        // Is there a first-movers disadvantage?
        // With checkpoints incentivised via seizure, this should clear, but if NOT, then onMMSettle dis-incentivise the first-movers.
        // However, this also incentivises MMs to checkpoint other MMs positions...
        // This uses competition to close the economic lag between tick-index and position growth accounting.

        if (residual > 0 && principal > 0) {
            uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, principal);
            uint256 currentIndex = paPool.coveragePerDeficitIndexX128.get(tokenIndex);
            paPool.coveragePerDeficitIndexX128.set(tokenIndex, currentIndex + deltaIndex);
            paPool.coverageResidualDICE.set(tokenIndex, 0);
        }
    }

    // --------------------------------------------------
    // CISE (Coverage-Indexed Settled Exposure) Helpers
    // --------------------------------------------------

    /// @notice Flush any pending CISE residual into the coverage-per-settled index
    /// @dev Called when totalSettled increases from 0 to >0.
    ///      Residual is socialised across current settled liquidity holders.
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    function _flushCISEResidualIfNeeded(VTSStorage storage s, PoolId poolId, uint8 tokenIndex) internal {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 residual = paPool.coverageResidualCISE.get(tokenIndex);
        uint256 totalSettled = paPool.totalSettled.get(tokenIndex);

        if (residual > 0 && totalSettled > 0) {
            uint256 deltaIndex = FullMath.mulDiv(residual, FixedPoint128.Q128, totalSettled);
            uint256 currentIndex = paPool.coveragePerSettledIndexX128.get(tokenIndex);
            paPool.coveragePerSettledIndexX128.set(tokenIndex, currentIndex + deltaIndex);
            paPool.coverageResidualCISE.set(tokenIndex, 0);
        }
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
        if (p.growthType == 0) {
            lastSnap0 = pa.deficitGrowthInsideLast.token0;
            lastSnap1 = pa.deficitGrowthInsideLast.token1;
            pa.deficitGrowthInsideLast.token0 = inside0;
            pa.deficitGrowthInsideLast.token1 = inside1;
        } else if (p.growthType == 1) {
            lastSnap0 = pa.inflowGrowthInsideLast.token0;
            lastSnap1 = pa.inflowGrowthInsideLast.token1;
            pa.inflowGrowthInsideLast.token0 = inside0;
            pa.inflowGrowthInsideLast.token1 = inside1;
        } else {
            // Coverage usage growth (growthType == 2) removed - DICE uses deficit-indexed coverage
            revert("VTSPositionLib: Invalid growthType");
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
                    growthType: 0
                })
            );
        }

        // console.log("Deficit Growth: add0", add0);
        // console.log("Deficit Growth: add1", add1);
        // console.log("Deficit Growth: pa.settled.token0", pa.settled.token0);
        // console.log("Deficit Growth: pa.settled.token1", pa.settled.token1);

        // Process token0 deficit in scoped block
        if (add0 > 0) {
            // Track full attributed outflows for fee sharing normalisation window
            pa.cumulativeOutflows.token0 += add0;

            // Consume settled coverage first, then accrue shortfall to deficit
            uint256 s0 = pa.settled.token0;
            if (s0 >= add0) {
                _updateSettlement(s, positionId, 0, -int256(add0));
            } else {
                uint256 deficitIncrease = add0 - s0;
                pa.cumulativeDeficit.token0 += deficitIncrease;
                // DICE: Track pool-wide deficit principal increase
                paPool.totalDeficitPrincipal.token0 += deficitIncrease;
                // DICE: Flush any pending coverage residual now that principal exists
                _flushCoverageResidualIfNeeded(s, poolId, 0);
                _updateSettlement(s, positionId, 0, -int256(s0));
            }
        }

        // Process token1 deficit in scoped block
        if (add1 > 0) {
            pa.cumulativeOutflows.token1 += add1;
            uint256 s1 = pa.settled.token1;
            if (s1 >= add1) {
                _updateSettlement(s, positionId, 1, -int256(add1));
            } else {
                uint256 deficitIncrease = add1 - s1;
                pa.cumulativeDeficit.token1 += deficitIncrease;
                // DICE: Track pool-wide deficit principal increase
                paPool.totalDeficitPrincipal.token1 += deficitIncrease;
                // DICE: Flush any pending coverage residual now that principal exists
                _flushCoverageResidualIfNeeded(s, poolId, 1);
                _updateSettlement(s, positionId, 1, -int256(s1));
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
                growthType: 1
            })
        );

        // Token0: net against deficit first
        if (add0 > 0) {
            // Auto-net and apply via centralised updater
            _updateSettlement(s, positionId, 0, int256(add0));
        }

        // Token1: net against deficit first
        if (add1 > 0) {
            // Auto-net and apply via centralised updater
            _updateSettlement(s, positionId, 1, int256(add1));
        }
    }

    /// @notice Calculate fees and checkpoint snapshots for coverage burn
    /// @dev Extracted to reduce stack depth in _applyCoverageBurn
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param id The position ID
    /// @param p The pool ID
    /// @param tokenIndex The token index (0 or 1) - this is the deficit token
    /// @param feeTokenIndex The fee token index (opposite of deficit token)
    /// @param burnBase The burn base amount
    /// @param positionLiquidity The position liquidity
    /// @return fg The fee growth value
    /// @return feesBurn The calculated fees burn amount
    function _calculateFeesBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint8 feeTokenIndex,
        uint256 burnBase,
        uint128 positionLiquidity
    ) private returns (uint256 fg, uint256 feesBurn) {
        PositionAccounting storage pa = s.positionAccounting[id];
        uint256 fees;
        uint256 ofDelta;
        uint256 cf;
        uint256 snap;

        // Scoped block: Read fee growth and calculate fees
        {
            Position memory pos = s.positions[id];
            (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, p, pos.tickLower, pos.tickUpper);
            fg = feeTokenIndex == 0 ? fg0 : fg1;

            uint256 lastFeeGrowth = pa.feeGrowthInsideLast.get(feeTokenIndex);
            if (positionLiquidity > 0 && fg > lastFeeGrowth) {
                fees = FullMath.mulDiv(fg - lastFeeGrowth, uint256(positionLiquidity), FixedPoint128.Q128);
            }
        }

        // Read outflow window (deficit token) since last burn checkpoint.
        // IMPORTANT:
        // - `fees` are on `feeTokenIndex` (input/counterparty token)
        // - `burnBase` and `ofDelta` are on `tokenIndex` (deficit/output token)
        // We must NOT checkpoint the outflow window to `cf` for partial exercises; otherwise future
        // coverage exercises against the same historical outflows would see `ofDelta == 0` and burn nothing.
        //
        // Instead, we advance `outflowsAtFeeSnap` by the amount of outflows actually "consumed" by this burn
        // (i.e. exercised deficit, capped by the current `ofDelta`), and only when a non-zero burn occurs.
        {
            cf = pa.cumulativeOutflows.get(tokenIndex);
            snap = pa.outflowsAtFeeSnap.get(tokenIndex);
            ofDelta = cf >= snap ? (cf - snap) : 0; // outflows since last burn checkpoint.
        }

        // console.log("fees", fees);
        // console.log("ofDelta", ofDelta);

        if (fees == 0 || ofDelta == 0) {
            return (fg, 0);
        }

        // Scoped block: Calculate feesBurn
        {
            uint256 bps = s.pools[p].vtsConfig.coverageFeeShare;
            if (bps == 0) {
                return (fg, 0);
            }

            // Never allow the exercised share to exceed 100% of the current outflow window.
            uint256 effBurnBase = burnBase <= ofDelta ? burnBase : ofDelta;

            // feesBurn = fees * (burnBase / ofDelta) * bps/10000
            feesBurn = FullMath.mulDiv(fees, effBurnBase, ofDelta);
            feesBurn = FullMath.mulDiv(feesBurn, bps, LiquidityUtils.BPS_DENOMINATOR);
            if (feesBurn > fees) feesBurn = fees; // clamp to fees accrued

            // Only advance burn checkpoints if a non-zero burn is actually applied.
            // - Fee growth baseline is advanced later in `_applyCoverageBurn` via `fg + growthInc`.
            // - Outflow snapshot is advanced here by the exercised outflow share to support repeated exercises.
            if (feesBurn > 0) {
                // This says: “we have just exercised effBurnBase worth of the remaining outflow window, so reduce the remaining window by that amount”.
                uint256 newSnap = snap + effBurnBase;
                if (newSnap > cf) newSnap = cf;
                pa.outflowsAtFeeSnap.set(tokenIndex, newSnap);
            }
        }
    }

    /// @notice Apply coverage burn for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param id The position ID
    /// @param p The pool ID
    /// @param tokenIndex The token index (0 or 1) - this is the deficit token (output token)
    /// @param cov The coverage usage amount
    /// @param positionLiquidity The position liquidity
    /// @dev Fees accrue on the input token, not the deficit token. For a token0 deficit (from token1->token0 swap),
    ///      fees accrued on token1. For a token1 deficit (from token0->token1 swap), fees accrued on token0.
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

        // Calculate burnBase in scoped block
        uint256 burnBase;
        {
            uint256 d = pa.cumulativeDeficit.get(tokenIndex);
            uint256 settled = pa.settled.get(tokenIndex);
            if (cov == 0 || (d == 0 && settled == 0)) return;

            // Enforce invariant: cov <= d + settled, then burn only deficit portion
            uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
            if (cEff == 0 || d == 0) return;
            burnBase = cEff < d ? cEff : d; // min(coverage, deficit)
        }

        // Calculate feesBurn via helper function to reduce stack depth
        uint8 feeTokenIndex = tokenIndex == 0 ? 1 : 0; // Fee token is opposite of deficit token
        uint256 fg;
        uint256 feesBurn;
        bool shouldReturn;
        (fg, feesBurn) =
            _calculateFeesBurn(s, poolManager, id, p, tokenIndex, feeTokenIndex, burnBase, positionLiquidity);
        if (feesBurn == 0) return;

        // Advance fee growth baseline by burn amount to effectively "burn" the fees (fee token only)
        if (positionLiquidity > 0) {
            uint256 growthInc = FullMath.mulDiv(feesBurn, FixedPoint128.Q128, uint256(positionLiquidity));
            pa.feeGrowthInsideLast.set(feeTokenIndex, fg + growthInc);
        }

        // Update accounting in scoped block (for the fee token)
        {
            PoolAccounting storage paPool = s.poolAccounting[p];

            // CSI: Sync remaining shares BEFORE minting new shares (critical ordering)
            VTSFeeLib._syncFeesSharedRemainingForToken(pa, paPool, feeTokenIndex);

            paPool.protocolFeeAccrued.set(feeTokenIndex, paPool.protocolFeeAccrued.get(feeTokenIndex) + feesBurn);
            pa.feesShared.set(feeTokenIndex, pa.feesShared.get(feeTokenIndex) + feesBurn);

            pa.pendingFeeAdj.set(feeTokenIndex, pa.pendingFeeAdj.get(feeTokenIndex) + int256(feesBurn));
        }
    }

    /// @notice Settle coverage for a single token using DICE accounting
    /// @dev Extracted to reduce stack depth in _settleCoverageUsage
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param liq The position liquidity
    function _settleDICEForToken(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint128 liq
    ) private {
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        uint256 indexNow = paPool.coveragePerDeficitIndexX128.get(tokenIndex);
        uint256 indexLast = pa.coverageIndexLastX128.get(tokenIndex);

        // Checkpoint index (even if no coverage to apply)
        if (indexNow != indexLast) {
            pa.coverageIndexLastX128.set(tokenIndex, indexNow);
        }

        uint256 deltaIndex = indexNow - indexLast;
        if (deltaIndex > 0) {
            uint256 deficitPrincipal = pa.cumulativeDeficit.get(tokenIndex);
            uint256 cov = FullMath.mulDiv(deficitPrincipal, deltaIndex, FixedPoint128.Q128);
            // console.log("DICE: deficitPrincipal", deficitPrincipal);
            // console.log("DICE: deltaIndex", deltaIndex);
            // console.log("DICE: cov", cov);

            if (cov > 0) {
                _applyCoverageBurn(s, poolManager, positionId, poolId, tokenIndex, cov, liq);
            }
        }
    }

    /// @notice Realise and checkpoint CISE exposure for a single token
    /// @dev Computes exposure = settled * (indexNow - indexLast) / Q128 and accumulates it
    /// @dev Performed on _settleCoverageUsage to ensure accurate CISE exposure is realised and checkpointed
    /// @param pa The position accounting storage reference
    /// @param paPool The pool accounting storage reference
    /// @param tokenIndex The token index (0 or 1)
    function _settleCISEForToken(PositionAccounting storage pa, PoolAccounting storage paPool, uint8 tokenIndex)
        internal
    {
        uint256 indexNow = paPool.coveragePerSettledIndexX128.get(tokenIndex);
        uint256 indexLast = pa.ciseIndexLastX128.get(tokenIndex);

        // console.log("indexNow", indexNow);
        // console.log("indexLast", indexLast);

        // Always checkpoint index (even if no exposure to apply)
        if (indexNow != indexLast) {
            pa.ciseIndexLastX128.set(tokenIndex, indexNow);
        }

        uint256 deltaIndex = indexNow - indexLast;
        if (deltaIndex > 0) {
            uint256 settled = pa.settled.get(tokenIndex);
            uint256 exposure = FullMath.mulDiv(settled, deltaIndex, FixedPoint128.Q128);
            // console.log("settled", settled);
            // console.log("deltaIndex", deltaIndex);
            // console.log("exposure", exposure);
            if (exposure > 0) {
                pa.ciseExposureSinceLastMod.set(tokenIndex, pa.ciseExposureSinceLastMod.get(tokenIndex) + exposure);
                paPool.totalCISEExposureSinceLastMod
                    .set(tokenIndex, paPool.totalCISEExposureSinceLastMod.get(tokenIndex) + exposure);
            }
        }
    }

    /// @notice Settle coverage usage using DICE (deficit-indexed) accounting
    /// @dev Coverage is proportional to position's deficit principal, not tick-indexed liquidity.
    ///      This fixes the attribution bug where coverage was charged to whoever was in-range at
    ///      unwrap time, rather than positions that created the deficit during swaps.
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settleDeficitIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
        internal
    {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));

        // DICE: Compute coverage from deficit-indexed growth (not tick-indexed)
        _settleDICEForToken(s, poolManager, positionId, poolId, 0, liq);
        _settleDICEForToken(s, poolManager, positionId, poolId, 1, liq);
    }

    /// @notice Settle settled-indexed coverage usage
    /// @dev Coverage is proportional to position's settled principal, not tick-indexed liquidity.
    ///      This fixes the attribution bug where coverage was charged to whoever was in-range at
    ///      unwrap time, rather than positions that created the deficit during swaps.
    /// @dev That settled must be the settled balance that existed during the interval [indexLast, indexNow].
    ///      If _settleCISEForToken is called after _updateSettlement has changed pa.settled, risks applying historical deltaIndex against the new settled balance.
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settleSettledIndexedCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
        internal
    {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 0);
        _settleCISEForToken(s.positionAccounting[positionId], s.poolAccounting[poolId], 1);
    }

    /// @notice Settle both deficit, inflow, and coverage growth for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
        _settleSettledIndexedCoverageUsage(s, poolManager, positionId);

        _settlePositionDeficitGrowth(s, poolManager, positionId);
        _settlePositionInflowGrowth(s, poolManager, positionId);
        // Coverage burn must occur in the settle stage (before position modification) to preserve economic integrity:
        // - burnBase is computed from pre-modification deficit/settled state, preventing users from covering deficits
        //   first and then avoiding the burn in the same modifyLiquidity call
        // - This ensures coverage usage is charged against the state that actually incurred the coverage obligation,
        //   maintaining fairness and preventing gaming of the slash mechanism
        _settleDeficitIndexedCoverageUsage(s, poolManager, positionId);
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
                timeOfLastTransition: block.timestamp, isOpen: false, gracePeriodExtension0: 0, gracePeriodExtension1: 0
            })
        });
    }

    /// @notice Link a position to a commit
    /// @param s The VTS storage
    /// @param positionId The position id
    /// @param commitId The token id (commit id)
    function _linkPositionToCommit(VTSStorage storage s, PositionId positionId, uint256 commitId) internal {
        // validate there is an existing commit for the token id
        if (s.commits[commitId].expiresAt < block.timestamp) {
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
    }

    /**
     * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
     * @param s The central VTS storage
     * @param poolManager The pool manager contract
     * @param id The id of the position
     */
    function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
        Position memory pos = s.positions[id];
        PoolId p = pos.poolId;
        PositionAccounting storage pa = s.positionAccounting[id];
        (, int24 tickCurrent,,) = StateLibrary.getSlot0(poolManager, p);

        SnapshotParams memory sp =
            SnapshotParams({poolId: p, tickLower: pos.tickLower, tickUpper: pos.tickUpper, tickCurrent: tickCurrent});

        _initDeficitSnapshot(s, pa, sp);
        _initInflowSnapshot(s, pa, sp);
        _initFeeSnapshot(poolManager, pa, sp);
        _initCoverageSnapshot(s, pa, sp);
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
    /// @param hookData The raw hook data bytes
    /// @return data The decoded hook data struct
    function _decodeHookData(bytes calldata hookData) private pure returns (TouchPositionHookData memory data) {
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);
        data.isMMOperation = PositionModificationHookDataLib.isMMOperation(mmData);
        data.commitId = mmData.commitId;
        data.isSeizing = mmData.seizure.isSeizing;
    }

    /// @notice Handles new position initialization and returns required settlement delta
    function _touchNewPosition(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        address owner,
        ModifyLiquidityParams calldata params,
        PositionId positionId,
        TouchPositionHookData memory hookData
    ) private returns (BalanceDelta requiredSettlementDelta) {
        _registerPosition(s, owner, poolId, params);

        if (hookData.isMMOperation && hookData.commitId > 0) {
            _linkPositionToCommit(s, positionId, hookData.commitId);
        }

        _initPositionSnapshots(s, poolManager, positionId);
        _trackCommitment(s, positionId, params);

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
            _updateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0));
            _updateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1));
            requiredSettlementDelta = BalanceDelta.wrap(0);
        }
    }

    /// @notice Handles existing position decrease and returns required settlement delta
    function _touchExistingDecrease(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        ModifyLiquidityParams calldata params,
        uint128 currentLiq,
        TouchPositionHookData memory hookData
    ) private returns (BalanceDelta requiredSettlementDelta) {
        if (!hookData.isSeizing) {
            calcRFS(s, poolManager, positionId, true);
        }
        _trackCommitment(s, positionId, params);

        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 s0 = pa.settled.token0;
        uint256 s1 = pa.settled.token1;
        uint256 excess0;
        uint256 excess1;

        if (currentLiq == 0) {
            excess0 = s0;
            excess1 = s1;
        } else {
            TokenPairUint memory commitmentMaxima = pa.commitmentMax;
            excess0 = s0 > commitmentMaxima.token0 ? s0 - commitmentMaxima.token0 : 0;
            excess1 = s1 > commitmentMaxima.token1 ? s1 - commitmentMaxima.token1 : 0;
        }

        if (hookData.isMMOperation) {
            requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
        } else {
            if (excess0 > 0) {
                _updateSettlement(s, positionId, 0, -SafeCast.toInt256(excess0));
            }
            if (excess1 > 0) {
                _updateSettlement(s, positionId, 1, -SafeCast.toInt256(excess1));
            }
            requiredSettlementDelta = BalanceDelta.wrap(0);
        }
    }

    /// @notice Handles existing position increase and returns required settlement delta
    function _touchExistingIncrease(
        VTSStorage storage s,
        PoolId poolId,
        PositionId positionId,
        ModifyLiquidityParams calldata params,
        TouchPositionHookData memory hookData
    ) private returns (BalanceDelta requiredSettlementDelta) {
        _trackCommitment(s, positionId, params);

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
            _updateSettlement(s, positionId, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
            _updateSettlement(s, positionId, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
            requiredSettlementDelta = BalanceDelta.wrap(0);
        }
    }

    function touchPosition(VTSStorage storage s, PositionContext memory ctx, TouchPositionParams calldata p)
        external
        returns (TouchPositionResult memory result)
    {
        PoolId poolId = p.poolKey.toId();
        result.id = PositionLibrary.generateId(p.owner, p.params);
        Position storage posStorage = s.positions[result.id];
        uint256 initialLiquidity = posStorage.liquidity;
        uint128 liq = ctx.poolManager.getPositionLiquidity(poolId, PositionId.unwrap(result.id));

        TouchPositionHookData memory hookData = _decodeHookData(p.hookData);
        BalanceDelta requiredSettlementDelta;

        if (posStorage.owner == address(0)) {
            // NEW POSITION
            requiredSettlementDelta =
                _touchNewPosition(s, ctx.poolManager, poolId, p.owner, p.params, result.id, hookData);
        } else {
            // EXISTING POSITION (active or previously inactive)

            // Validate no mismatch if commit ID present.
            if (hookData.isMMOperation && hookData.commitId != posStorage.commitId) {
                revert Errors.InvariantViolated("Invalid operation: Commit ID mismatch");
            }

            if (p.params.liquidityDelta < 0) {
                // Disallow decreases on previously-inactive positions. (If liq == 0, Uniswap will revert anyway.)
                if (!posStorage.isActive) revert Errors.NotActive(result.id);
                requiredSettlementDelta = _touchExistingDecrease(s, ctx.poolManager, result.id, p.params, liq, hookData);
            } else if (p.params.liquidityDelta > 0) {
                // Allow re-activating a previously inactive position by adding liquidity.
                // Logically required to build on value routing while collecting fees on inactive positions.
                requiredSettlementDelta = _touchExistingIncrease(s, poolId, result.id, p.params, hookData);
            } else {
                // Allow a no-op when active (Uniswap v4 disallows this when initial liq == 0).
                // See https://github.com/Uniswap/v4-core/blob/36d790b1a3af38461453a13a6ff395290fbc11b2/src/libraries/Position.sol#L86
                requiredSettlementDelta = BalanceDelta.wrap(0);
            }

            // Update position liquidity
            int256 newLiquidity = SafeCast.toInt256(uint256(posStorage.liquidity)) + p.params.liquidityDelta;
            posStorage.liquidity = newLiquidity < 0 ? 0 : SafeCast.toUint128(uint256(newLiquidity));
        }

        // console.log("MM OPERATION:", hookData.isMMOperation);

        _updateActiveStatus(s, posStorage, initialLiquidity, liq);

        result.feeAdj = VTSFeeLinkedLib.afterTouchPosition(s, result.id);

        if (hookData.isMMOperation) {
            _processMMOperations(s, ctx, p, result, hookData.commitId, hookData.isSeizing, requiredSettlementDelta);
        }

        result.pos = posStorage;
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

    /// @notice Process MM-specific operations (LCC management, deltas, checkpoints)
    /// @dev Extracted to reduce stack pressure in touchPosition
    function _processMMOperations(
        VTSStorage storage s,
        PositionContext memory ctx,
        TouchPositionParams calldata p,
        TouchPositionResult memory result,
        uint256 mmCommitId,
        bool isSeizing,
        BalanceDelta requiredSettlementDelta
    ) internal {
        // CoreHook applies a feeAdj to the callerDelta. ie.  callerDelta = principalDelta - feesAccrued - feeAdj.
        // Treat feeAdj as part of fees for cancel/transfer purposes.
        // ? feeAdj bonus is negative, slash is positive. The result is higher fees for bonus, lower for slash.
        BalanceDelta accruedFeesAfterAdj = p.feesAccrued - result.feeAdj;

        // positionDelta(a0/a1) are the gross amounts returned by the PoolManager for position modification.
        // principal0/principal1 = a{0,1} - fees{0,1} reflect the true principal liquidity change
        // that maps to LCC cancellation. fees are trader-derived, wrapped LCC value and must remain wrapped.
        BalanceDelta principalDelta = p.callerDelta - accruedFeesAfterAdj;

        // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
        // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
        // This allows direct _take calls for LCC without a separate collectFees function.

        // Handle LCC issuance/cancellation based on liquidity direction
        if (p.params.liquidityDelta > 0) {
            // Adding liquidity: Issue LCCs
            _handleLiquidityIncrease(
                s,
                ctx,
                p.poolKey,
                p.params,
                LiquidityIncreaseParams({
                    owner: p.owner, commitId: mmCommitId, positionId: result.id, principalDelta: principalDelta
                })
            );
        } else if (p.params.liquidityDelta < 0) {
            // Re-decode hookData to get locker - scoped to free memory
            address queueRecipient;
            {
                PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
                queueRecipient = PositionModificationHookDataLib.getLocker(mmData, p.owner);
            }

            if (isSeizing) {
                // @note: For Seizures,
                // - LCCs are received directly by locker simiarly to fees.
                // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                // - For any excess, this can also be settled immediately via MM operations.

                // Only cancel excess settled received.
                _handleLiquidityDecrease(
                    ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                );
            } else {
                // Removing liquidity: Cancel LCCs without seizing.

                // @note We cannot cancel directly at this point in the flow,
                // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                _handleLiquidityDecrease(
                    ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                );
            }
        }

        if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
            // Account underlying currency settlement obligations to MMPositionManager
            // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
            // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
            DynamicCurrencyDelta.accountUnderlyingSettlementDelta(
                p.owner, requiredSettlementDelta, p.poolKey.currency0, p.poolKey.currency1
            );
        }

        // Mark RFS checkpoint
        (bool rfsOpen,) = getRFS(s, result.id);
        CheckpointLibrary.markCheckpoint(s, result.id, rfsOpen);
    }

    // --------------------------------------------------
    // LCC Issuance/Cancellation Helpers
    // --------------------------------------------------

    /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
    /// @param s The VTS storage
    /// @param ctx The position context
    /// @param poolKey The pool key
    /// @param params The modify liquidity params
    /// @param p The liquidity increase params (bundled for stack depth)
    function _handleLiquidityIncrease(
        VTSStorage storage s,
        PositionContext memory ctx,
        PoolKey calldata poolKey,
        ModifyLiquidityParams calldata params,
        LiquidityIncreaseParams memory p
    ) public {
        // Calculate amounts in scoped block
        uint256 amount0;
        uint256 amount1;
        {
            // Negative delta means LP deposited tokens
            amount0 =
                p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
            amount1 =
                p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
            if (amount0 == 0 && amount1 == 0) return;
        }

        // Validate commitment backing in scoped block
        {
            (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
            VTSCommitLib.validateLiquidityDelta(
                s,
                ctx.oracleHelper,
                p.commitId,
                p.positionId,
                VTSCommitLib.LiquidityDeltaParams({
                    currency0: poolKey.currency0,
                    currency1: poolKey.currency1,
                    sqrtPriceX96: sqrtPriceX96,
                    currentTick: currentTick,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: params.liquidityDelta
                }),
                true
            );
        }

        // Issue LCC tokens in scoped block
        {
            if (amount0 > 0) {
                ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
            }
            if (amount1 > 0) {
                ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
            }
        }
    }

    /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
    /// @param ctx The position context
    /// @param owner The position owner
    /// @param poolKey The pool key
    /// @param principalDelta The principal delta after fee adjustments
    /// @param requiredSettlementDelta The required settlement delta from touchPosition
    /// @param queueRecipient The recipient for settlement queue (locker or owner)
    function _handleLiquidityDecrease(
        PositionContext memory ctx,
        address owner,
        PoolKey calldata poolKey,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta,
        address queueRecipient
    ) internal {
        if (LiquidityUtils.isZeroDelta(principalDelta)) return;

        // Calculate queued delta in scoped block
        BalanceDelta queuedDelta;
        {
            BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
            // 1. Determine what amount of available liquidity can be used to cover settlement.
            BalanceDelta rawQueued = requiredSettlementDelta - availableDelta;
            // 2. Clamp queuedDelta to non-negative values (negative values become 0)
            int128 qd0 = rawQueued.amount0() > 0 ? rawQueued.amount0() : int128(0);
            int128 qd1 = rawQueued.amount1() > 0 ? rawQueued.amount1() : int128(0);
            queuedDelta = toBalanceDelta(qd0, qd1);
        }

        // 3. Queue settlements via cancelWithQueue
        // Burns LCCs from MMPM (ctx.mmpmAddress) and queues shortfall for queueRecipient (locker or MMPM)
        // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
        // Process token0 cancellation
        {
            uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
            if (principalAmount0 > 0) {
                ctx.liquidityHub
                    .planCancelWithQueue(
                        Currency.unwrap(poolKey.currency0),
                        address(ctx.poolManager),
                        owner,
                        principalAmount0,
                        LiquidityUtils.safeInt128ToUint256(queuedDelta.amount0()),
                        queueRecipient
                    );
            }
        }

        // Process token1 cancellation
        {
            uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
            if (principalAmount1 > 0) {
                ctx.liquidityHub
                    .planCancelWithQueue(
                        Currency.unwrap(poolKey.currency1),
                        address(ctx.poolManager),
                        owner,
                        principalAmount1,
                        LiquidityUtils.safeInt128ToUint256(queuedDelta.amount1()),
                        queueRecipient
                    );
            }
        }

        // 4. Queued shortfall is tracked in LiquidityHub as owed to queueRecipient
        // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
        // If recipient is MMPM, the balance is synced to the locker's delta.
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

    /// @notice Core settlement entrypoint for MM-managed positions
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param p The MM settle parameters (vault, positionId, currencies, delta, isSeizing)
    /// @return result The MM settle result (settlementDelta, rfsOpen, seizedLiquidityUnits)
    function onMMSettle(VTSStorage storage s, IPoolManager poolManager, SettleParams calldata p)
        external
        returns (SettleResult memory result)
    {
        Position memory pos = s.positions[p.positionId];
        PoolId poolId = pos.poolId;

        // Validate position exists
        address owner = pos.owner;
        if (owner == address(0)) {
            revert("VTSPositionLib: Invalid position");
        }

        // Read position required settlement delta from currencyDelta (set by _touchPosition via DynamicCurrencyDelta)
        BalanceDelta positionRequiredSettlementDelta =
            DynamicCurrencyDelta.getUnderlyingDeltaPair(owner, p.lccCurrency0, p.lccCurrency1);

        // During withdrawals, delta is positive as per caller context. During deposits, delta is negative.
        // However, _updateSettlement accepts the inverse as a delta of the settled amount.
        // Ie. positive increases, and negative decreases the metric.
        int256 amount0 = int256(p.delta.amount0());
        int256 amount1 = int256(p.delta.amount1());

        // Settle growths and get RFS state
        BalanceDelta rfsDelta;
        settlePositionGrowths(s, poolManager, p.positionId);
        (result.rfsOpen, rfsDelta) = getRFS(s, p.positionId);

        // Handle settlement based on position state
        if (!pos.isActive) {
            // Inactive: unrestricted deposits/settlements
            (amount0, amount1) = _settleInactive(s, p.positionId, amount0, amount1);
        } else if (p.isSeizing) {
            // Seizing: clamp deposits/withdrawals by RFS and position requirements
            (amount0, amount1) =
                _settleSeizing(s, p.positionId, amount0, amount1, rfsDelta, positionRequiredSettlementDelta);
        } else {
            // Active and not seizing: validate and apply RFS clamps
            (amount0, amount1) = _settleActive(s, p.positionId, amount0, amount1, rfsDelta, result.rfsOpen);
        }

        // Clamps within _updateSettlement may modify the return delta. Flip the signs on amount0 and amount1 to match caller-context delta.
        result.settlementDelta =
            LiquidityUtils.negateBalanceDelta(toBalanceDelta(amount0.toInt128(), amount1.toInt128()));

        // ========================================
        // PHASE 2: Clamp by available market liquidity & retroactive adjustment
        // ========================================

        // Only need to clamp withdrawals (positive settlementDelta)
        if (result.settlementDelta.amount0() > 0 || result.settlementDelta.amount1() > 0) {
            // Get available liquidity from vault
            // This does not include deposits during seizing, as liquidity has not tranferred yet.
            BalanceDelta availableDelta = p.vault.dryModifyLiquidities(result.settlementDelta);

            // Scoped block for shortfall calculation
            {
                // Calculate shortfall for withdrawals only
                int128 shortfall0 = result.settlementDelta.amount0() - availableDelta.amount0();
                int128 shortfall1 = result.settlementDelta.amount1() - availableDelta.amount1();

                // Retroactively adjust _updateSettlement for any shortfall
                // Shortfall is positive when we over-settled. We need to add back (positive delta to _updateSettlement)
                // because we previously called _updateSettlement with negative delta for withdrawals
                if (shortfall0 > 0) {
                    _updateSettlement(s, p.positionId, 0, int256(shortfall0));
                }
                if (shortfall1 > 0) {
                    _updateSettlement(s, p.positionId, 1, int256(shortfall1));
                }
            }

            // Update settlementDelta to reflect actual available amounts
            result.settlementDelta = availableDelta;
        }

        // ========================================
        // PHASE 3: Seizure calculation and Fee Management
        // ========================================

        // Calculate seized liquidity units when seizing
        if (p.isSeizing) {
            result.seizedLiquidityUnits = _calcSeizure(s, poolManager, p.positionId, result.settlementDelta);
        } else {
            result.seizedLiquidityUnits = 0;
        }

        // ========================================
        // PHASE 4: Clear currency deltas based on settlement
        // ========================================

        // Scoped block for delta clearance to free temporaries early
        {
            Currency underlyingCurrency0 = DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0);
            Currency underlyingCurrency1 = DynamicCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1);

            // Read current owner deltas (these represent what was owed/credited from position modifications)
            int128 ownerDelta0 = positionRequiredSettlementDelta.amount0();
            int128 ownerDelta1 = positionRequiredSettlementDelta.amount1();

            // settlementDelta represents actual amounts being moved:
            // - negative = deposit (caller owes protocol)
            // - positive = withdrawal (protocol owes caller)
            int128 settleAmount0 = result.settlementDelta.amount0();
            int128 settleAmount1 = result.settlementDelta.amount1();

            // Clear deltas based on settlement conditions
            int128 deltaClear0 = _calcDeltaClearance(ownerDelta0, settleAmount0);
            int128 deltaClear1 = _calcDeltaClearance(ownerDelta1, settleAmount1);

            // Apply delta clearance (negative values reduce positive deltas, positive values reduce negative deltas)
            if (deltaClear0 != 0) {
                DynamicCurrencyDelta.accountDelta(underlyingCurrency0, deltaClear0, owner);
            }
            if (deltaClear1 != 0) {
                DynamicCurrencyDelta.accountDelta(underlyingCurrency1, deltaClear1, owner);
            }
        }

        // ========================================
        // PHASE 5: Touch ups
        // ========================================

        // Mark RFS checkpoint for the position
        CheckpointLibrary.markCheckpoint(s, p.positionId, result.rfsOpen);
    }

    /// @notice Handle settlement for inactive positions (unrestricted)
    /// @dev Extracted to reduce stack pressure in onMMSettle
    function _settleInactive(VTSStorage storage s, PositionId positionId, int256 amount0, int256 amount1)
        internal
        returns (int256, int256)
    {
        if (amount0 != 0) {
            amount0 = _updateSettlement(s, positionId, 0, -amount0);
        }
        if (amount1 != 0) {
            amount1 = _updateSettlement(s, positionId, 1, -amount1);
        }
        return (amount0, amount1);
    }

    /// @notice Handle settlement during seizure with RFS clamping
    /// @dev Extracted to reduce stack pressure in onMMSettle
    function _settleSeizing(
        VTSStorage storage s,
        PositionId positionId,
        int256 amount0,
        int256 amount1,
        BalanceDelta rfsDelta,
        BalanceDelta positionRequiredSettlementDelta
    ) internal returns (int256, int256) {
        // Seizing: clamp deposits (negative settlementDelta) by positive rfsDelta
        int128 rfs0 = rfsDelta.amount0();
        int128 rfs1 = rfsDelta.amount1();

        // Read the required settlement delta from position modifications
        // Signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
        int128 posRequiredSettlement0 = positionRequiredSettlementDelta.amount0();
        int128 posRequiredSettlement1 = positionRequiredSettlementDelta.amount1();

        if (amount0 < 0) {
            // deposit: clamp by positive rfsDelta
            // If rfs0 > 0, we can deposit up to rfs0 (clamp amount0 to -rfs0 minimum)
            // If rfs0 <= 0, no RFS requirement, so don't deposit (clamp to 0)
            if (rfs0 > 0) {
                int128 maxDeposit0 = -rfs0; // negative because deposits are negative
                if (amount0 < maxDeposit0) {
                    amount0 = maxDeposit0;
                }
                // Return value is total (deficit coverage + settled increase)
                amount0 = _updateSettlement(s, positionId, 0, -amount0);
            } else {
                // No RFS requirement for token0, don't deposit
                amount0 = 0;
            }
        } else if (amount0 > 0) {
            // withdrawal: clamp by positionRequiredSettlementDelta
            // If positionRequiredSettlementDelta > 0, clamp to min(amount0, positionRequiredSettlementDelta)
            // If positionRequiredSettlementDelta <= 0, clamp to 0
            if (posRequiredSettlement0 > 0) {
                if (amount0 > posRequiredSettlement0) {
                    amount0 = posRequiredSettlement0;
                }
            } else {
                amount0 = 0;
            }

            amount0 = _updateSettlement(s, positionId, 0, -amount0);
        }

        if (amount1 < 0) {
            // deposit: clamp by positive rfsDelta
            // If rfs1 > 0, we can deposit up to rfs1 (clamp amount1 to -rfs1 minimum)
            // If rfs1 <= 0, no RFS requirement, so don't deposit (set to 0)
            if (rfs1 > 0) {
                int128 maxDeposit1 = -rfs1; // negative because deposits are negative
                if (amount1 < maxDeposit1) {
                    amount1 = maxDeposit1;
                }
                // Return value is total (deficit coverage + settled increase)
                amount1 = _updateSettlement(s, positionId, 1, -amount1);
            } else {
                // No RFS requirement for token1, clamp deposit to 0
                amount1 = 0;
            }
        } else if (amount1 > 0) {
            // withdrawal: clamp by positionRequiredSettlementDelta
            // If positionRequiredSettlementDelta > 0, clamp to min(amount1, positionRequiredSettlementDelta)
            // If positionRequiredSettlementDelta <= 0, clamp to 0
            if (posRequiredSettlement1 > 0) {
                if (amount1 > posRequiredSettlement1) {
                    amount1 = posRequiredSettlement1;
                }
            } else {
                amount1 = 0;
            }

            amount1 = _updateSettlement(s, positionId, 1, -amount1);
        }

        return (amount0, amount1);
    }

    /// @notice Handle settlement for active positions (with RFS validation)
    /// @dev Extracted to reduce stack pressure in onMMSettle
    function _settleActive(
        VTSStorage storage s,
        PositionId positionId,
        int256 amount0,
        int256 amount1,
        BalanceDelta rfsDelta,
        bool rfsOpen
    ) internal returns (int256, int256) {
        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Active and not seizing: validate and apply RFS clamps
        if (pa.commitmentMax.token0 == 0 || pa.commitmentMax.token1 == 0) {
            revert("VTSPositionLib: Invalid position");
        }
        // For withdrawals, validate RFS closure
        bool isWithdrawal = amount0 > 0 || amount1 > 0;
        if (isWithdrawal && rfsOpen) {
            revert("VTSPositionLib: RFS open");
        }

        // Apply RFS clamps for withdrawals
        if (amount0 > 0) {
            // withdraw
            // Clamp by rfsDelta: if rfsDelta < 0, then -rfsDelta is withdrawable
            int128 rfs0 = rfsDelta.amount0();
            if (rfs0 < 0) {
                uint256 withdrawable0 = LiquidityUtils.safeInt128ToUint256(rfs0);
                if (uint256(amount0) > withdrawable0) {
                    amount0 = withdrawable0.toInt256();
                }
                amount0 = _updateSettlement(s, positionId, 0, -amount0);
            } else {
                // rfsDelta >= 0 means cannot withdraw
                amount0 = 0;
            }
        } else if (amount0 < 0) {
            // deposit
            amount0 = _updateSettlement(s, positionId, 0, -amount0);
        }
        if (amount1 > 0) {
            // withdraw
            // Clamp by rfsDelta: if rfsDelta < 0, then -rfsDelta is withdrawable
            int128 rfs1 = rfsDelta.amount1();
            if (rfs1 < 0) {
                uint256 withdrawable1 = LiquidityUtils.safeInt128ToUint256(rfs1);
                if (uint256(amount1) > withdrawable1) {
                    amount1 = withdrawable1.toInt256();
                }
                amount1 = _updateSettlement(s, positionId, 1, -amount1);
            } else {
                // rfsDelta >= 0 means cannot withdraw
                amount1 = 0;
            }
        } else if (amount1 < 0) {
            // deposit
            amount1 = _updateSettlement(s, positionId, 1, -amount1);
        }

        return (amount0, amount1);
    }

    /// @notice Calculates the delta clearance amount based on settlement conditions
    /// @param delta The current currency delta for the owner (negative = owes, positive = owed)
    /// @param amount The settlement amount (negative = deposit, positive = withdrawal)
    /// @return clearance The amount to clear from delta (negative reduces positive delta, positive reduces negative delta)
    function _calcDeltaClearance(int128 delta, int128 amount) internal pure returns (int128 clearance) {
        /**
         * delta < 0 && amount < 0: eg. DECREASE_LIQUIDITY, caller owes protocol
         *   -- clamp currency delta net by the amount deposited.
         *   -- Clear: use min magnitude (max of two negatives)
         *
         * delta < 0 && amount > 0: Not allowed. Protocol requires liquidity, caller cannot withdraw.
         *   -- Should be prevented by earlier clamping. No clearance.
         *
         * delta > 0 && amount < 0: NO accounting. Just settling in (deposit above what's owed).
         *   -- Deposit doesn't clear positive delta (protocol still owes caller).
         *
         * delta > 0 && amount > 0: Either net delta to 0, or reduce by withdrawal amount.
         *   -- Clear: use min(delta, amount)
         *
         * delta == 0 && amount < 0: NO accounting. Just depositing, clamped by commitmentMaxima.
         * delta == 0 && amount > 0: NO accounting. Just withdrawing, clamped by rfsDelta.
         */

        if (delta < 0 && amount < 0) {
            // Both negative: clear by min magnitude (max of two negatives gives smaller absolute value)
            // We want to reduce the negative delta by the amount deposited
            // eg. delta = -100, amount = -50 → clear +50 (reduce debt by 50)
            // eg. delta = -50, amount = -100 → clear +50 (reduce debt by 50, can only clear up to debt)
            int128 minMagnitude = delta > amount ? delta : amount; // max of negatives = smaller absolute
            clearance = -minMagnitude; // positive clearance reduces negative delta
        } else if (delta > 0 && amount > 0) {
            // Both positive: clear by min of the two
            // eg. delta = 100, amount = 50 → clear -50 (reduce credit by 50)
            // eg. delta = 50, amount = 100 → clear -50 (reduce credit by 50, can only clear up to credit)
            int128 minValue = delta < amount ? delta : amount;
            clearance = -minValue; // negative clearance reduces positive delta
        }
        // All other cases: clearance = 0 (no accounting)
    }

    /// @notice Calculates liquidity units to seize for a given position and settlement delta
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position id
    /// @param settlementDelta The settlement delta applied during seizure
    /// @return seizedLiquidityUnits The liquidity units to seize
    function _calcSeizure(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        BalanceDelta settlementDelta
    ) internal returns (uint256 seizedLiquidityUnits) {
        // Settle growths first
        settlePositionGrowths(s, poolManager, positionId);

        BalanceDelta rfsDelta;
        {
            bool rfsOpen;
            (rfsOpen, rfsDelta) = getRFS(s, positionId);
            if (!rfsOpen) {
                // if RFS is not open, return 0 as nothing can be seized
                return 0;
            }
        }

        // Calculate base values in scoped block
        uint256 c0;
        uint256 c1;
        uint256 r0;
        uint256 r1;
        uint256 s0;
        uint256 s1;
        {
            PositionAccounting storage pa = s.positionAccounting[positionId];
            c0 = pa.commitmentMax.token0;
            c1 = pa.commitmentMax.token1;

            // Only consider tokens with positive RFS deltas (needs settlement)
            // Negative RFS deltas indicate excess, not requirements, so they don't contribute to seizure
            int128 rfs0 = rfsDelta.amount0();
            int128 rfs1 = rfsDelta.amount1();
            r0 = rfs0 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs0) : 0;
            r1 = rfs1 > 0 ? LiquidityUtils.safeInt128ToUint256(rfs1) : 0;

            // settlementDelta: negative = deposit, positive = withdrawal
            // For seizure calculation, we only care about deposits (negative), so take absolute value
            s0 = settlementDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0()) : 0;
            s1 = settlementDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1()) : 0;
        }

        // Calculate exposure and seized units in scoped block
        Position memory pos = s.positions[positionId];
        Pool memory pool = s.pools[pos.poolId];
        MarketVTSConfiguration memory cfg = pool.vtsConfig;
        uint256 liq = uint256(pos.liquidity);

        uint256 total;
        {
            // 1) Base exposures (RfS/commitment, floored by VTS_base)
            uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
            uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
            if (cfg.token0.baseVTSRate > e0bps) e0bps = cfg.token0.baseVTSRate;
            if (cfg.token1.baseVTSRate > e1bps) e1bps = cfg.token1.baseVTSRate;

            // 2) Determine a portion of the seizure exposure proportional to settled / RfS amount
            uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
            uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);

            // 3) Calculate seized liquidity units based on exposure / commitment sized by settlement
            total = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps)
                + LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);
        }

        // 4) Cap at full position liquidity and apply residual threshold
        // Apply residual threshold: if remaining liquidity would be below minResidualUnits, fully close the position
        {
            uint256 minResidual = cfg.minResidualUnits == 0 ? 1 : cfg.minResidualUnits;
            if (total < liq && (liq - total) < minResidual) {
                total = liq;
            } else if (total > liq) {
                total = liq;
            }
        }

        return total;
    }
}
