// SPDX-License-Identifier: MIT
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
import {Errors} from "./Errors.sol";
import {VTSFeeLib} from "./VTSFeeLib.sol";
import {DynamicCurrencyDelta} from "./DynamicCurrencyDelta.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";

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

    // Maximum positive magnitude representable in int128
    uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;

    // --------------------------------------------------
    // Commitment Tracking
    // --------------------------------------------------

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

    // --------------------------------------------------
    // Settlement Updates
    // --------------------------------------------------

    /// @notice Updates the settlement amount by a delta which could be positive or negative
    /// @param s The central VTS storage
    /// @param id The position id
    /// @param tokenIndex The token index (0 or 1)
    /// @param delta The delta of the settlement
    /// @return applied The applied delta to the total settlement amount
    function _updateSettlement(VTSStorage storage s, PositionId id, uint8 tokenIndex, int256 delta)
        internal
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
        internal
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
    function _settlePositionInflowGrowth(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) internal {
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
    ) internal returns (uint256 fees, uint256 ofDelta) {
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
    ) internal {
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

    /// @notice Settle coverage-usage growth and burn fees only on exercised deficits
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function _settleCoverageUsage(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) internal {
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

    /// @notice Settle both deficit, inflow, and coverage growth for a position
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position ID
    function settlePositionGrowths(VTSStorage storage s, IPoolManager poolManager, PositionId positionId) public {
        _settlePositionDeficitGrowth(s, poolManager, positionId);
        _settlePositionInflowGrowth(s, poolManager, positionId);
        _settleCoverageUsage(s, poolManager, positionId);
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
    ) internal {
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

    /**
     * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
     * @param s The central VTS storage
     * @param poolManager The pool manager contract
     * @param id The id of the position
     */
    function _initPositionSnapshots(VTSStorage storage s, IPoolManager poolManager, PositionId id) internal {
        Position memory pos = s.positions[id];
        PoolId p = pos.poolId;
        PoolAccounting storage paPool = s.poolAccounting[p];
        PositionAccounting storage pa = s.positionAccounting[id];

        // Deficit growth snapshot
        (uint256 d0, uint256 d1) = _growthInside(
            p,
            pos.tickLower,
            pos.tickUpper,
            paPool.deficitGrowthGlobal.token0,
            paPool.deficitGrowthGlobal.token1,
            s.deficitGrowthOutside
        );
        pa.deficitGrowthInsideLast.token0 = d0;
        pa.deficitGrowthInsideLast.token1 = d1;

        // Inflow growth snapshot
        (uint256 i0, uint256 i1) = _growthInside(
            p,
            pos.tickLower,
            pos.tickUpper,
            paPool.inflowGrowthGlobal.token0,
            paPool.inflowGrowthGlobal.token1,
            s.inflowGrowthOutside
        );
        pa.inflowGrowthInsideLast.token0 = i0;
        pa.inflowGrowthInsideLast.token1 = i1;

        // Fee growth snapshot
        (uint256 fg0, uint256 fg1) = StateLibrary.getFeeGrowthInside(poolManager, p, pos.tickLower, pos.tickUpper);
        pa.feeGrowthInsideLast.token0 = fg0;
        pa.feeGrowthInsideLast.token1 = fg1;

        // Coverage usage snapshot
        (uint256 cu0, uint256 cu1) = _growthInside(
            p,
            pos.tickLower,
            pos.tickUpper,
            paPool.coverageUseGrowthGlobal.token0,
            paPool.coverageUseGrowthGlobal.token1,
            s.coverageUseGrowthOutside
        );
        pa.coverageUseGrowthInsideLast.token0 = cu0;
        pa.coverageUseGrowthInsideLast.token1 = cu1;
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
    function touchPosition(
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
            _initPositionSnapshots(s, poolManager, id);
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
                    calcRFS(s, poolManager, id, true);
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
        feeAdj = VTSFeeLib.processPositionFees(s, poolManager, id, currency0, currency1);
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
        Position memory pos = s.positions[positionId];
        Pool memory pool = s.pools[pos.poolId];

        // Get commitments
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;

        // Get settled amounts and deficits
        uint256 s0 = pa.settled.token0;
        uint256 s1 = pa.settled.token1;
        uint256 d0 = pa.cumulativeDeficit.token0;
        uint256 d1 = pa.cumulativeDeficit.token1;

        // Base-required per token (commitment * baseVTSRate). RfS gates by max(deficitReq, baseReq)
        MarketVTSConfiguration memory cfg = pool.vtsConfig;
        (uint256 base0, uint256 base1) =
            LiquidityUtils.getBaseSettlementAmounts(c0, c1, cfg.token0.baseVTSRate, cfg.token1.baseVTSRate);

        // Cap deficits by commitment
        uint256 defReq0 = d0 < c0 ? d0 : c0;
        uint256 defReq1 = d1 < c1 ? d1 : c1;

        // Gate by base: require at least base amounts even without deficit
        uint256 req0 = base0 > defReq0 ? base0 : defReq0;
        uint256 req1 = base1 > defReq1 ? base1 : defReq1;

        // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
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

    /// @notice Gets the current VTS for a position
    /// @param s The central VTS storage
    /// @param positionId The position id
    /// @return vtsCurrent0 The current VTS for token0
    /// @return vtsCurrent1 The current VTS for token1
    function getVTSCurrent(VTSStorage storage s, PositionId positionId)
        public
        view
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;
        uint256 s0 = pa.settled.token0;
        uint256 s1 = pa.settled.token1;

        uint256 v0 = c0 > 0 ? FullMath.mulDiv(s0, LiquidityUtils.ONE_WAD, c0) : 0;
        uint256 v1 = c1 > 0 ? FullMath.mulDiv(s1, LiquidityUtils.ONE_WAD, c1) : 0;
        return (v0, v1);
    }

    /// @notice Gets the required VTS for a position
    /// @param s The central VTS storage
    /// @param positionId The position id
    /// @return vtsRequired0 The required VTS for token0 (1e18 scale)
    /// @return vtsRequired1 The required VTS for token1 (1e18 scale)
    function getVTSRequired(VTSStorage storage s, PositionId positionId)
        public
        view
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;
        uint256 d0 = pa.cumulativeDeficit.token0;
        uint256 d1 = pa.cumulativeDeficit.token1;
        vtsRequired0 =
            c0 == 0 ? 0 : (d0 >= c0 ? LiquidityUtils.ONE_WAD : FullMath.mulDiv(d0, LiquidityUtils.ONE_WAD, c0));
        vtsRequired1 =
            c1 == 0 ? 0 : (d1 >= c1 ? LiquidityUtils.ONE_WAD : FullMath.mulDiv(d1, LiquidityUtils.ONE_WAD, c1));
    }

    // --------------------------------------------------
    // Settlement Functions (from VTSSettleLib)
    // --------------------------------------------------

    /// @notice Core settlement entrypoint for MM-managed positions
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position id
    /// @param lccCurrency0 The pool currency of the LCC token for token0
    /// @param lccCurrency1 The pool currency of the LCC token for token1
    /// @param delta The balance delta of the settlement
    /// @param isSeizing Whether the position is being seized
    /// @param mmPositionManager The MM Position Manager address (to read deltas from)
    /// @return settlementDelta The delta actually applied to underlying
    /// @return rfsOpen Whether the RFS is open for the position
    /// @return seizedLiquidityUnits The amount of liquidity units seized (non-zero only when seizing)
    function onMMSettle(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing,
        address mmPositionManager
    ) public returns (BalanceDelta settlementDelta, bool rfsOpen, uint256 seizedLiquidityUnits) {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        // Validate position exists (commitmentMax > 0 for active positions)
        PositionAccounting storage pa = s.positionAccounting[positionId];
        if (pos.owner == address(0)) {
            revert("VTSPositionLib: Invalid position");
        }

        // Read position required settlement delta from currencyDelta (set by _touchPosition via DynamicCurrencyDelta)
        BalanceDelta positionRequiredSettlementDelta =
            DynamicCurrencyDelta.getUnderlyingSettlementDelta(mmPositionManager, lccCurrency0, lccCurrency1);

        // During withdrawals, delta is positive as per caller context. During deposits, delta is negative.
        // However, _updateSettlement accepts the inverse as a delta of the settled amount.
        // Ie. positive increases, and negative decreases the metric.
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());

        // Settle growths and get RFS state
        BalanceDelta rfsDelta;
        settlePositionGrowths(s, poolManager, positionId);
        (rfsOpen, rfsDelta) = getRFS(s, positionId);

        // Handle settlement based on position state
        if (!pos.isActive) {
            // Inactive: unrestricted deposits/settlements
            if (amount0 != 0) {
                amount0 = _updateSettlement(s, positionId, 0, -amount0);
            }
            if (amount1 != 0) {
                amount1 = _updateSettlement(s, positionId, 1, -amount1);
            }
        } else if (isSeizing) {
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
                if (rfs0 > 0) {
                    int128 maxDeposit0 = -rfs0; // negative because deposits are negative
                    if (amount0 < maxDeposit0) {
                        amount0 = maxDeposit0;
                    }
                }
                amount0 = _updateSettlement(s, positionId, 0, -amount0);
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
                if (rfs1 > 0) {
                    int128 maxDeposit1 = -rfs1; // negative because deposits are negative
                    if (amount1 < maxDeposit1) {
                        amount1 = maxDeposit1;
                    }
                }
                amount1 = _updateSettlement(s, positionId, 1, -amount1);
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
        } else {
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
        }

        // Clamps within _updateSettlement may modify the return delta. Flip the signs on amount0 and amount1 to match caller-context delta.
        settlementDelta = LiquidityUtils.negateBalanceDelta(toBalanceDelta(amount0.toInt128(), amount1.toInt128()));

        // Calculate seized liquidity units when seizing
        if (isSeizing) {
            seizedLiquidityUnits = _calcSeizure(s, poolManager, positionId, settlementDelta);
        } else {
            seizedLiquidityUnits = 0;
        }

        // Proactive extraction (incremental): fund only increases in pending slashes since last observation to avoid over-funding
        VTSFeeLib.proactiveFunding(s, poolManager, poolId, positionId, lccCurrency0, lccCurrency1);
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

        Position memory pos = s.positions[positionId];
        (bool rfsOpen, BalanceDelta rfsDelta) = getRFS(s, positionId);
        if (!rfsOpen) {
            revert("VTSPositionLib: RFS not open");
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        Pool memory pool = s.pools[pos.poolId];

        // Commitments and RfS amounts
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;
        uint256 r0 = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0());
        uint256 r1 = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1());
        uint256 s0 = LiquidityUtils.safeInt128ToUint256(settlementDelta.amount0());
        uint256 s1 = LiquidityUtils.safeInt128ToUint256(settlementDelta.amount1());

        MarketVTSConfiguration memory cfg = pool.vtsConfig;

        // 1) Base exposures (RfS/commitment, floored by VTS_base)
        uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
        uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
        if (cfg.token0.baseVTSRate > e0bps) {
            e0bps = cfg.token0.baseVTSRate;
        }
        if (cfg.token1.baseVTSRate > e1bps) {
            e1bps = cfg.token1.baseVTSRate;
        }

        // 2) Determine a portion of the seizure exposure proportional to settled / RfS amount
        uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
        uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);

        // 3) Calculate seized liquidity units based on exposure / commitment sized by settlement
        uint256 liq = uint256(pos.liquidity);
        uint256 u0 = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps);
        uint256 u1 = LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);

        // 4) Cap at full position liquidity and apply residual threshold
        uint256 total = u0 + u1;

        // Apply residual threshold: if remaining liquidity would be below minResidualUnits, fully close the position
        uint256 minResidual = cfg.minResidualUnits == 0 ? 1 : cfg.minResidualUnits;
        if (total < liq) {
            if ((liq - total) < minResidual) {
                total = liq;
            }
        } else if (total > liq) {
            // Final clamp to ensure we don't exceed position liquidity
            total = liq;
        }

        return total;
    }

    /// @notice Unwrap LCC to underlying asset
    /// @param lcc The LCC token
    /// @param liquidityHub The liquidity hub
    /// @param from The address to unwrap from
    /// @param to The recipient address
    /// @param requested The requested amount to unwrap
    /// @param availableCredit The available credit from deltas
    /// @return unwrapped The amount actually unwrapped
    /// @return underlying The underlying token address
    function unwrapLCC(
        ILCC lcc,
        ILiquidityHub liquidityHub,
        address from,
        address to,
        uint256 requested,
        uint256 availableCredit
    ) public returns (uint256 unwrapped, address underlying) {
        // unwrap the lcc from the position
        underlying = lcc.underlying();

        // Measure recipient underlying balance before unwrap
        uint256 beforeBal = IERC20Minimal(underlying).balanceOf(to);

        uint256 toUnwrap;

        if (requested == 0) {
            // Unwrap from deltas: use available credit from this contract's deltas
            toUnwrap = availableCredit; // Unwrap all available deltas
        } else {
            // Unwrap from caller's wallet: transfer LCC from caller to this contract first
            toUnwrap = requested;
        }

        if (toUnwrap > 0) {
            // Route unwrap via LiquidityHub to leverage reserve tracking and settlement queuing
            if (from != address(this)) {
                lcc.transferFrom(from, address(this), toUnwrap);
            }
            liquidityHub.unwrapTo(address(lcc), to, toUnwrap);
        }

        // Compute actually unwrapped by observing recipient balance delta
        unwrapped = IERC20Minimal(underlying).balanceOf(to) - beforeBal;
    }
}
