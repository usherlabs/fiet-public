// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PositionIndex} from "../modules/PositionIndex.sol";
import {PositionMeta} from "../types/Position.sol";
import {GrowthAccounting} from "../libraries/GrowthAccounting.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCastLib} from "solmate/utils/SafeCastLib.sol";
import {PositionLibrary, PositionId} from "../types/Position.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast as OZSafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";

abstract contract VTSManager is IVTSManager, PositionIndex {
    using SafeCastLib for *;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Mapping from core pool ID to VTS configuration
    mapping(PoolId => MarketVTSConfiguration) public corePoolToVTSConfiguration;
    // Event ring/outflow tracking removed in favour of deficit growth accounting
    // Mapping to store maximum potential commitment for each position
    mapping(PositionId => uint256[2]) internal commitmentMaxima;
    // Mapping to store the total settlement amount for each position
    mapping(PositionId => uint256[2]) internal totalSettlementAmount;
    // Deficit growth accounting (Uniswap v3-style growth per liquidity unit, Q128)
    // Maximum positive magnitude representable in int128
    uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
    // Per-market (pool) global deficit growth per token (token0, token1)
    mapping(PoolId => uint256[2]) internal deficitGrowthGlobal;
    // Per-market per-tick outside deficit growth per token
    mapping(PoolId => mapping(int24 => uint256[2])) internal deficitGrowthOutside;
    // Per-position last inside deficit growth snapshot per token
    mapping(PositionId => uint256[2]) internal deficitGrowthInsideLast;
    // Per-position cumulative deficit (in raw token units)
    mapping(PositionId => uint256[2]) internal cumulativeDeficit;

    // Inflow growth accounting (mirrors deficit growth; Uniswap v3-style growth per liquidity unit, Q128)
    // Per-market (pool) global inflow growth per token (token0, token1)
    mapping(PoolId => uint256[2]) internal inflowGrowthGlobal;
    // Per-market per-tick outside inflow growth per token
    mapping(PoolId => mapping(int24 => uint256[2])) internal inflowGrowthOutside;
    // Per-position last inside inflow growth snapshot per token
    mapping(PositionId => uint256[2]) internal inflowGrowthInsideLast;

    // Protocol coverage & fee sharing accounting
    // Total protocol-covered unwraps (net of proactive pool usage)
    mapping(PoolId => uint256[2]) public protocolCoverage;
    // Sum of all position cumulative deficits per market/token
    mapping(PoolId => uint256[2]) public globalDeficit;
    // Protocol/LPs fee pot accrued from fee sharing (per token index)
    mapping(PoolId => uint256[2]) public protocolFeeAccrued;
    // Per-position last inside fee growth snapshot per token (for fee sharing)
    mapping(PositionId => uint256[2]) internal feeGrowthInsideLast;
    // Per-position cumulative attributed outflows (raw units), per token
    mapping(PositionId => uint256[2]) internal cumulativeOutflows;
    // Per-position outflow snapshot taken when feeGrowthInsideLast is checkpointed, per token
    mapping(PositionId => uint256[2]) internal outflowsAtFeeSnap;

    // Proactive liquidity accounting (tick-indexed, Q128 per-liquidity growth)
    // Proactive excess credited while in-range, accumulates in pool-wide storage.
    mapping(PoolId => uint256[2]) internal proactiveExcessGrowthGlobal;
    // Proactive usage consumed at unwrap while in-range
    mapping(PoolId => uint256[2]) internal proactiveUseGrowthGlobal;
    mapping(PoolId => mapping(int24 => uint256[2])) internal proactiveUseGrowthOutside;
    mapping(PositionId => uint256[2]) internal proactiveUseGrowthInsideLast;
    // Per-position accumulated obligation arising from proactive usage attribution
    mapping(PositionId => uint256[2]) internal proactiveObligation;

    // Inverted fee-pot growth accounting over proactively settled backing units
    mapping(PoolId => uint256[2]) internal feePotGrowthGlobal;
    mapping(PoolId => mapping(int24 => uint256[2])) internal feePotGrowthOutside;
    mapping(PositionId => uint256[2]) internal feePotGrowthInsideLast;
    mapping(PositionId => uint256[2]) internal feePotGlobalLast;
    // Per-position settled baseline (claimable tally)
    mapping(PositionId => uint256[2]) internal feePotBaseline;
    // Pool-wide sum of coverage units (per token)
    mapping(PoolId => uint256[2]) internal totalCoverageUnits;
    // Per-position last cached coverage units
    mapping(PositionId => uint256[2]) internal lastCoverageUnits;

    error InvalidMarketVTSConfiguration(PoolId corePoolId);
    error NotEnoughSettlementBalance(PositionId id, uint8 tokenIndex, uint256 currentAmount, uint256 attemptedAmount);
    error InvalidPosition(PositionId positionId);
    error RFSOpenForPosition(PositionId positionId);

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event MarketVTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    event FeeShareHandled(
        PoolId indexed poolId, PositionId indexed positionId, uint8 indexed tokenIndex, uint256 share, uint256 growthInc
    );
    event MMPositionLiquidityUpdated(
        PoolId indexed poolId, PositionId indexed positionId, int128 amount0, int128 amount1
    );
    event ProactiveCredited(PoolId indexed poolId, uint8 indexed tokenIndex, uint256 amount, int24 tick);
    event ProactiveUsed(PoolId indexed poolId, uint8 indexed tokenIndex, uint256 used, uint256 residual);

    address private immutable mmPositionManager;
    IPoolManager private immutable poolManager;
    address private calculator; // optional external calculator (Stylus or pure)

    modifier onlyPositionValid(PositionId _positionId) {
        if (!isPositionValid(_positionId, true)) {
            revert InvalidPosition(_positionId);
        }
        if (commitmentMaxima[_positionId][0] == 0 || commitmentMaxima[_positionId][1] == 0) {
            revert InvalidPosition(_positionId);
        }
        _;
    }

    modifier onlyMMPosition(PositionId _positionId) {
        if (!_isCallerMMP(msg.sender) || !_isMMPosition(_positionId)) {
            revert InvalidCaller();
        }
        _;
    }

    constructor(address _poolManager, address _marketFactory, address _mmPositionManager, address _calculator)
        PositionIndex(_marketFactory)
    {
        poolManager = IPoolManager(_poolManager);
        mmPositionManager = _mmPositionManager;
        if (_calculator != address(0)) {
            // calculator = IVTSCalculator(_calculator);
            calculator = _calculator;
        }
    }

    /**
     * @notice Sets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @param vtsConfiguration The VTS configuration
     */
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        public
        override
        onlyMarketFactory
    {
        corePoolToVTSConfiguration[corePoolId] = vtsConfiguration;

        emit MarketVTSConfigurationSet(corePoolId, vtsConfiguration);
    }

    function getPositionSettledAmounts(PositionId positionId)
        public
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        return (totalSettlementAmount[positionId][0], totalSettlementAmount[positionId][1]);
    }

    /**
     * @notice Gets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @return The VTS configuration
     */
    function getMarketVTSConfiguration(PoolId corePoolId)
        public
        view
        override
        returns (MarketVTSConfiguration memory)
    {
        return corePoolToVTSConfiguration[corePoolId];
    }

    /**
     * @notice Checks if the caller is the MM Position Manager
     * @return True if the caller is the MM Position Manager, false otherwise
     */
    function _isCallerMMP(address caller) internal view returns (bool) {
        return caller == mmPositionManager;
    }

    /**
     * @notice Checks if a position is a DirectLP - all positions not owned by the MM Position Manager are DirectLPs - ie. handled natively, or by third-party contracts.
     * @param positionId The id of the position
     * @return True if the position is a DirectLP, false otherwise
     */
    function _isMMPosition(PositionId positionId) internal view returns (bool) {
        return meta[positionId].owner == mmPositionManager;
    }

    /**
     * @notice Touches a position, registers it if it doesn't exist, updates it if it does, and tracks the commitment
     * @param owner The owner of the position - ie. the Smart Contract managing positions.
     * @param poolId The pool id
     * @param params The parameters of the transaction
     */
    function _touchPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) internal virtual {
        PositionId id = PositionLibrary.generateId(owner, params);
        PositionMeta memory m = meta[id];
        if (m.owner == address(0)) {
            // new position, initialize the liquidity to the liquidity delta, assuming it will always be positive
            _registerPosition(owner, poolId, params);
            _initPositionSnapshots(id);
        } else if (m.isActive == true) {
            // existing position, update the liquidity by the liquidity delta
            int256 newLiquidity = meta[id].liquidity += params.liquidityDelta;
            if (newLiquidity < 0) {
                // this should never happen in theory but check is performed to be safe since it is a uint256 and a position musst not have a negative liquidity
                // revert InvalidLiquidityDelta(newLiquidity);
                meta[id].liquidity = 0;
            } else {
                meta[id].liquidity = newLiquidity;
            }
        } else {
            revert NotActive(id);
        }
        uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(id));
        if (liq == 0) {
            meta[id].isActive = false;
        } else {
            meta[id].isActive = true;
        }

        _trackCommitment(id, params);
    }

    /**
     * @notice Initializes the snapshots for a position. Prevents new positions from inheriting historical tick-indexed growths.
     * @param id The id of the position
     */
    function _initPositionSnapshots(PositionId id) internal {
        PositionMeta memory m = meta[id];
        PoolId p = m.poolId;

        (uint256 d0, uint256 d1) =
            GrowthAccounting.inside(deficitGrowthGlobal, deficitGrowthOutside, p, m.tickLower, m.tickUpper);
        deficitGrowthInsideLast[id][0] = d0;
        deficitGrowthInsideLast[id][1] = d1;

        (uint256 i0, uint256 i1) =
            GrowthAccounting.inside(inflowGrowthGlobal, inflowGrowthOutside, p, m.tickLower, m.tickUpper);
        inflowGrowthInsideLast[id][0] = i0;
        inflowGrowthInsideLast[id][1] = i1;

        (uint256 u0, uint256 u1) =
            GrowthAccounting.inside(proactiveUseGrowthGlobal, proactiveUseGrowthOutside, p, m.tickLower, m.tickUpper);
        proactiveUseGrowthInsideLast[id][0] = u0;
        proactiveUseGrowthInsideLast[id][1] = u1;

        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthInside(p, m.tickLower, m.tickUpper);
        feeGrowthInsideLast[id][0] = fg0;
        feeGrowthInsideLast[id][1] = fg1;

        (uint256 fp0, uint256 fp1) =
            GrowthAccounting.inside(feePotGrowthGlobal, feePotGrowthOutside, p, m.tickLower, m.tickUpper);
        feePotGrowthInsideLast[id][0] = fp0;
        feePotGrowthInsideLast[id][1] = fp1;
        feePotGlobalLast[id][0] = feePotGrowthGlobal[p][0];
        feePotGlobalLast[id][1] = feePotGrowthGlobal[p][1];

        lastCoverageUnits[id][0] = _coverageUnits(id, 0);
        lastCoverageUnits[id][1] = _coverageUnits(id, 1);
    }

    /**
     * @notice Tracks the maximum potential commitment for both tokens in a position
     * @param positionId The ascribed id of the position
     * @param params The parameters of the transaction
     */
    function _trackCommitment(PositionId positionId, ModifyLiquidityParams calldata params) internal {
        // Current tracked maxima for this position
        uint256 currentC0 = commitmentMaxima[positionId][0];
        uint256 currentC1 = commitmentMaxima[positionId][1];

        PoolId pId = meta[positionId].poolId;

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            uint128 liquidityAdded = SafeCastLib.safeCastTo128(uint256(params.liquidityDelta));
            (uint256 addC0, uint256 addC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            commitmentMaxima[positionId][0] = currentC0 + addC0;
            commitmentMaxima[positionId][1] = currentC1 + addC1;
            _refreshCoverageUnits(positionId, pId, 0);
            _refreshCoverageUnits(positionId, pId, 1);
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = SafeCastLib.safeCastTo128(uint256(-params.liquidityDelta));
            (uint256 subC0, uint256 subC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            commitmentMaxima[positionId][0] = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            commitmentMaxima[positionId][1] = currentC1 > subC1 ? (currentC1 - subC1) : 0;
            _refreshCoverageUnits(positionId, pId, 0);
            _refreshCoverageUnits(positionId, pId, 1);
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    /**
     * @notice Records the settlement of assets on a position
     * @dev make sure this function can only be called by the position manager since that is the interface through which settlements are going to be made
     * @param positionId The id of the position
     * @param modifyDelta The balance delta of the settlement
     */
    function onMMLiquidityModify(PositionId positionId, BalanceDelta modifyDelta)
        external
        onlyMMPosition(positionId)
        onlyPositionValid(positionId)
        returns (BalanceDelta)
    {
        // First, settle both growths since last touch
        _settlePositionGrowths(positionId);
        // Auto-redeem fee pot to settlement credits BEFORE deriving defaults and RfS,
        // so newly allocated fees are available to this operation
        _redeemFeePot(positionId, false);

        PoolId poolId = meta[positionId].poolId;
        int128 amount0 = modifyDelta.amount0();
        int128 amount1 = modifyDelta.amount1();

        if (amount0 == 0 && amount1 == 0) {
            (uint256 s0, uint256 s1) = getPositionSettledAmounts(positionId);
            // Default to withdraw the total amount settled
            amount0 = -OZSafeCast.toInt128(OZSafeCast.toInt256(s0));
            amount1 = -OZSafeCast.toInt128(OZSafeCast.toInt256(s1));
        }

        BalanceDelta returnDelta = toBalanceDelta(amount0, amount1);

        bool rfsOpen;
        BalanceDelta rfsDelta;
        if (amount0 < 0 || amount1 < 0) {
            // validate that there is no open RFS for this position
            // positions settled above, therefore _getRFS
            (rfsOpen, rfsDelta) = _getRFS(positionId); // second param is true to revert if RFS is open
            if (rfsOpen) {
                revert RFSOpenForPosition(positionId);
            }
        }

        // NOTE: Only apply explicit MM actions to totalSettlementAmount here.
        // - Positive amounts: add only proactive excess (portion not used to extinguish deficit).
        // - Negative amounts: first calc RfS, and then apply the withdrawal.
        if (amount0 > 0) {
            _handleMMSettlementForToken(positionId, poolId, 0, OZSafeCast.toUint256(int256(amount0)));
        } else if (amount0 < 0) {
            // Validate that amount to be withdrawn is within limits
            if (amount0 < rfsDelta.amount0()) {
                revert NotEnoughSettlementBalance(
                    positionId,
                    0,
                    LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0()),
                    LiquidityUtils.safeInt128ToUint256(amount0)
                );
            }
            _updateSettlement(poolId, positionId, 0, int256(amount0));
        }
        if (amount1 > 0) {
            _handleMMSettlementForToken(positionId, poolId, 1, OZSafeCast.toUint256(int256(amount1)));
        } else if (amount1 < 0) {
            if (amount1 < rfsDelta.amount1()) {
                revert NotEnoughSettlementBalance(
                    positionId,
                    1,
                    LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1()),
                    LiquidityUtils.safeInt128ToUint256(amount1)
                );
            }
            _updateSettlement(poolId, positionId, 1, int256(amount1));
        }

        emit MMPositionLiquidityUpdated(poolId, positionId, amount0, amount1);

        return returnDelta;
    }

    /**
     * @dev Called by LCC to increment unwrap coverage of the pool
     * @param poolId The pool id
     * @param amount The amount to increment the coverage by
     */
    function incrementCoverage(PoolId poolId, uint256 amount) external {
        uint8 tokenIndex = _getTokenIndexFromCaller(poolId); // ensures msg.sender is a valid LCC for the pool id.

        _incrementCoverage(poolId, tokenIndex, amount);
    }

    function _handleMMSettlementForToken(PositionId positionId, PoolId poolId, uint8 tokenIndex, uint256 settledAmount)
        internal
    {
        uint256 dBefore = cumulativeDeficit[positionId][tokenIndex];
        uint256 d = settledAmount >= dBefore ? dBefore : settledAmount; // extinguished deficit this tx
        // d computed as the minimum of the settled amount and the cumulative deficit for the position.
        // therefore, attribution is based on the deficit amount being covered in this transaction.

        if (d > 0) {
            cumulativeDeficit[positionId][tokenIndex] = dBefore - d;
            uint256 gD = globalDeficit[poolId][tokenIndex];
            uint256 pC = protocolCoverage[poolId][tokenIndex];
            if (gD > 0) {
                globalDeficit[poolId][tokenIndex] = gD - d;
                if (pC > 0) {
                    uint256 attributed = FullMath.mulDiv(d, pC, gD); // deficit / globalDeficit * protocolCoverage
                    protocolCoverage[poolId][tokenIndex] = pC - attributed;

                    uint256 bps = corePoolToVTSConfiguration[poolId].coverageFeeShare;
                    uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(positionId));
                    (uint256 fees, uint256 ofDelta) = _readFeesAndCheckpoint(positionId, poolId, tokenIndex, liq);
                    // Fees accrue continuously over time; deficits arise from outflows.
                    // To share “fees on the deficit amount exclusively,” normalise fees by the same window’s position-attributed outflows.
                    // New calc: share = fees * (attributed / outflowDelta) * coverageFeeShare_bps/10000, where:
                    // outflowDelta = cumulativeOutflows - outflowsAtFeeSnap (same checkpoint window as feeGrowth).
                    // This ties fee sharing to the outflow volume that generated the obligation, not just the settlement amount.
                    if (bps > 0 && fees > 0 && ofDelta > 0 && attributed > 0) {
                        uint256 share = FullMath.mulDiv(fees, attributed, ofDelta);
                        share = FullMath.mulDiv(share, bps, 10000);
                        if (share > 0 && share <= fees) {
                            uint256 growthInc = 0;
                            if (liq > 0) {
                                // The following is “burning” their claimable fees by advancing feeGrowthInsideLast by the share-equivalent growth.
                                // In Uniswap-style accounting, a position’s owed fees = (feeGrowthInside − feeGrowthInsideLast) × liquidity. By increasing feeGrowthInsideLast by share/Q128/liquidity, we reduce their future fee delta exactly by share.
                                growthInc = FullMath.mulDiv(share, FixedPoint128.Q128, liq);
                                feeGrowthInsideLast[positionId][tokenIndex] += growthInc;
                            }
                            // The “value” of the share is accrued to protocolFeeAccrued[...], so the MM loses that amount and the protocol/other LPs gain it.
                            protocolFeeAccrued[poolId][tokenIndex] += share; // utilised to clamp fee claims

                            // Inverted fee-pot growth: accrue per backing unit
                            uint256 denom = totalCoverageUnits[poolId][tokenIndex];
                            if (denom > 0) {
                                uint256 dG = FullMath.mulDiv(share, FixedPoint128.Q128, denom);
                                feePotGrowthGlobal[poolId][tokenIndex] += dG;
                            }

                            emit FeeShareHandled(poolId, positionId, tokenIndex, share, growthInc);
                        }
                    }
                }
            }
        }

        uint256 proactive = settledAmount - d;
        if (proactive > 0) {
            _updateSettlement(poolId, positionId, tokenIndex, int256(proactive));
            // Credit proactive excess only if in-range at settlement
            (, int24 tick,,) = poolManager.getSlot0(poolId);
            PositionMeta memory m = meta[positionId];
            bool inRange = (tick >= m.tickLower && tick < m.tickUpper);
            if (inRange) {
                _accrueProactiveExcessGrowth(poolId, tokenIndex, proactive);
                emit ProactiveCredited(poolId, tokenIndex, proactive, tick);
            }
        }
    }

    /// @dev Reads fees since last snapshot and checkpoints fee growth and outflow snapshots atomically.
    function _readFeesAndCheckpoint(PositionId positionId, PoolId poolId, uint8 tokenIndex, uint128 positionLiquidity)
        internal
        returns (uint256 fees, uint256 ofDelta)
    {
        PositionMeta memory m = meta[positionId];
        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthInside(poolId, m.tickLower, m.tickUpper);
        uint256 fg = tokenIndex == 0 ? fg0 : fg1;
        uint256 last = feeGrowthInsideLast[positionId][tokenIndex];
        if (positionLiquidity > 0 && fg > last) {
            fees = FullMath.mulDiv(fg - last, positionLiquidity, FixedPoint128.Q128);
        } else {
            fees = 0;
        }
        // compute outflow window and checkpoint both snapshots
        uint256 cf = cumulativeOutflows[positionId][tokenIndex];
        uint256 snap = outflowsAtFeeSnap[positionId][tokenIndex];
        ofDelta = cf >= snap ? (cf - snap) : 0;
        feeGrowthInsideLast[positionId][tokenIndex] = fg; // snapshot fees here.
        outflowsAtFeeSnap[positionId][tokenIndex] = cf;
    }

    /// @dev Internal helper to settle both deficit and inflow growth for a position
    function _settlePositionGrowths(PositionId positionId) internal {
        _settlePositionDeficitGrowth(positionId);
        _settlePositionInflowGrowth(positionId);
        _settlePositionProactiveUseGrowth(positionId);
        _settleFeePotGrowth(positionId);
    }

    /// @dev Settle inverted fee-pot growth for a position into feePotBaseline
    function _settleFeePotGrowth(PositionId id) internal {
        PositionMeta memory m = meta[id];
        PoolId p = m.poolId;

        uint256 in0 = 0;
        uint256 in1 = 0;

        // DirectLPs always eligible (no inside exclusion), where as MMs are conditionally eligible.
        if (_isMMPosition(id)) {
            (in0, in1) = GrowthAccounting.inside(feePotGrowthGlobal, feePotGrowthOutside, p, m.tickLower, m.tickUpper);
        }

        uint256 g0 = feePotGrowthGlobal[p][0];
        uint256 g1 = feePotGrowthGlobal[p][1];

        uint256 lastIn0 = feePotGrowthInsideLast[id][0];
        uint256 lastIn1 = feePotGrowthInsideLast[id][1];
        uint256 lastG0 = feePotGlobalLast[id][0];
        uint256 lastG1 = feePotGlobalLast[id][1];

        uint256 dIn0 = in0 >= lastIn0 ? in0 - lastIn0 : 0;
        uint256 dIn1 = in1 >= lastIn1 ? in1 - lastIn1 : 0;
        uint256 dG0 = g0 >= lastG0 ? g0 - lastG0 : 0;
        uint256 dG1 = g1 >= lastG1 ? g1 - lastG1 : 0;

        uint256 out0 = dG0 > dIn0 ? dG0 - dIn0 : 0;
        uint256 out1 = dG1 > dIn1 ? dG1 - dIn1 : 0;

        uint256 u0 = _coverageUnits(id, 0);
        uint256 u1 = _coverageUnits(id, 1);

        if (out0 > 0 && u0 > 0) {
            feePotBaseline[id][0] += FullMath.mulDiv(out0, u0, FixedPoint128.Q128);
        }
        if (out1 > 0 && u1 > 0) {
            feePotBaseline[id][1] += FullMath.mulDiv(out1, u1, FixedPoint128.Q128);
        }

        feePotGrowthInsideLast[id][0] = in0;
        feePotGrowthInsideLast[id][1] = in1;
        feePotGlobalLast[id][0] = g0;
        feePotGlobalLast[id][1] = g1;
    }

    /// @dev Increment protocol or proactive excess liquidity coverage on unwrap, consuming proactive pool first
    function _incrementCoverage(PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) internal {
        if (tokenIndex > 1 || coveredAmount == 0) return;
        // Use proactive availability based on current in-range liquidity
        uint128 liq = poolManager.getLiquidity(poolId);
        uint256 residual = coveredAmount;
        if (liq > 0) {
            uint256 gEx = proactiveExcessGrowthGlobal[poolId][tokenIndex];
            uint256 gUse = proactiveUseGrowthGlobal[poolId][tokenIndex];
            // Natural/inherited clamp: proactive usage is bounded by current in-range liquidity.
            // available = floor((excessGrowth - useGrowth) * L / Q128), so "use" is min(requested, available).
            // Any remainder after this in-range clamp is recorded as protocolCoverage (the unmet portion).
            uint256 available = 0;
            if (gEx > gUse) {
                available = FullMath.mulDiv(gEx - gUse, uint256(liq), FixedPoint128.Q128);
            }
            if (available > 0) {
                uint256 use = residual <= available ? residual : available;
                if (use > 0) {
                    // consume: add per-liquidity growth
                    uint256 deltaG = FullMath.mulDiv(use, FixedPoint128.Q128, uint256(liq));
                    proactiveUseGrowthGlobal[poolId][tokenIndex] = gUse + deltaG;
                    residual -= use;
                    emit ProactiveUsed(poolId, tokenIndex, use, residual);
                }
            }
        }
        if (residual > 0) {
            // Residual here is the post-clamp remainder (unmet by in-range proactive liquidity).
            protocolCoverage[poolId][tokenIndex] += residual;
        }
    }

    /**
     * @notice Internal redemption to settlement credit (used by MMs and external claim)
     * @param id The id of the position
     * @param forReturnDelta Whether the redemption is for return delta in the CoreHook. Default is false, meaning it's for MM withdrawals.
     * @return pay0 The amount of token0 to pay
     * @return pay1 The amount of token1 to pay
     */
    function _redeemFeePot(PositionId id, bool forReturnDelta) internal returns (uint256 pay0, uint256 pay1) {
        PoolId p = meta[id].poolId;
        pay0 = feePotBaseline[id][0];
        pay1 = feePotBaseline[id][1];

        if (pay0 > 0) {
            if (pay0 > protocolFeeAccrued[p][0]) pay0 = protocolFeeAccrued[p][0];
            if (pay0 > 0) {
                if (!forReturnDelta) {
                    _updateSettlement(p, id, 0, int256(pay0));
                }
                protocolFeeAccrued[p][0] -= pay0;
                feePotBaseline[id][0] -= pay0;
            }
        }
        if (pay1 > 0) {
            if (pay1 > protocolFeeAccrued[p][1]) pay1 = protocolFeeAccrued[p][1];
            if (pay1 > 0) {
                if (!forReturnDelta) {
                    _updateSettlement(p, id, 1, int256(pay1));
                }
                protocolFeeAccrued[p][1] -= pay1;
                feePotBaseline[id][1] -= pay1;
            }
        }
    }

    /// @notice Called by the hook on tick cross to flip outside growth for a tick
    function _onTickCross(PoolId corePoolId, int24 tick, uint8 token) internal {
        GrowthAccounting.flipOutside(deficitGrowthGlobal, deficitGrowthOutside, corePoolId, tick, token);
        GrowthAccounting.flipOutside(inflowGrowthGlobal, inflowGrowthOutside, corePoolId, tick, token);
        GrowthAccounting.flipOutside(proactiveUseGrowthGlobal, proactiveUseGrowthOutside, corePoolId, tick, token);
        // Flip fee-pot outside accumulator (inverted growth over backing units)
        GrowthAccounting.flipOutside(feePotGrowthGlobal, feePotGrowthOutside, corePoolId, tick, token);
    }

    /// @dev Accrue deficit growth to the global accumulator (per token) using current in-range liquidity
    function _accrueDeficitGrowth(PoolId corePoolId, uint8 token, uint256 deficitAmount) internal {
        uint128 liq = poolManager.getLiquidity(corePoolId);
        GrowthAccounting.accrue(deficitGrowthGlobal, corePoolId, token, deficitAmount, liq);
    }

    /// @dev Compute inside accumulator for a position bounds
    function _deficitGrowthInside(PoolId corePoolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 inside0, uint256 inside1)
    {
        return GrowthAccounting.inside(deficitGrowthGlobal, deficitGrowthOutside, corePoolId, tickLower, tickUpper);
    }

    /// @dev Settle deficit growth for a position into cumulativeDeficit in raw token units
    // get the previously snapshotted values gotten from _deficitGrowthInside
    // compare them with the current values and calculate the delta
    // get the fraction of the liquidity represented by delta
    // deduct it from user settled balance
    // if debt ensues, then we create the variable in the `cumulativeDeficit` variable
    function _settlePositionDeficitGrowth(PositionId positionId) internal {
        PositionMeta memory m = meta[positionId];
        PoolId corePoolId = m.poolId;
        // Use current position liquidity for scaling back to raw units
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        (uint256 add0, uint256 add1) = GrowthAccounting.deltaAndCheckpoint(
            deficitGrowthGlobal,
            deficitGrowthOutside,
            deficitGrowthInsideLast[positionId],
            corePoolId,
            m.tickLower,
            m.tickUpper,
            liq
        );
        if (add0 > 0) {
            // track full attributed outflows for fee sharing normalisation window
            cumulativeOutflows[positionId][0] += add0;

            // consume settled coverage first, then accrue shortfall to deficit
            // MM deficits account for liquidity no longer theirs. Settled liquidity must not include amounts that cover deficits. The counterparty token inflow amounts are accrued to the position's settled amounts to compensate.
            uint256 s0 = totalSettlementAmount[positionId][0];
            if (s0 >= add0) {
                _updateSettlement(corePoolId, positionId, 0, -(OZSafeCast.toInt256(add0))); // reduce total settlement amount by add0
            } else {
                uint256 netAdd0 = add0 - s0;
                cumulativeDeficit[positionId][0] += netAdd0;
                globalDeficit[corePoolId][0] += netAdd0;
                _updateSettlement(corePoolId, positionId, 0, -(OZSafeCast.toInt256(s0))); // set total settlement amount to 0
            }
        }
        if (add1 > 0) {
            cumulativeOutflows[positionId][1] += add1;

            uint256 s1 = totalSettlementAmount[positionId][1];
            if (s1 >= add1) {
                _updateSettlement(corePoolId, positionId, 1, -(OZSafeCast.toInt256(add1))); // reduce total settlement amount by add1
            } else {
                uint256 netAdd1 = add1 - s1;
                cumulativeDeficit[positionId][1] += netAdd1;
                globalDeficit[corePoolId][1] += netAdd1;
                _updateSettlement(corePoolId, positionId, 1, -(OZSafeCast.toInt256(s1))); // set total settlement amount to 0
            }
        }
    }

    /// @dev Accrue inflow growth to the global accumulator (per token) using current in-range liquidity
    ///      inflowAmount should be net of Uniswap LP/protocol fees (use no-fee input per segment)
    function _accrueInflowGrowth(PoolId corePoolId, uint8 token, uint256 inflowAmount) internal {
        uint128 liq = poolManager.getLiquidity(corePoolId);
        GrowthAccounting.accrue(inflowGrowthGlobal, corePoolId, token, inflowAmount, liq);
    }

    /// @dev Accrue proactive excess growth to global accumulator (per token)
    function _accrueProactiveExcessGrowth(PoolId corePoolId, uint8 token, uint256 proactiveAmount) internal {
        uint128 liq = poolManager.getLiquidity(corePoolId);
        GrowthAccounting.accrue(proactiveExcessGrowthGlobal, corePoolId, token, proactiveAmount, liq);
    }

    /// @dev Settle proactive use growth into per-position obligation
    function _settlePositionProactiveUseGrowth(PositionId positionId) internal {
        PositionMeta memory m = meta[positionId];
        PoolId corePoolId = m.poolId;
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        (uint256 add0, uint256 add1) = GrowthAccounting.deltaAndCheckpoint(
            proactiveUseGrowthGlobal,
            proactiveUseGrowthOutside,
            proactiveUseGrowthInsideLast[positionId],
            corePoolId,
            m.tickLower,
            m.tickUpper,
            liq
        );
        if (add0 > 0) {
            proactiveObligation[positionId][0] += add0;
        }
        if (add1 > 0) {
            proactiveObligation[positionId][1] += add1;
        }
    }

    /// @dev Compute inflow inside accumulator for a position bounds

    /// @dev Settle inflow growth for a position into totalSettlementAmount in raw token units
    function _settlePositionInflowGrowth(PositionId positionId) internal {
        PositionMeta memory m = meta[positionId];
        PoolId corePoolId = m.poolId;
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        (uint256 add0, uint256 add1) = GrowthAccounting.deltaAndCheckpoint(
            inflowGrowthGlobal,
            inflowGrowthOutside,
            inflowGrowthInsideLast[positionId],
            corePoolId,
            m.tickLower,
            m.tickUpper,
            liq
        );
        if (add0 > 0) {
            _updateSettlement(corePoolId, positionId, 0, int256(add0));
        }
        if (add1 > 0) {
            _updateSettlement(corePoolId, positionId, 1, int256(add1));
        }
    }

    /**
     * @notice Calculates the required vts for a position
     * @param positionId The position id
     * @return vtsRequired0 The required vts for token0 (1e18 scale)
     * @return vtsRequired1 The required vts for token1 (1e18 scale)
     */
    function calcVTSRequired(PositionId positionId)
        public
        onlyPositionValid(positionId)
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        _settlePositionGrowths(positionId);
        return _getVTSRequired(positionId);
    }

    /**
     * @notice Gets the required vts for a position using cumulative deficits
     * @param positionId The position id
     * @return vtsRequired0 The required vts for token0 (1e18 scale)
     * @return vtsRequired1 The required vts for token1 (1e18 scale)
     */
    function _getVTSRequired(PositionId positionId)
        internal
        view
        virtual
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        // If external calculator is configured, defer
        if (address(calculator) != address(0)) {
            return (0, 0);
        }
        (uint256 c0, uint256 c1) = _getCommitment(positionId);
        uint256 d0 = cumulativeDeficit[positionId][0];
        uint256 d1 = cumulativeDeficit[positionId][1];
        uint256 one = 1e18;
        vtsRequired0 = c0 == 0 ? 0 : (d0 >= c0 ? one : (d0 * one) / c0);
        vtsRequired1 = c1 == 0 ? 0 : (d1 >= c1 ? one : (d1 * one) / c1);
    }

    function getPositionUnsettledUSDValue(PoolId poolId, PositionId positionId) public view returns (uint256) {
        address[2] memory currencyPair = IMarketFactory(marketFactory).corePoolToCurrencyPair(poolId);
        address lcc0 = currencyPair[0];
        address lcc1 = currencyPair[1];
        // get the total usd value of all the commitments under this position
        // get the total usd value of all the settlements under this position
        // return the difference between the two

        (uint256 commitmentTotal0, uint256 commitmentTotal1) = _getCommitment(positionId);
        // get the total amount settled
        uint256 settlementTotal0 = totalSettlementAmount[positionId][0];
        uint256 settlementTotal1 = totalSettlementAmount[positionId][1];

        // the position's value is the commitments minus settlements
        uint256 unsettledAmount0 = commitmentTotal0 > settlementTotal0 ? commitmentTotal0 - settlementTotal0 : 0;
        uint256 unsettledAmount1 = commitmentTotal1 > settlementTotal1 ? commitmentTotal1 - settlementTotal1 : 0;

        // return the total usd value of the position
        (uint256 lcc0Price, uint256 price0Decimal) = ILCC(lcc0).usdPrice(address(0));
        (uint256 lcc1Price, uint256 price1Decimal) = ILCC(lcc1).usdPrice(address(0));

        uint256 totalLCCValue = ((lcc0Price * unsettledAmount0) / 10 ** price0Decimal)
            + ((lcc1Price * unsettledAmount1) / 10 ** price1Decimal);

        return totalLCCValue;
    }

    function calcVTSCurrent(PositionId positionId)
        public
        onlyPositionValid(positionId)
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        _settlePositionGrowths(positionId);
        return _getVTSCurrent(positionId);
    }

    /**
     * @notice Gets the current vts for a position
     * @param positionId The position id
     * @return vtsCurrent0 The current vts for token0
     * @return vtsCurrent1 The current vts for token1
     */
    function _getVTSCurrent(PositionId positionId)
        internal
        view
        virtual
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        uint256 c0 = commitmentMaxima[positionId][0];
        uint256 c1 = commitmentMaxima[positionId][1];

        uint256 s0 = totalSettlementAmount[positionId][0];
        uint256 s1 = totalSettlementAmount[positionId][1];

        uint256 one = 1e18;
        uint256 v0 = c0 > 0 ? FullMath.mulDiv(s0, one, c0) : 0;
        uint256 v1 = c1 > 0 ? FullMath.mulDiv(s1, one, c1) : 0;
        return (v0, v1);
    }

    /**
     * @notice Gets the commitment for a position
     * @param positionId The position id
     * @return commitment0 The commitment for token0
     * @return commitment1 The commitment for token1
     */
    function getCommitment(PositionId positionId)
        external
        view
        onlyPositionValid(positionId)
        returns (uint256 commitment0, uint256 commitment1)
    {
        return _getCommitment(positionId);
    }

    /**
     * @notice Gets the commitment for a position
     * @param positionId The position id
     * @return commitment0 The commitment for token0
     * @return commitment1 The commitment for token1
     */
    function _getCommitment(PositionId positionId)
        internal
        view
        virtual
        returns (uint256 commitment0, uint256 commitment1)
    {
        (uint256 c0, uint256 c1) = (commitmentMaxima[positionId][0], commitmentMaxima[positionId][1]);
        return (c0, c1);
    }

    /**
     * @notice Calculates the RFS for a position (settles growths and calls getRFS)
     * @param positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
     */
    function calcRFS(PositionId positionId, bool requireClosedRfS)
        public
        onlyPositionValid(positionId)
        returns (bool, BalanceDelta)
    {
        _settlePositionGrowths(positionId);
        (bool rfsOpen, BalanceDelta delta) = _getRFS(positionId);
        if (requireClosedRfS) {
            if (rfsOpen) {
                revert RFSOpenForPosition(positionId);
            }
        }
        return (rfsOpen, delta);
    }

    /**
     * @notice Gets the amount of assets that can be seized from a position using the linked library
     * @param _positionId The position id
     * @return siezureFractionBPS The amount of position that can be seized in bps
     */
    function getSeizureAmount(PositionId _positionId) public view virtual returns (uint256 siezureFractionBPS) {
        // TODO: derive the amount of assets that can be seized from a position
        _positionId;
        return 0;
    }

    /**
     * @notice Gets (view) the RFS for a position
     * @param _positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
     */
    function _getRFS(PositionId _positionId) internal view returns (bool, BalanceDelta) {
        // Commitment caps
        (uint256 c0, uint256 c1) = _getCommitment(_positionId);

        // If calculator is set, try calculator first (not implemented here)
        if (address(calculator) != address(0)) {
            return (false, toBalanceDelta(0, 0));
        }

        // Compute raw deltas directly in token units
        uint256 s0 = totalSettlementAmount[_positionId][0];
        uint256 s1 = totalSettlementAmount[_positionId][1];
        uint256 d0 = cumulativeDeficit[_positionId][0];
        uint256 d1 = cumulativeDeficit[_positionId][1];
        uint256 o0 = proactiveObligation[_positionId][0];
        uint256 o1 = proactiveObligation[_positionId][1];
        uint256 req0 = d0 < c0 ? d0 : c0; // cap deficit by commitment
        uint256 req1 = d1 < c1 ? d1 : c1;

        int128 amount0 = _rfsDeltaRaw(s0, req0, o0);
        int128 amount1 = _rfsDeltaRaw(s1, req1, o1);

        // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
        bool open = (amount0 > 0) || (amount1 > 0);
        return (open, toBalanceDelta(amount0, amount1));
    }

    /// @dev Return signed delta in raw units: positive => needs settlement, negative => withdrawable
    function _rfsDeltaRaw(uint256 settled, uint256 required, uint256 obligation) internal pure returns (int128) {
        uint256 need = required + obligation; // safe add (Solidity 0.8 checks overflow)
        if (need >= settled) {
            uint256 pos = need - settled; // requires settlement
            if (pos > INT128_MAX_U) return type(int128).max;
            return OZSafeCast.toInt128(int256(pos));
        }
        uint256 neg = settled - need; // withdrawable
        if (neg > INT128_MAX_U) return type(int128).min;
        int128 magnitude = OZSafeCast.toInt128(int256(neg));
        return -magnitude;
    }

    /**
     * @notice Updates the settlement amount by a delta which could be positive or negative
     * @param poolId The pool id
     * @param id The position id
     * @param tokenIndex The token index
     * @param delta The delta of the settlement
     */
    function _updateSettlement(PoolId poolId, PositionId id, uint8 tokenIndex, int256 delta) internal {
        uint256 cur = totalSettlementAmount[id][tokenIndex];
        uint256 next;
        if (delta > 0) {
            next = cur + uint256(delta);
        } else if (delta < 0) {
            uint256 subtract = uint256(-delta);
            if (cur < subtract) {
                revert NotEnoughSettlementBalance(id, tokenIndex, cur, subtract);
            }
            next = cur - subtract;
        } else {
            return;
        }
        totalSettlementAmount[id][tokenIndex] = next;
        _refreshCoverageUnits(id, poolId, tokenIndex);
    }

    /// @dev Coverage units are proactively settled amounts capped by commitment for the given token.
    function _coverageUnits(PositionId id, uint8 t) internal view returns (uint256) {
        uint256 c = commitmentMaxima[id][t];
        uint256 s = totalSettlementAmount[id][t];
        return s < c ? s : c;
    }

    /// @dev Refresh pool-wide coverage units when a position's units change.
    function _refreshCoverageUnits(PositionId posId, PoolId poolid, uint8 tokenIndex) internal {
        uint256 beforeU = lastCoverageUnits[posId][tokenIndex];
        uint256 afterU = _coverageUnits(posId, tokenIndex);
        if (afterU == beforeU) return;
        if (afterU > beforeU) {
            totalCoverageUnits[poolid][tokenIndex] += (afterU - beforeU);
        } else if (beforeU > afterU) {
            uint256 dec = beforeU - afterU;
            uint256 cur = totalCoverageUnits[poolid][tokenIndex];
            totalCoverageUnits[poolid][tokenIndex] = dec > cur ? 0 : cur - dec;
        }
        lastCoverageUnits[posId][tokenIndex] = afterU;
    }
}
