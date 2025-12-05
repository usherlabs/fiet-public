// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {
    VTSStorage,
    PositionAccounting,
    PoolAccounting,
    GrowthPair,
    MarketVTSConfiguration,
    TokenPairUint,
    TokenPairInt,
    TokenPairLib
} from "../types/VTS.sol";
import {
    PositionId,
    Position,
    PositionLibrary,
    PositionModificationHookData,
    PositionModificationHookDataLib
} from "../types/Position.sol";
import {Pool} from "../types/Pool.sol";
import {Commit} from "../types/Commit.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {TransientSlots} from "./TransientSlots.sol";
import {TickUtils} from "./TickUtils.sol";
import {VTSCommitLib} from "./VTSCommitLib.sol";
import {VTSSettleLib} from "./VTSSettleLib.sol";
import {Errors} from "./Errors.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {console} from "forge-std/console.sol";
import {ProxySwapFlag} from "./ProxySwapFlag.sol";
import {ProxyHook} from "../ProxyHook.sol";

/// @title VTSPoolAndPositionAccountingLib
/// @notice Pool and position-level accounting helpers for VTS, operating on VTSStorage
/// @dev All functions are external/public for linked-library usage but prefixed with `_` as they are conceptually internal.
/// @author Fiet Protocol
library VTSPoolAndPositionAccountingLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencySettler for Currency;
    using TokenPairLib for TokenPairUint;
    using TokenPairLib for TokenPairInt;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    /// @notice Processes the logic for CoreHook._afterSwap
    function _processSwap(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolKey calldata key,
        SwapParams calldata,
        BalanceDelta delta,
        uint160 sqrtPBefore,
        uint128 liqBefore
    ) external {
        // Inflow growth is net of (excludes) LP/protocol fees.

        // Tick cross flips + per-segment accrual: iterate initialised ticks crossed during the swap
        {
            // read start tick from transient sqrtP_before and end tick from state
            (uint160 sqrtPAfter, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, key.toId());
            int24 tickBefore = TickMath.getTickAtSqrtPrice(sqrtPBefore);

            if (tickAfter != tickBefore) {
                bool zeroForOne = tickAfter < tickBefore;
                // running sqrt for segment starts
                uint160 sqrtCurrent = sqrtPBefore;
                // running segment liquidity snapshot (from beforeSwap)
                uint128 segmentLiquidity = liqBefore;
                int24 stepTick = tickBefore;
                while (true) {
                    // next initialised tick in the direction of the swap
                    (int24 next, bool initialized) = TickUtils.nextInitializedTickWithinOneWord(
                        poolManager, key.toId(), stepTick, key.tickSpacing, zeroForOne
                    );
                    // compute target sqrt for this segment (either next tick or final price)
                    // Ensure we don't go beyond valid tick bounds
                    int24 boundedNext = next;
                    if (boundedNext <= TickMath.MIN_TICK) {
                        boundedNext = TickMath.MIN_TICK;
                    }
                    if (boundedNext >= TickMath.MAX_TICK) {
                        boundedNext = TickMath.MAX_TICK;
                    }
                    uint160 sqrtNext = TickMath.getSqrtPriceAtTick(boundedNext);
                    uint160 sqrtTarget = zeroForOne
                        ? (sqrtPAfter < sqrtNext ? sqrtPAfter : sqrtNext)
                        : (sqrtPAfter > sqrtNext ? sqrtPAfter : sqrtNext);
                    if (segmentLiquidity > 0 && sqrtTarget != sqrtCurrent) {
                        // amountOut per segment from price delta and liquidity
                        // see reference: https://github.com/Uniswap/v4-core/blob/0f17b65aa61edee384d5129b7ea080f22905faa0/src/libraries/SwapMath.sol#L88
                        uint256 outSeg = zeroForOne
                            ? SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, segmentLiquidity, false)
                            : SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, segmentLiquidity, false);
                        if (outSeg > 0) {
                            _accrueDeficitGlobalGrowth(s, key.toId(), zeroForOne ? 1 : 0, outSeg, segmentLiquidity);
                        }
                        // Inflow accrual per segment using no-fee input (net of LP/protocol fees)
                        {
                            uint8 tokenIn = zeroForOne ? 0 : 1;
                            uint256 inNoFee = zeroForOne
                                ? SqrtPriceMath.getAmount0Delta(sqrtCurrent, sqrtTarget, segmentLiquidity, true)
                                : SqrtPriceMath.getAmount1Delta(sqrtTarget, sqrtCurrent, segmentLiquidity, true);
                            if (inNoFee > 0) {
                                _accrueInflowGlobalGrowth(s, key.toId(), tokenIn, inNoFee, segmentLiquidity);
                            }
                        }
                        sqrtCurrent = sqrtTarget;
                    }
                    // stop if we've reached final price
                    if (sqrtTarget == sqrtPAfter) {
                        break;
                    }
                    // otherwise, we crossed an initialised tick; flip outside and update liquidity
                    if (initialized) {
                        _onTickCross(s, poolManager, key.toId(), next, 0);
                        _onTickCross(s, poolManager, key.toId(), next, 1);
                        // apply liquidity net change for subsequent segments (direction-aware)
                        (, int128 liquidityNet) = StateLibrary.getTickLiquidity(poolManager, key.toId(), next);
                        if (zeroForOne) liquidityNet = -liquidityNet;
                        unchecked {
                            if (liquidityNet < 0) {
                                segmentLiquidity = uint128(uint256(segmentLiquidity) - uint256(uint128(-liquidityNet)));
                            } else if (liquidityNet > 0) {
                                segmentLiquidity = uint128(uint256(segmentLiquidity) + uint256(uint128(liquidityNet)));
                            }
                        }
                    }
                    stepTick = next;
                }
            } else {
                // Intra-tick swap: accrue a single segment from sqrtPBefore to sqrtPAfter
                // Determine direction by price movement
                bool zeroForOne = sqrtPAfter < sqrtPBefore;
                // Load liquidity snapshot from beforeSwap
                uint128 segmentLiquidity = liqBefore;
                if (segmentLiquidity > 0 && sqrtPAfter != sqrtPBefore) {
                    uint256 outSeg = zeroForOne
                        ? SqrtPriceMath.getAmount1Delta(sqrtPAfter, sqrtPBefore, segmentLiquidity, false)
                        : SqrtPriceMath.getAmount0Delta(sqrtPBefore, sqrtPAfter, segmentLiquidity, false);
                    if (outSeg > 0) {
                        _accrueDeficitGlobalGrowth(s, key.toId(), zeroForOne ? 1 : 0, outSeg, segmentLiquidity);
                    }
                    // Inflow accrual for intra-tick segment (no-fee input)
                    {
                        uint8 tokenIn = zeroForOne ? 0 : 1;
                        uint256 inNoFee = zeroForOne
                            ? SqrtPriceMath.getAmount0Delta(sqrtPBefore, sqrtPAfter, segmentLiquidity, true)
                            : SqrtPriceMath.getAmount1Delta(sqrtPAfter, sqrtPBefore, segmentLiquidity, true);
                        if (inNoFee > 0) {
                            _accrueInflowGlobalGrowth(s, key.toId(), tokenIn, inNoFee, segmentLiquidity);
                        }
                    }
                }
            }
        }

        // Check if this is a direct core pool swap, and if it is, call the proxy hook
    }

    /// @notice Tracks the maximum potential commitment for both tokens in a position
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

    /// @notice Updates the settlement amount by a delta which could be positive or negative
    /// @param s The central VTS storage
    /// @param id The position id
    /// @param tokenIndex The token index (0 or 1)
    /// @param delta The delta of the settlement
    /// @return applied The applied delta to the total settlement amount
    function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
        public
        returns (int256 applied)
    {
        // Derive poolId from position to minimise parameters
        Position memory pos = s.positions[id];
        PoolId poolId = pos.poolId;
        PositionAccounting storage pa = s.positionAccounting[id];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read current settled amount and commitment maxima for the selected token
        uint256 cur = pa.settled.get(tokenIndex);
        uint256 c = pa.commitmentMax.get(tokenIndex);
        uint256 cumulativeDef = pa.cumulativeDeficit.get(tokenIndex);
        uint256 commitmentDef = pa.commitmentDeficit.get(tokenIndex);
        int256 netSinceLastMod = pa.netSettlementSinceLastMod.get(tokenIndex);
        uint256 poolNetSinceLastMod = paPool.poolNetSinceLastMod.get(tokenIndex);

        if (delta == 0) {
            return 0;
        }
        uint256 next = cur;

        if (delta > 0) {
            // Auto-net any lingering deficit first
            if (cumulativeDef > 0) {
                uint256 cover = uint256(delta) > cumulativeDef ? cumulativeDef : uint256(delta);
                if (cover > 0) {
                    cumulativeDef -= cover;
                    // keep global coherent
                    uint256 gD = paPool.globalDeficit.get(tokenIndex);
                    paPool.globalDeficit.set(tokenIndex, cover <= gD ? (gD - cover) : 0);
                    delta -= int256(cover);
                }
            }
            // Then net against commitment-scoped deficit (insolvency gate)
            if (delta > 0 && commitmentDef > 0) {
                uint256 coverCd = uint256(delta) > commitmentDef ? commitmentDef : uint256(delta);
                if (coverCd > 0) {
                    commitmentDef -= coverCd;
                    delta -= int256(coverCd);
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

        // Write back updated settlement and accounting fields based on token index
        pa.settled.set(tokenIndex, next);
        pa.cumulativeDeficit.set(tokenIndex, cumulativeDef);
        pa.commitmentDeficit.set(tokenIndex, commitmentDef);

        applied = next.toInt256() - cur.toInt256(); // output delta

        // Update commit-level settled amounts if position belongs to a commit
        if (pos.commitId > 0) {
            Commit storage commit = s.commits[pos.commitId];
            Pool storage pool = s.pools[poolId];
            Currency currency = tokenIndex == 0 ? pool.currency0 : pool.currency1;

            uint256 commitSettled = commit.settled[currency];
            if (applied > 0) {
                commit.settled[currency] = commitSettled + uint256(applied);
            } else if (applied < 0) {
                uint256 subtract = uint256(-applied);
                commit.settled[currency] = subtract > commitSettled ? 0 : (commitSettled - subtract);
            }
        }

        // Accrue persistent nets since last fee finalisation
        pa.netSettlementSinceLastMod.set(tokenIndex, netSinceLastMod + applied);
        if (applied >= 0) {
            paPool.poolNetSinceLastMod.set(tokenIndex, poolNetSinceLastMod + uint256(applied));
        } else {
            uint256 dec = uint256(-applied);
            uint256 curPoolNet = poolNetSinceLastMod;
            paPool.poolNetSinceLastMod.set(tokenIndex, dec > curPoolNet ? 0 : (curPoolNet - dec));
        }
    }

    // --------------------------------------------------
    // Growth Accounting Helper Functions
    // --------------------------------------------------

    /// @notice Called by the hook on tick cross to flip outside growth for a tick
    function _onTickCross(VTSStorage storage s, IPoolManager poolManager, PoolId poolId, int24 tick, uint8 token)
        public
    {
        // Flip deficit growth outside
        _flipOutside(s, poolId, tick, token, 0);
        // Flip inflow growth outside
        _flipOutside(s, poolId, tick, token, 1);
        // Flip coverage usage growth outside
        _flipOutside(s, poolId, tick, token, 2);

        // Apply residual if any when liquidity becomes active
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 residual = paPool.coverageResidual.get(token);
        if (residual > 0) {
            uint128 liq = StateLibrary.getLiquidity(poolManager, poolId);
            if (liq > 0) {
                uint256 deltaG = FullMath.mulDiv(residual, FixedPoint128.Q128, uint256(liq));
                uint256 currentGrowth = paPool.coverageUseGrowthGlobal.get(token);
                paPool.coverageUseGrowthGlobal.set(token, currentGrowth + deltaG);
                paPool.coverageResidual.set(token, 0);
            }
        }
    }

    /// @notice Flip outside growth for a tick
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param tick The tick
    /// @param token The token index (0 or 1)
    /// @param growthType The growth type (0 = deficit, 1 = inflow, 2 = coverage usage)
    function _flipOutside(VTSStorage storage s, PoolId poolId, int24 tick, uint8 token, uint8 growthType) public {
        if (token > 1) return;
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 g;
        GrowthPair storage outsidePair;

        if (growthType == 0) {
            // Deficit growth
            g = paPool.deficitGrowthGlobal.get(token);
            outsidePair = s.deficitGrowthOutside[poolId][tick];
        } else if (growthType == 1) {
            // Inflow growth
            g = paPool.inflowGrowthGlobal.get(token);
            outsidePair = s.inflowGrowthOutside[poolId][tick];
        } else if (growthType == 2) {
            // Coverage usage growth
            g = paPool.coverageUseGrowthGlobal.get(token);
            outsidePair = s.coverageUseGrowthOutside[poolId][tick];
        } else {
            return;
        }

        uint256 o = token == 0 ? outsidePair.token0 : outsidePair.token1;
        uint256 newOutside = g - o;
        if (token == 0) {
            outsidePair.token0 = newOutside;
        } else {
            outsidePair.token1 = newOutside;
        }
    }

    /// @notice Accrue growth to a pool's global accumulator (per token) using current in-range liquidity
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param token The token index (0 or 1)
    /// @param amount The amount to accrue
    /// @param liquidity The current in-range liquidity
    function _accrueDeficitGlobalGrowth(
        VTSStorage storage s,
        PoolId poolId,
        uint8 token,
        uint256 amount,
        uint128 liquidity
    ) public {
        if (token > 1 || amount == 0 || liquidity == 0) return;
        uint256 deltaG = FullMath.mulDiv(amount, FixedPoint128.Q128, uint256(liquidity));
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentGrowth = paPool.deficitGrowthGlobal.get(token);
        paPool.deficitGrowthGlobal.set(token, currentGrowth + deltaG);
    }

    /// @notice Accrue inflow growth to a pool's global accumulator (per token) using current in-range liquidity
    /// @param s The central VTS storage
    /// @param poolId The pool ID
    /// @param token The token index (0 or 1)
    /// @param amount The amount to accrue
    /// @param liquidity The current in-range liquidity
    function _accrueInflowGlobalGrowth(
        VTSStorage storage s,
        PoolId poolId,
        uint8 token,
        uint256 amount,
        uint128 liquidity
    ) public {
        if (token > 1 || amount == 0 || liquidity == 0) return;
        uint256 deltaG = FullMath.mulDiv(amount, FixedPoint128.Q128, uint256(liquidity));
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentGrowth = paPool.inflowGrowthGlobal.get(token);
        paPool.inflowGrowthGlobal.set(token, currentGrowth + deltaG);
    }

    /// @notice Compute inside growth for a position range using GrowthPair-based outside mappings
    /// @param poolId The pool ID
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param global0 The global growth for token0
    /// @param global1 The global growth for token1
    /// @param outsideMap The outside growth mapping (deficitGrowthOutside, inflowGrowthOutside, or coverageUseGrowthOutside)
    /// @return inside0 The inside growth for token0
    /// @return inside1 The inside growth for token1
    function _growthInside(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint256 global0,
        uint256 global1,
        mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap
    ) private view returns (uint256 inside0, uint256 inside1) {
        GrowthPair memory lower = outsideMap[poolId][tickLower];
        GrowthPair memory upper = outsideMap[poolId][tickUpper];
        inside0 = global0 - lower.token0 - upper.token0;
        inside1 = global1 - lower.token1 - upper.token1;
    }

    /// @notice Compute delta and checkpoint for growth settlement
    /// @param poolId The pool ID
    /// @param tickLower The lower tick
    /// @param tickUpper The upper tick
    /// @param liquidity The position liquidity
    /// @param global0 The global growth for token0
    /// @param global1 The global growth for token1
    /// @param outsideMap The outside growth mapping
    /// @param pa The position accounting storage reference
    /// @param snapField0 The field name identifier for token0 snapshot (0=deficit, 1=inflow, 2=coverage)
    /// @param snapField1 The field name identifier for token1 snapshot (0=deficit, 1=inflow, 2=coverage)
    /// @return add0 The attributed growth delta for token0
    /// @return add1 The attributed growth delta for token1
    function _deltaAndCheckpointGrowth(
        PoolId poolId,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint256 global0,
        uint256 global1,
        mapping(PoolId => mapping(int24 => GrowthPair)) storage outsideMap,
        PositionAccounting storage pa,
        uint8 snapField0,
        uint8 snapField1
    ) private returns (uint256 add0, uint256 add1) {
        (uint256 inside0, uint256 inside1) = _growthInside(poolId, tickLower, tickUpper, global0, global1, outsideMap);

        // Read last snapshots based on field identifier
        uint256 lastSnap0;
        uint256 lastSnap1;
        if (snapField0 == 0) {
            lastSnap0 = pa.deficitGrowthInsideLast.token0;
            pa.deficitGrowthInsideLast.token0 = inside0;
        } else if (snapField0 == 1) {
            lastSnap0 = pa.inflowGrowthInsideLast.token0;
            pa.inflowGrowthInsideLast.token0 = inside0;
        } else {
            lastSnap0 = pa.coverageUseGrowthInsideLast.token0;
            pa.coverageUseGrowthInsideLast.token0 = inside0;
        }

        if (snapField1 == 0) {
            lastSnap1 = pa.deficitGrowthInsideLast.token1;
            pa.deficitGrowthInsideLast.token1 = inside1;
        } else if (snapField1 == 1) {
            lastSnap1 = pa.inflowGrowthInsideLast.token1;
            pa.inflowGrowthInsideLast.token1 = inside1;
        } else {
            lastSnap1 = pa.coverageUseGrowthInsideLast.token1;
            pa.coverageUseGrowthInsideLast.token1 = inside1;
        }

        uint256 d0 = inside0 - lastSnap0;
        uint256 d1 = inside1 - lastSnap1;
        if (liquidity > 0) {
            if (d0 > 0) {
                add0 = FullMath.mulDiv(d0, uint256(liquidity), FixedPoint128.Q128);
            }
            if (d1 > 0) {
                add1 = FullMath.mulDiv(d1, uint256(liquidity), FixedPoint128.Q128);
            }
        }
    }

    /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settlePositionDeficitGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId)
        public
    {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
            poolId,
            pos.tickLower,
            pos.tickUpper,
            liq,
            paPool.deficitGrowthGlobal.token0,
            paPool.deficitGrowthGlobal.token1,
            s.deficitGrowthOutside,
            pa,
            0, // deficit growth field
            0 // deficit growth field
        );

        if (add0 > 0) {
            // Track full attributed outflows for fee sharing normalisation window
            pa.cumulativeOutflows.token0 += add0;

            // Consume settled coverage first, then accrue shortfall to deficit
            uint256 s0 = pa.settled.token0;
            if (s0 >= add0) {
                _updateSettlement(s, positionId, 0, -int256(add0)); // reduce total settlement amount by add0
            } else {
                uint256 netAdd0 = add0 - s0;
                pa.cumulativeDeficit.token0 += netAdd0;
                paPool.globalDeficit.token0 += netAdd0;
                _updateSettlement(s, positionId, 0, -int256(s0)); // set total settlement amount to 0
            }
        }
        if (add1 > 0) {
            pa.cumulativeOutflows.token1 += add1;

            uint256 s1 = pa.settled.token1;
            if (s1 >= add1) {
                _updateSettlement(s, positionId, 1, -int256(add1)); // reduce total settlement amount by add1
            } else {
                uint256 netAdd1 = add1 - s1;
                pa.cumulativeDeficit.token1 += netAdd1;
                paPool.globalDeficit.token1 += netAdd1;
                _updateSettlement(s, positionId, 1, -int256(s1)); // set total settlement amount to 0
            }
        }
    }

    /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
            poolId,
            pos.tickLower,
            pos.tickUpper,
            liq,
            paPool.inflowGrowthGlobal.token0,
            paPool.inflowGrowthGlobal.token1,
            s.inflowGrowthOutside,
            pa,
            1, // inflow growth field
            1 // inflow growth field
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

    /// @notice Read fees since last snapshot and checkpoint fee growth and outflow snapshots atomically
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param positionLiquidity The position liquidity
    /// @return fees The fees accrued since last snapshot
    /// @return ofDelta The outflow delta since last fee snapshot
    function _readFeesAndCheckpoint(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        uint8 tokenIndex,
        uint128 positionLiquidity
    ) public returns (uint256 fees, uint256 ofDelta) {
        Position memory pos = s.positions[positionId];
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, poolId, pos.tickLower, pos.tickUpper);
        uint256 fg = tokenIndex == 0 ? fg0 : fg1;

        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 last = pa.feeGrowthInsideLast.get(tokenIndex);

        if (positionLiquidity > 0 && fg > last) {
            fees = FullMath.mulDiv(fg - last, uint256(positionLiquidity), FixedPoint128.Q128);
        } else {
            fees = 0;
        }

        // Compute outflow window and checkpoint both snapshots
        uint256 cf = pa.cumulativeOutflows.get(tokenIndex);
        uint256 snap = pa.outflowsAtFeeSnap.get(tokenIndex);
        ofDelta = cf >= snap ? (cf - snap) : 0;

        // Snapshot fees here
        pa.feeGrowthInsideLast.set(tokenIndex, fg);
        pa.outflowsAtFeeSnap.set(tokenIndex, cf);
    }

    /// @notice Settle coverage-usage growth and burn fees only on exercised deficits
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settleCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(poolManager, poolId, PositionId.unwrap(positionId));

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        (uint256 cov0, uint256 cov1) = _deltaAndCheckpointGrowth(
            poolId,
            pos.tickLower,
            pos.tickUpper,
            liq,
            paPool.coverageUseGrowthGlobal.token0,
            paPool.coverageUseGrowthGlobal.token1,
            s.coverageUseGrowthOutside,
            pa,
            2, // coverage growth field
            2 // coverage growth field
        );

        if (cov0 > 0) {
            _applyCoverageBurn(s, poolManager, positionId, poolId, 0, cov0, liq);
        }
        if (cov1 > 0) {
            _applyCoverageBurn(s, poolManager, positionId, poolId, 1, cov1, liq);
        }
    }

    /// @notice Apply coverage burn for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param id The position ID
    /// @param p The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param cov The coverage usage amount
    /// @param positionLiquidity The position liquidity
    function _applyCoverageBurn(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId id,
        PoolId p,
        uint8 tokenIndex,
        uint256 cov,
        uint128 positionLiquidity
    ) private {
        PositionAccounting storage pa = s.positionAccounting[id];
        uint256 d = pa.cumulativeDeficit.get(tokenIndex);
        uint256 settled = pa.settled.get(tokenIndex);
        if (cov == 0 || (d == 0 && settled == 0)) return;

        // Enforce invariant: cov <= d + settled, then burn only deficit portion
        uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
        if (cEff == 0 || d == 0) return;
        uint256 burnBase = cEff < d ? cEff : d; // min(coverage, deficit)

        (uint256 fees, uint256 ofDelta) = _readFeesAndCheckpoint(s, poolManager, id, p, tokenIndex, positionLiquidity);
        if (fees == 0 || ofDelta == 0) return;

        Pool memory pool = s.pools[p];
        MarketVTSConfiguration memory cfg = pool.vtsConfig;
        uint256 bps = cfg.coverageFeeShare;
        if (bps == 0) return;

        // feesBurn = fees * (burnBase / ofDelta) * bps/10000
        uint256 feesBurn = FullMath.mulDiv(fees, burnBase, ofDelta);
        feesBurn = FullMath.mulDiv(feesBurn, bps, LiquidityUtils.BPS_DENOMINATOR);
        if (feesBurn == 0) return;
        if (feesBurn > fees) feesBurn = fees; // clamp to fees accrued

        uint256 growthInc = 0;
        if (positionLiquidity > 0) {
            growthInc = FullMath.mulDiv(feesBurn, FixedPoint128.Q128, uint256(positionLiquidity));
            // Burn by advancing fee growth baseline
            uint256 currentFeeGrowth = pa.feeGrowthInsideLast.get(tokenIndex);
            pa.feeGrowthInsideLast.set(tokenIndex, currentFeeGrowth + growthInc);
        }

        PoolAccounting storage paPool = s.poolAccounting[p];
        uint256 currentProtocolFee = paPool.protocolFeeAccrued.get(tokenIndex);
        paPool.protocolFeeAccrued.set(tokenIndex, currentProtocolFee + feesBurn);
        uint256 currentFeesShared = pa.feesShared.get(tokenIndex);
        pa.feesShared.set(tokenIndex, currentFeesShared + feesBurn);
        int256 currentPendingAdj = pa.pendingFeeAdj.get(tokenIndex);
        pa.pendingFeeAdj.set(tokenIndex, currentPendingAdj + int256(feesBurn));
    }

    /// @notice Internal helper to settle both deficit and inflow growth for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
        _settlePositionDeficitGrowth(s, poolManager, positionId);
        _settlePositionInflowGrowth(s, poolManager, positionId);
        _settleCoverageUsage(s, poolManager, positionId);
    }

    // --------------------------------------------------
    // Fee and Pot Management Functions
    // --------------------------------------------------

    /// @notice Peek the current pending fee adjustments for a position without mutating state
    /// @param s The central VTS storage
    /// @param positionId The position ID
    /// @return adj0 The pending fee adjustment for token0 (+slash, -bonus)
    /// @return adj1 The pending fee adjustment for token1 (+slash, -bonus)
    function _peekFeeAdjustment(VTSStorage storage s, PositionId positionId)
        public
        view
        returns (int256 adj0, int256 adj1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        adj0 = pa.pendingFeeAdj.token0;
        adj1 = pa.pendingFeeAdj.token1;
    }

    /// @notice Increase the slashed pot for a pool/token when a take() succeeds
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param lccCurrency The LCC currency
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to fund
    function _fundFeePot(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        Currency lccCurrency,
        uint8 tokenIndex,
        uint256 amount
    ) public {
        if (amount == 0) return;
        // In linked libraries, address(this) refers to the calling contract via DELEGATECALL
        lccCurrency.take(poolManager, address(this), amount, true);
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 currentPot = paPool.slashedPot.get(tokenIndex);
        paPool.slashedPot.set(tokenIndex, currentPot + amount);
    }

    /// @notice Decrease the slashed pot when settling bonuses (giving out from CoreHook to PoolManager)
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param lccCurrency The LCC currency
    /// @param tokenIndex The token index (0 or 1)
    /// @param amount The amount to drain
    function _drainFeePot(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        Currency lccCurrency,
        uint8 tokenIndex,
        uint256 amount
    ) public {
        if (amount == 0) return;
        lccCurrency.settle(poolManager, address(this), amount, true);
        PoolAccounting storage paPool = s.poolAccounting[poolId];
        uint256 pot = paPool.slashedPot.get(tokenIndex);
        // Clamp to available pot to avoid underflow; caller must have already bounded the amount
        if (amount > pot) amount = pot;
        paPool.slashedPot.set(tokenIndex, pot - amount);
    }

    /// @notice Finalise a portion of the pending fee adjustment as materialised in the current hook call
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
    function _finaliseFeeAdjustment(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        Currency currency0,
        Currency currency1
    ) internal returns (BalanceDelta adj) {
        // Materialise pending: fund slashed pot for +ve; drain to LP for -ve
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(s, positionId);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 > 0) {
            _fundFeePot(s, poolManager, poolId, currency0, 0, uint256(pend0));
            mat0 = pend0;
        } else if (pend0 < 0) {
            uint256 need0 = uint256(-pend0);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot0 = paPool.slashedPot.token0;
            uint256 pay0 = pot0 < need0 ? pot0 : need0;
            if (pay0 > 0) {
                _drainFeePot(s, poolManager, poolId, currency0, 0, pay0);
                mat0 = -pay0.toInt256();
            }
        }

        if (pend1 > 0) {
            _fundFeePot(s, poolManager, poolId, currency1, 1, uint256(pend1));
            mat1 = pend1;
        } else if (pend1 < 0) {
            uint256 need1 = uint256(-pend1);
            PoolAccounting storage paPool = s.poolAccounting[poolId];
            uint256 pot1 = paPool.slashedPot.token1;
            uint256 pay1 = pot1 < need1 ? pot1 : need1;
            if (pay1 > 0) {
                _drainFeePot(s, poolManager, poolId, currency1, 1, pay1);
                mat1 = -pay1.toInt256();
            }
        }

        // Clamp materialised values to current pending to avoid over-finalisation
        // For positive pending, materialised must be in [0, p]; for negative pending, in [p, 0]
        if (pend0 >= 0) {
            if (mat0 < 0) mat0 = 0;
            if (mat0 > pend0) mat0 = pend0;
        } else {
            if (mat0 > 0) mat0 = 0;
            if (mat0 < pend0) mat0 = pend0;
        }
        if (pend1 >= 0) {
            if (mat1 < 0) mat1 = 0;
            if (mat1 > pend1) mat1 = pend1;
        } else {
            if (mat1 > 0) mat1 = 0;
            if (mat1 < pend1) mat1 = pend1;
        }

        // Subtract the materialised portion from pending (note: signed arithmetic)
        PositionAccounting storage pa = s.positionAccounting[positionId];
        pa.pendingFeeAdj.token0 = pend0 - mat0;
        pa.pendingFeeAdj.token1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);

        // Snapshot current pending after finalisation to keep future settle-time funding incremental
        pa.lastFundedPendingAdj.token0 = pa.pendingFeeAdj.token0;
        pa.lastFundedPendingAdj.token1 = pa.pendingFeeAdj.token1;
    }

    /// @notice Consolidated fee processing for a position during modification: applies and zeros nets, queues bonus using net weighting
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @return adj The materialised fee adjustment delta
    function _processPositionFees(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        Currency currency0,
        Currency currency1
    ) public returns (BalanceDelta adj) {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        Pool memory pool = s.pools[poolId];

        // If fee sharing is enabled, skip processing (fees handled elsewhere)
        if (pool.vtsConfig.coverageFeeShare > 0) {
            return toBalanceDelta(0, 0);
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read per-position nets (already applied to settled via _updateSettlement). Do not mutate yet
        int256 selfNet0 = pa.netSettlementSinceLastMod.token0;
        int256 selfNet1 = pa.netSettlementSinceLastMod.token1;

        // Queue bonuses using positive nets since last modification
        for (uint8 t = 0; t < 2; t++) {
            int256 selfNet = (t == 0) ? selfNet0 : selfNet1;
            if (selfNet <= 0) continue;

            uint256 pot = paPool.protocolFeeAccrued.get(t);
            uint256 selfContrib = pa.feesShared.get(t);
            uint256 potAvail = pot > selfContrib ? (pot - selfContrib) : 0;
            if (potAvail == 0) continue;

            uint256 totalNetBefore = paPool.poolNetSinceLastMod.get(t);
            // totalNetBefore is UNSIGNED. Only positive when settled > 0 - preventing positive nets that cover deficits from being used
            if (totalNetBefore == 0) continue;

            // Dust guard
            if (uint256(selfNet) < 1e12) continue;

            uint256 bonus = FullMath.mulDiv(potAvail, uint256(selfNet), totalNetBefore);
            if (bonus > potAvail) bonus = potAvail;

            // Deduct from pot, keep self-contrib excluded
            paPool.protocolFeeAccrued.set(t, potAvail - bonus + selfContrib);
            // Queue negative pending (bonus increases payout at materialisation)
            int256 currentPending = pa.pendingFeeAdj.get(t);
            pa.pendingFeeAdj.set(t, currentPending - bonus.toInt256());
        }

        // After allocation, zero/decrement nets so future allocations don't double-count
        if (selfNet0 != 0) {
            pa.netSettlementSinceLastMod.token0 = 0;
            if (selfNet0 > 0) {
                uint256 cur0 = paPool.poolNetSinceLastMod.token0;
                uint256 dec0 = uint256(selfNet0);
                paPool.poolNetSinceLastMod.token0 = dec0 > cur0 ? 0 : (cur0 - dec0);
            }
        }
        if (selfNet1 != 0) {
            pa.netSettlementSinceLastMod.token1 = 0;
            if (selfNet1 > 0) {
                uint256 cur1 = paPool.poolNetSinceLastMod.token1;
                uint256 dec1 = uint256(selfNet1);
                paPool.poolNetSinceLastMod.token1 = dec1 > cur1 ? 0 : (cur1 - dec1);
            }
        }

        return _finaliseFeeAdjustment(s, poolManager, positionId, poolId, currency0, currency1);
    }

    /// @notice Increment protocol or proactive excess liquidity coverage on LCC unwrap, consuming proactive pool first
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param poolId The pool ID
    /// @param tokenIndex The token index (0 or 1)
    /// @param coveredAmount The amount covered
    function _incrementCoverage(
        VTSStorage storage s,
        IPoolManager poolManager,
        PoolId poolId,
        uint8 tokenIndex,
        uint256 coveredAmount
    ) public {
        if (tokenIndex > 1 || coveredAmount == 0) return;
        uint128 liq = StateLibrary.getLiquidity(poolManager, poolId);
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        if (liq > 0) {
            // Accrue coverage usage growth per-liquidity (outflow weight basis at current tick)
            uint256 deltaG = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, uint256(liq));
            uint256 currentGrowth = paPool.coverageUseGrowthGlobal.get(tokenIndex);
            paPool.coverageUseGrowthGlobal.set(tokenIndex, currentGrowth + deltaG);
        } else {
            // No in-range liquidity; defer to residual
            uint256 currentResidual = paPool.coverageResidual.get(tokenIndex);
            paPool.coverageResidual.set(tokenIndex, currentResidual + coveredAmount);
        }
    }

    /// @dev Check if fee sharing is enabled for a pool
    function _isFeeSharingEnabled(VTSStorage storage s, PoolId p) internal view returns (bool) {
        return s.pools[p].vtsConfig.coverageFeeShare > 0;
    }

    // --------------------------------------------------
    // Position Registration and Management (consolidated from MMPositionsLib)
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
    ) public {
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
            salt: params.salt
        });
    }

    /// @notice Link a position to a commit
    /// @param s The VTS storage
    /// @param positionManager The position manager address
    /// @param positionId The position id
    /// @param tokenId The token id (commit id)
    function _linkPositionToCommit(
        VTSStorage storage s,
        address positionManager,
        PositionId positionId,
        uint256 tokenId
    ) public {
        // validate there is an existing commit for the token id
        if (s.commits[tokenId].expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }

        // Get current position count to use as index for the new position
        uint256 currentPositionCount = s.commits[tokenId].positionCount;

        // modify the commit to include the position and update the position count
        s.commits[tokenId].positions[currentPositionCount] = positionId;
        s.commits[tokenId].positionCount++;

        // update the commitId of the position i.e associate the position with the commit
        s.positions[positionId].commitId = tokenId;
    }

    /// @notice Calculate RFS (Required for Settlement) for a position
    /// @param s The VTS storage
    /// @param poolManager The pool manager
    /// @param id The position id
    /// @param requireClosedRfS Whether to require the RFS to be closed
    /// @return rfsOpen Whether the RFS is open
    /// @return delta The RFS delta
    function _calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
        public
        returns (bool rfsOpen, BalanceDelta delta)
    {
        // Settle position growths before calculating RFS
        _settlePositionGrowths(s, poolManager, id);

        (rfsOpen, delta) = VTSSettleLib._getRFS(s, id);
        if (requireClosedRfS && rfsOpen) {
            revert Errors.RFSOpenForPosition(id);
        }
    }

    /// @notice Touch a position to update its state, process fees, and calculate required settlement delta
    /// @dev Single entry point for position processing - handles registration, linking, fee processing
    /// @param s The VTS storage
    /// @param poolManager The pool manager
    /// @param owner The owner of the position
    /// @param poolId The pool id
    /// @param params The modify liquidity params
    /// @param hookData The hook data containing PositionModificationHookData
    /// @param positionManager The MM position manager address
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @return id The position id
    /// @return requiredSettlementDelta The required settlement delta
    /// @return feeAdj The fee adjustment delta
    /// @return isSeizing Whether this is a seizure operation
    /// @return isNewPosition Whether this is a new position
    function _touchPosition(
        VTSStorage storage s,
        IPoolManager poolManager,
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        address positionManager,
        Currency currency0,
        Currency currency1
    )
        external
        returns (
            PositionId id,
            BalanceDelta requiredSettlementDelta,
            BalanceDelta feeAdj,
            bool isSeizing,
            bool isNewPosition
        )
    {
        id = PositionLibrary.generateId(owner, params);
        Position storage pos = s.positions[id];

        // pos.owner == address(0) means new position
        isNewPosition = pos.owner == address(0);
        bool isMMPosition = isNewPosition ? owner == positionManager : pos.owner == positionManager;

        uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(id));

        // Decode hookData using the PositionModificationHookData struct
        BalanceDelta seizureSettlementDelta = BalanceDelta.wrap(0);
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);

        if (mmData.seizure.isSeizing) {
            isSeizing = true;
            seizureSettlementDelta = toBalanceDelta(mmData.seizure.settle0, mmData.seizure.settle1);
        }

        // Initialize requiredSettlementDelta to zero
        requiredSettlementDelta = BalanceDelta.wrap(0);

        if (isNewPosition) {
            // NEW POSITION: initialize the liquidity to the liquidity delta
            _registerPosition(s, owner, poolId, params);
            // TODO: Re-add initSnapshots.
            _trackCommitment(s, id, params);

            // Link position to commit for MM positions
            if (isMMPosition && mmData.commitId > 0) {
                _linkPositionToCommit(s, positionManager, id, mmData.commitId);
            }

            // get the commitment maxima for the position
            TokenPairUint memory commitmentMaxima = s.positionAccounting[id].commitmentMax;

            if (isMMPosition) {
                // New positions mean base settlement.
                MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
                (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                    commitmentMaxima.token0,
                    commitmentMaxima.token1,
                    vtsConfiguration.token0.baseVTSRate,
                    vtsConfiguration.token1.baseVTSRate
                );
                // Invert signs: negative delta = caller owes liquidity (deposit)
                requiredSettlementDelta =
                    LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
            } else {
                // Set the settlement amounts to the total commitment amounts for DirectLPs.
                _updateSettlement(s, id, 0, SafeCast.toInt256(commitmentMaxima.token0));
                _updateSettlement(s, id, 1, SafeCast.toInt256(commitmentMaxima.token1));
            }
        } else if (pos.isActive == true) {
            // EXISTING POSITION: update the liquidity by the liquidity delta
            if (params.liquidityDelta < 0) {
                // FULL or PARTIAL LIQUIDATION:

                // validate that RfS is closed before we track position param updates.
                // Skip calcRFS when seizing
                if (!isSeizing) {
                    _calcRFS(s, poolManager, id, true);
                }
                _trackCommitment(s, id, params);

                PositionAccounting storage pa = s.positionAccounting[id];
                uint256 s0 = pa.settled.token0;
                uint256 s1 = pa.settled.token1;
                uint256 excess0 = 0;
                uint256 excess1 = 0;

                if (liq == 0) {
                    // full liquidation
                    excess0 = s0;
                    excess1 = s1;
                } else {
                    // partial liquidation
                    TokenPairUint memory commitmentMaxima = pa.commitmentMax;
                    if (isSeizing) {
                        // Use seizure-specific excess calculation
                        (excess0, excess1) = LiquidityUtils.calculateSeizureExcess(
                            s0, s1, uint256(liq), uint256(-params.liquidityDelta), seizureSettlementDelta
                        );
                    } else {
                        // Standard excess calculation
                        if (s0 > commitmentMaxima.token0) {
                            excess0 = s0 - commitmentMaxima.token0;
                        }
                        if (s1 > commitmentMaxima.token1) {
                            excess1 = s1 - commitmentMaxima.token1;
                        }
                    }
                }

                console.log("excess0", excess0);
                console.log("excess1", excess1);
                console.log("isMMPosition", isMMPosition);
                console.logBytes32(PositionId.unwrap(id));

                if (isMMPosition) {
                    // Positive delta = protocol owes (withdrawal)
                    requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
                } else {
                    // Update settlement for DirectLPs
                    if (excess0 > 0) {
                        _updateSettlement(s, id, 0, -SafeCast.toInt256(excess0));
                    }
                    if (excess1 > 0) {
                        _updateSettlement(s, id, 1, -SafeCast.toInt256(excess1));
                    }
                }
            } else if (params.liquidityDelta > 0) {
                // POSITION DELTA INCREASE:
                _trackCommitment(s, id, params);

                PositionAccounting storage pa = s.positionAccounting[id];
                uint256 s0 = pa.settled.token0;
                uint256 s1 = pa.settled.token1;
                TokenPairUint memory commitmentMaxima = pa.commitmentMax;

                if (isMMPosition) {
                    // commitment maxima increases, recalculate base settlement requirements
                    MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
                    (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                        commitmentMaxima.token0,
                        commitmentMaxima.token1,
                        vtsConfiguration.token0.baseVTSRate,
                        vtsConfiguration.token1.baseVTSRate
                    );
                    uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
                    uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;

                    // Negative delta = caller owes liquidity (deposit)
                    requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
                } else {
                    // Increase DirectLPs settlement amounts
                    _updateSettlement(s, id, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0));
                    _updateSettlement(s, id, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1));
                }
            }

            // Update position liquidity
            int256 newLiquidity = SafeCast.toInt256(uint256(pos.liquidity)) + params.liquidityDelta;
            if (newLiquidity < 0) {
                pos.liquidity = 0;
            } else {
                pos.liquidity = SafeCast.toUint128(uint256(newLiquidity));
            }
        } else {
            revert Errors.NotActive(id);
        }

        // Update active status based on liquidity
        if (liq == 0) {
            pos.isActive = false;
        } else {
            pos.isActive = true;
        }

        // Process position fees - single entry point for fee processing
        feeAdj = _processPositionFees(s, poolManager, id, currency0, currency1);
    }
}
