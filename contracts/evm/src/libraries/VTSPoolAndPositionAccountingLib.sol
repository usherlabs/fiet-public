// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {
    VTSStorage,
    PositionAccounting,
    PoolAccounting,
    GrowthPair,
    MarketVTSConfiguration
} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {Pool} from "../types/Pool.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {
    IPoolManager
} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {
    StateLibrary
} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {
    FixedPoint128
} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BalanceDelta,
    toBalanceDelta
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @title VTSPoolAndPositionAccountingLib
/// @notice Pool and position-level accounting helpers for VTS, operating on VTSStorage
/// @dev All functions are external/public for linked-library usage but prefixed with `_` as they are conceptually internal.
/// @author Fiet Protocol
library VTSPoolAndPositionAccountingLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    using CurrencySettler for Currency;

    /// @notice Tracks the maximum potential commitment for both tokens in a position
    /// @param s The central VTS storage
    /// @param positionId The ascribed id of the position
    /// @param params The parameters of the transaction
    function _trackCommitment(
        VTSStorage storage s,
        PositionId positionId,
        ModifyLiquidityParams calldata params
    ) external {
        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Current tracked maxima for this position
        uint256 currentC0 = pa.commitmentMax0;
        uint256 currentC1 = pa.commitmentMax1;

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            // Cast int256 -> uint256 -> uint128 to preserve full uint128 range (not limited by int128 max)
            uint128 liquidityAdded = uint256(params.liquidityDelta).toUint128();
            (uint256 addC0, uint256 addC1) = LiquidityUtils
                .calculateCommitmentMaxima(
                    params.tickLower,
                    params.tickUpper,
                    liquidityAdded
                );

            pa.commitmentMax0 = currentC0 + addC0;
            pa.commitmentMax1 = currentC1 + addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = uint256(-params.liquidityDelta)
                .toUint128();
            (uint256 subC0, uint256 subC1) = LiquidityUtils
                .calculateCommitmentMaxima(
                    params.tickLower,
                    params.tickUpper,
                    liquidityRemoved
                );

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            pa.commitmentMax0 = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            pa.commitmentMax1 = currentC1 > subC1 ? (currentC1 - subC1) : 0;
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
    function _updateSettlement(
        VTSStorage storage s,
        PositionId id,
        uint8 tokenIndex,
        int256 delta
    ) public returns (int256 applied) {
        // Derive poolId from position to minimise parameters
        PoolId poolId = s.positions[id].poolId;
        PositionAccounting storage pa = s.positionAccounting[id];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read current settled amount and commitment maxima for the selected token
        uint256 cur;
        uint256 c;
        uint256 cumulativeDef;
        uint256 commitmentDef;
        int256 netSinceLastMod;
        uint256 poolNetSinceLastMod;

        if (tokenIndex == 0) {
            cur = pa.settled0;
            c = pa.commitmentMax0;
            cumulativeDef = pa.cumulativeDeficit0;
            commitmentDef = pa.commitmentDeficit0;
            netSinceLastMod = pa.netSettlementSinceLastMod0;
            poolNetSinceLastMod = paPool.poolNetSinceLastMod0;
        } else {
            cur = pa.settled1;
            c = pa.commitmentMax1;
            cumulativeDef = pa.cumulativeDeficit1;
            commitmentDef = pa.commitmentDeficit1;
            netSinceLastMod = pa.netSettlementSinceLastMod1;
            poolNetSinceLastMod = paPool.poolNetSinceLastMod1;
        }

        if (delta == 0) {
            return 0;
        }
        uint256 next = cur;

        if (delta > 0) {
            // Auto-net any lingering deficit first
            if (cumulativeDef > 0) {
                uint256 cover = uint256(delta) > cumulativeDef
                    ? cumulativeDef
                    : uint256(delta);
                if (cover > 0) {
                    cumulativeDef -= cover;
                    // keep global coherent
                    if (tokenIndex == 0) {
                        uint256 gD0 = paPool.globalDeficit0;
                        paPool.globalDeficit0 = cover <= gD0
                            ? (gD0 - cover)
                            : 0;
                    } else {
                        uint256 gD1 = paPool.globalDeficit1;
                        paPool.globalDeficit1 = cover <= gD1
                            ? (gD1 - cover)
                            : 0;
                    }
                    delta -= int256(cover);
                }
            }
            // Then net against commitment-scoped deficit (insolvency gate)
            if (delta > 0 && commitmentDef > 0) {
                uint256 coverCd = uint256(delta) > commitmentDef
                    ? commitmentDef
                    : uint256(delta);
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
        if (tokenIndex == 0) {
            pa.settled0 = next;
            pa.cumulativeDeficit0 = cumulativeDef;
            pa.commitmentDeficit0 = commitmentDef;
        } else {
            pa.settled1 = next;
            pa.cumulativeDeficit1 = cumulativeDef;
            pa.commitmentDeficit1 = commitmentDef;
        }

        applied = next.toInt256() - cur.toInt256(); // output delta

        // Accrue persistent nets since last fee finalisation
        if (tokenIndex == 0) {
            pa.netSettlementSinceLastMod0 = netSinceLastMod + applied;
            if (applied >= 0) {
                paPool.poolNetSinceLastMod0 =
                    poolNetSinceLastMod +
                    uint256(applied);
            } else {
                uint256 dec = uint256(-applied);
                uint256 curPoolNet = poolNetSinceLastMod;
                paPool.poolNetSinceLastMod0 = dec > curPoolNet
                    ? 0
                    : (curPoolNet - dec);
            }
        } else {
            pa.netSettlementSinceLastMod1 = netSinceLastMod + applied;
            if (applied >= 0) {
                paPool.poolNetSinceLastMod1 =
                    poolNetSinceLastMod +
                    uint256(applied);
            } else {
                uint256 dec = uint256(-applied);
                uint256 curPoolNet = poolNetSinceLastMod;
                paPool.poolNetSinceLastMod1 = dec > curPoolNet
                    ? 0
                    : (curPoolNet - dec);
            }
        }
    }

    // --------------------------------------------------
    // Growth Accounting Helper Functions
    // --------------------------------------------------

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
        (uint256 inside0, uint256 inside1) = _growthInside(
            poolId,
            tickLower,
            tickUpper,
            global0,
            global1,
            outsideMap
        );

        // Read last snapshots based on field identifier
        uint256 lastSnap0;
        uint256 lastSnap1;
        if (snapField0 == 0) {
            lastSnap0 = pa.deficitGrowthInsideLast0;
            pa.deficitGrowthInsideLast0 = inside0;
        } else if (snapField0 == 1) {
            lastSnap0 = pa.inflowGrowthInsideLast0;
            pa.inflowGrowthInsideLast0 = inside0;
        } else {
            lastSnap0 = pa.coverageUseGrowthInsideLast0;
            pa.coverageUseGrowthInsideLast0 = inside0;
        }

        if (snapField1 == 0) {
            lastSnap1 = pa.deficitGrowthInsideLast1;
            pa.deficitGrowthInsideLast1 = inside1;
        } else if (snapField1 == 1) {
            lastSnap1 = pa.inflowGrowthInsideLast1;
            pa.inflowGrowthInsideLast1 = inside1;
        } else {
            lastSnap1 = pa.coverageUseGrowthInsideLast1;
            pa.coverageUseGrowthInsideLast1 = inside1;
        }

        uint256 d0 = inside0 - lastSnap0;
        uint256 d1 = inside1 - lastSnap1;
        if (liquidity > 0) {
            if (d0 > 0)
                add0 = FullMath.mulDiv(
                    d0,
                    uint256(liquidity),
                    FixedPoint128.Q128
                );
            if (d1 > 0)
                add1 = FullMath.mulDiv(
                    d1,
                    uint256(liquidity),
                    FixedPoint128.Q128
                );
        }
    }

    /// @notice Settle deficit growth for a position into cumulativeDeficit in raw token units
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settlePositionDeficitGrowth(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId
    ) public {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(
            poolManager,
            poolId,
            PositionId.unwrap(positionId)
        );

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
            poolId,
            pos.tickLower,
            pos.tickUpper,
            liq,
            paPool.deficitGrowthGlobal0,
            paPool.deficitGrowthGlobal1,
            s.deficitGrowthOutside,
            pa,
            0, // deficit growth field
            0 // deficit growth field
        );

        if (add0 > 0) {
            // Track full attributed outflows for fee sharing normalisation window
            pa.cumulativeOutflows0 += add0;

            // Consume settled coverage first, then accrue shortfall to deficit
            uint256 s0 = pa.settled0;
            if (s0 >= add0) {
                _updateSettlement(s, positionId, 0, -int256(add0)); // reduce total settlement amount by add0
            } else {
                uint256 netAdd0 = add0 - s0;
                pa.cumulativeDeficit0 += netAdd0;
                paPool.globalDeficit0 += netAdd0;
                _updateSettlement(s, positionId, 0, -int256(s0)); // set total settlement amount to 0
            }
        }
        if (add1 > 0) {
            pa.cumulativeOutflows1 += add1;

            uint256 s1 = pa.settled1;
            if (s1 >= add1) {
                _updateSettlement(s, positionId, 1, -int256(add1)); // reduce total settlement amount by add1
            } else {
                uint256 netAdd1 = add1 - s1;
                pa.cumulativeDeficit1 += netAdd1;
                paPool.globalDeficit1 += netAdd1;
                _updateSettlement(s, positionId, 1, -int256(s1)); // set total settlement amount to 0
            }
        }
    }

    /// @notice Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settlePositionInflowGrowth(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId
    ) public {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(
            poolManager,
            poolId,
            PositionId.unwrap(positionId)
        );

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        (uint256 add0, uint256 add1) = _deltaAndCheckpointGrowth(
            poolId,
            pos.tickLower,
            pos.tickUpper,
            liq,
            paPool.inflowGrowthGlobal0,
            paPool.inflowGrowthGlobal1,
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
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(
            poolManager,
            poolId,
            pos.tickLower,
            pos.tickUpper
        );
        uint256 fg = tokenIndex == 0 ? fg0 : fg1;

        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 last = tokenIndex == 0
            ? pa.feeGrowthInsideLast0
            : pa.feeGrowthInsideLast1;

        if (positionLiquidity > 0 && fg > last) {
            fees = FullMath.mulDiv(
                fg - last,
                uint256(positionLiquidity),
                FixedPoint128.Q128
            );
        } else {
            fees = 0;
        }

        // Compute outflow window and checkpoint both snapshots
        uint256 cf = tokenIndex == 0
            ? pa.cumulativeOutflows0
            : pa.cumulativeOutflows1;
        uint256 snap = tokenIndex == 0
            ? pa.outflowsAtFeeSnap0
            : pa.outflowsAtFeeSnap1;
        ofDelta = cf >= snap ? (cf - snap) : 0;

        // Snapshot fees here
        if (tokenIndex == 0) {
            pa.feeGrowthInsideLast0 = fg;
            pa.outflowsAtFeeSnap0 = cf;
        } else {
            pa.feeGrowthInsideLast1 = fg;
            pa.outflowsAtFeeSnap1 = cf;
        }
    }

    /// @notice Settle coverage-usage growth and burn fees only on exercised deficits
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settleCoverageUsage(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId
    ) public {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;
        uint128 liq = StateLibrary.getPositionLiquidity(
            poolManager,
            poolId,
            PositionId.unwrap(positionId)
        );

        PoolAccounting storage paPool = s.poolAccounting[poolId];
        PositionAccounting storage pa = s.positionAccounting[positionId];

        (uint256 cov0, uint256 cov1) = _deltaAndCheckpointGrowth(
            poolId,
            pos.tickLower,
            pos.tickUpper,
            liq,
            paPool.coverageUseGrowthGlobal0,
            paPool.coverageUseGrowthGlobal1,
            s.coverageUseGrowthOutside,
            pa,
            2, // coverage growth field
            2 // coverage growth field
        );

        if (cov0 > 0) {
            _applyCoverageBurn(
                s,
                poolManager,
                positionId,
                poolId,
                0,
                cov0,
                liq
            );
        }
        if (cov1 > 0) {
            _applyCoverageBurn(
                s,
                poolManager,
                positionId,
                poolId,
                1,
                cov1,
                liq
            );
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
        uint256 d = tokenIndex == 0
            ? pa.cumulativeDeficit0
            : pa.cumulativeDeficit1;
        uint256 settled = tokenIndex == 0 ? pa.settled0 : pa.settled1;
        if (cov == 0 || (d == 0 && settled == 0)) return;

        // Enforce invariant: cov <= d + settled, then burn only deficit portion
        uint256 cEff = cov <= (d + settled) ? cov : (d + settled);
        if (cEff == 0 || d == 0) return;
        uint256 burnBase = cEff < d ? cEff : d; // min(coverage, deficit)

        (uint256 fees, uint256 ofDelta) = _readFeesAndCheckpoint(
            s,
            poolManager,
            id,
            p,
            tokenIndex,
            positionLiquidity
        );
        if (fees == 0 || ofDelta == 0) return;

        Pool memory pool = s.pools[p];
        MarketVTSConfiguration memory cfg = pool.vtsConfig;
        uint256 bps = cfg.coverageFeeShare;
        if (bps == 0) return;

        // feesBurn = fees * (burnBase / ofDelta) * bps/10000
        uint256 feesBurn = FullMath.mulDiv(fees, burnBase, ofDelta);
        feesBurn = FullMath.mulDiv(
            feesBurn,
            bps,
            LiquidityUtils.BPS_DENOMINATOR
        );
        if (feesBurn == 0) return;
        if (feesBurn > fees) feesBurn = fees; // clamp to fees accrued

        uint256 growthInc = 0;
        if (positionLiquidity > 0) {
            growthInc = FullMath.mulDiv(
                feesBurn,
                FixedPoint128.Q128,
                uint256(positionLiquidity)
            );
            // Burn by advancing fee growth baseline
            if (tokenIndex == 0) {
                pa.feeGrowthInsideLast0 += growthInc;
            } else {
                pa.feeGrowthInsideLast1 += growthInc;
            }
        }

        PoolAccounting storage paPool = s.poolAccounting[p];
        if (tokenIndex == 0) {
            paPool.protocolFeeAccrued0 += feesBurn;
            pa.feesShared0 += feesBurn;
            pa.pendingFeeAdj0 += int256(feesBurn);
        } else {
            paPool.protocolFeeAccrued1 += feesBurn;
            pa.feesShared1 += feesBurn;
            pa.pendingFeeAdj1 += int256(feesBurn);
        }
    }

    /// @notice Internal helper to settle both deficit and inflow growth for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settlePositionGrowths(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId
    ) external {
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
    function _peekFeeAdjustment(
        VTSStorage storage s,
        PositionId positionId
    ) public view returns (int256 adj0, int256 adj1) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        adj0 = pa.pendingFeeAdj0;
        adj1 = pa.pendingFeeAdj1;
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
        if (tokenIndex == 0) {
            paPool.slashedPot0 += amount;
        } else {
            paPool.slashedPot1 += amount;
        }
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
        uint256 pot = tokenIndex == 0 ? paPool.slashedPot0 : paPool.slashedPot1;
        // Clamp to available pot to avoid underflow; caller must have already bounded the amount
        if (amount > pot) amount = pot;
        if (tokenIndex == 0) {
            paPool.slashedPot0 = pot - amount;
        } else {
            paPool.slashedPot1 = pot - amount;
        }
    }

    /// @notice Finalise a portion of the pending fee adjustment as materialised in the current hook call
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param poolId The pool ID
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @param isMMPosition Whether this is an MM-managed position (for transient storage handling)
    /// @return adj The materialised delta as BalanceDelta for the hook to apply this call only
    function _finaliseFeeAdjustment(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        PoolId poolId,
        Currency currency0,
        Currency currency1,
        bool isMMPosition
    ) public returns (BalanceDelta adj) {
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
            uint256 pot0 = paPool.slashedPot0;
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
            uint256 pot1 = paPool.slashedPot1;
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
        pa.pendingFeeAdj0 = pend0 - mat0;
        pa.pendingFeeAdj1 = pend1 - mat1;

        adj = LiquidityUtils.safeToBalanceDelta(mat0, mat1);
        // Note: Transient storage handling for MM positions should be done by the calling contract
        // if (isMMPosition) {
        //     TransientSlots.addFeeAdjDelta(adj);
        // }

        // Snapshot current pending after finalisation to keep future settle-time funding incremental
        pa.lastFundedPendingAdj0 = pa.pendingFeeAdj0;
        pa.lastFundedPendingAdj1 = pa.pendingFeeAdj1;
    }

    /// @notice Consolidated fee processing for a position during modification: applies and zeros nets, queues bonus using net weighting
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    /// @param currency0 The currency for token0
    /// @param currency1 The currency for token1
    /// @param isMMPosition Whether this is an MM-managed position
    /// @return adj The materialised fee adjustment delta
    function _processPositionFees(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        Currency currency0,
        Currency currency1,
        bool isMMPosition
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
        int256 selfNet0 = pa.netSettlementSinceLastMod0;
        int256 selfNet1 = pa.netSettlementSinceLastMod1;

        // Queue bonuses using positive nets since last modification
        for (uint8 t = 0; t < 2; t++) {
            int256 selfNet = (t == 0) ? selfNet0 : selfNet1;
            if (selfNet <= 0) continue;

            uint256 pot = t == 0
                ? paPool.protocolFeeAccrued0
                : paPool.protocolFeeAccrued1;
            uint256 selfContrib = t == 0 ? pa.feesShared0 : pa.feesShared1;
            uint256 potAvail = pot > selfContrib ? (pot - selfContrib) : 0;
            if (potAvail == 0) continue;

            uint256 totalNetBefore = t == 0
                ? paPool.poolNetSinceLastMod0
                : paPool.poolNetSinceLastMod1;
            // totalNetBefore is UNSIGNED. Only positive when settled > 0 - preventing positive nets that cover deficits from being used
            if (totalNetBefore == 0) continue;

            // Dust guard
            if (uint256(selfNet) < 1e12) continue;

            uint256 bonus = FullMath.mulDiv(
                potAvail,
                uint256(selfNet),
                totalNetBefore
            );
            if (bonus > potAvail) bonus = potAvail;

            // Deduct from pot, keep self-contrib excluded
            if (t == 0) {
                paPool.protocolFeeAccrued0 = potAvail - bonus + selfContrib;
                // Queue negative pending (bonus increases payout at materialisation)
                pa.pendingFeeAdj0 -= bonus.toInt256();
            } else {
                paPool.protocolFeeAccrued1 = potAvail - bonus + selfContrib;
                pa.pendingFeeAdj1 -= bonus.toInt256();
            }
        }

        // After allocation, zero/decrement nets so future allocations don't double-count
        if (selfNet0 != 0) {
            pa.netSettlementSinceLastMod0 = 0;
            if (selfNet0 > 0) {
                uint256 cur0 = paPool.poolNetSinceLastMod0;
                uint256 dec0 = uint256(selfNet0);
                paPool.poolNetSinceLastMod0 = dec0 > cur0 ? 0 : (cur0 - dec0);
            }
        }
        if (selfNet1 != 0) {
            pa.netSettlementSinceLastMod1 = 0;
            if (selfNet1 > 0) {
                uint256 cur1 = paPool.poolNetSinceLastMod1;
                uint256 dec1 = uint256(selfNet1);
                paPool.poolNetSinceLastMod1 = dec1 > cur1 ? 0 : (cur1 - dec1);
            }
        }

        return
            _finaliseFeeAdjustment(
                s,
                poolManager,
                positionId,
                poolId,
                currency0,
                currency1,
                isMMPosition
            );
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
            uint256 deltaG = FullMath.mulDiv(
                coveredAmount,
                FixedPoint128.Q128,
                uint256(liq)
            );
            if (tokenIndex == 0) {
                paPool.coverageUseGrowthGlobal0 += deltaG;
            } else {
                paPool.coverageUseGrowthGlobal1 += deltaG;
            }
        } else {
            // No in-range liquidity; defer to residual
            if (tokenIndex == 0) {
                paPool.coverageResidual0 += coveredAmount;
            } else {
                paPool.coverageResidual1 += coveredAmount;
            }
        }
    }
}
