// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {PositionIndex} from "../modules/PositionIndex.sol";
import {PositionMeta} from "../types/Position.sol";
import {GrowthAccounting} from "../libraries/GrowthAccounting.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PositionLibrary, PositionId} from "../types/Position.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {TransientSlots} from "../libraries/TransientSlots.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";
import {FixedPoint128} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint128.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
import {IOracleHelper} from "../interfaces/IOracleHelper.sol";
import {Errors} from "../libraries/Errors.sol";

abstract contract VTSManager is IVTSManager, PositionIndex {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using TransientSlot for *;
    using CurrencySettler for Currency;

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
    // Tick-indexed coverage usage growth (per token) accrued at unwrap time
    mapping(PoolId => uint256[2]) internal coverageUseGrowthGlobal;
    mapping(PoolId => mapping(int24 => uint256[2])) internal coverageUseGrowthOutside;
    mapping(PositionId => uint256[2]) internal coverageUseGrowthInsideLast;
    // Residual coverage when no in-range liquidity; applied on next activation
    mapping(PoolId => uint256[2]) internal coverageResidual;
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

    // (legacy proactive and fee-pot accounting removed)

    // Per-position fees contributed to the pot via slashes (for self-exclusion in bonus)
    mapping(PositionId => uint256[2]) internal feesSharedByPosition;
    // Per-position signed pending fee adjustment: +slash (reduces payout), -bonus (increases payout)
    mapping(PositionId => int256[2]) internal pendingFeeAdj;

    // Slashed pot per market/token: LCC balances held by CoreHook (this) extracted via take(),
    // used to fund bonus materialisation. Index 0 => token0 pot, 1 => token1 pot.
    mapping(PoolId => uint256[2]) internal slashedPot;

    // Persistent nets since last fee finalisation (position modification)
    // Per-position net settlement delta (signed) per token
    mapping(PositionId => int256[2]) internal netSettlementSinceLastMod;
    // Per-pool sum of positive nets per token (used for net-weighted bonus allocation)
    mapping(PoolId => uint256[2]) internal poolNetSinceLastMod;

    // Snapshot of last funded pending fee adjustments per position/token to avoid over-funding across multiple settles
    mapping(PositionId => int256[2]) internal lastFundedPendingAdj;

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event MarketVTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    event FeeShareHandled(
        PoolId indexed poolId, PositionId indexed positionId, uint8 indexed tokenIndex, uint256 share, uint256 growthInc
    );
    event MMPositionSettle(PoolId indexed poolId, PositionId indexed positionId, int128 amount0, int128 amount1);

    address private immutable mmPositionManager;
    IPoolManager private immutable poolManager;
    IOracleHelper private immutable oracleHelper;

    modifier onlyPositionValid(PositionId _positionId) {
        if (!isPositionValid(_positionId, true)) {
            revert Errors.InvalidPosition(0, 0, _positionId);
        }
        if (commitmentMaxima[_positionId][0] == 0 || commitmentMaxima[_positionId][1] == 0) {
            revert Errors.InvalidPosition(0, 0, _positionId);
        }
        _;
    }

    modifier onlyMMPosition(PositionId _positionId) {
        if (!_isCallerMMP(msg.sender) || !_isMMPosition(_positionId)) {
            revert Errors.InvalidSender();
        }
        _;
    }

    constructor(address _poolManager, address _marketFactory, address _mmPositionManager)
        PositionIndex(_marketFactory)
    {
        poolManager = IPoolManager(_poolManager);
        oracleHelper = IOracleHelper(marketFactory.oracleHelper());
        mmPositionManager = _mmPositionManager;
    }

    // --------------------------------------------------
    // Helper Functions
    // --------------------------------------------------

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
     * @notice Sets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @param vtsConfiguration The VTS configuration
     */
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        public
        override
        onlyFactory
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

    function getPositionSettledAmounts(PositionId[] calldata positionIds)
        public
        view
        override
        returns (uint256 amount0, uint256 amount1)
    {
        uint256 len = positionIds.length;
        for (uint256 i = 0; i < len;) {
            PositionId id = positionIds[i];
            uint256[2] storage s = totalSettlementAmount[id];
            amount0 += s[0];
            amount1 += s[1];
            unchecked {
                i++;
            }
        }
    }

    /**
     * @notice Gets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @return The VTS configuration
     */
    function getMarketVTSConfiguration(PoolId corePoolId) public view override returns (MarketVTSConfiguration memory) {
        return corePoolToVTSConfiguration[corePoolId];
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
     * @notice Checks if fee sharing is enabled for a core pool
     * @return True if fee sharing is enabled, false otherwise
     */
    function _isFeeSharingEnabled(PoolId p) internal view returns (bool) {
        return corePoolToVTSConfiguration[p].coverageFeeShare > 0;
    }

    // --------------------------------------------------
    // Position Management Functions
    // --------------------------------------------------

    /**
     * @notice Touches a position, registers it if it doesn't exist, updates it if it does, and tracks the commitment
     * @param owner The owner of the position - ie. the Smart Contract managing positions.
     * @param poolId The pool id
     * @param params The parameters of the transaction
     */
    function _touchPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) internal virtual {
        PositionId id = PositionLibrary.generateId(owner, params);
        PositionMeta memory m = meta[id];

        uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(id));

        bool isMMPosition = _isCallerMMP(owner) && _isMMPosition(id);

        if (m.owner == address(0)) {
            // NEW POSITION: initialize the liquidity to the liquidity delta, assuming it will always be positive
            _registerPosition(owner, poolId, params);
            _initPositionSnapshots(id);
            _trackCommitment(id, params);

            if (isMMPosition) {
                // New positions mean base settlement.
                // If the modifyDelta is 0 AND the position is active (created), then default settlement to base amounts
                MarketVTSConfiguration memory vtsConfiguration = getMarketVTSConfiguration(poolId);
                (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                    commitmentMaxima[id][0],
                    commitmentMaxima[id][1],
                    vtsConfiguration.token0.baseVTSRate,
                    vtsConfiguration.token1.baseVTSRate
                );
                // Set the settlement amounts to the total commitment amounts for DirectLPs.
                _updateSettlement(id, 0, SafeCast.toInt256(amountToSettle0));
                _updateSettlement(id, 1, SafeCast.toInt256(amountToSettle1));

                TransientSlots.addPositionRequiredSettlementDelta(
                    LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, false, false)
                );
            } else {
                // Set the settlement amounts to the total commitment amounts for DirectLPs.
                _updateSettlement(id, 0, SafeCast.toInt256(commitmentMaxima[id][0]));
                _updateSettlement(id, 1, SafeCast.toInt256(commitmentMaxima[id][1]));
            }
        } else if (m.isActive == true) {
            // EXISTING POSITION: update the liquidity by the liquidity delta
            if (params.liquidityDelta < 0) {
                // FULL or PARTIAL LIQUIDATION:

                // validate that RfS is closed before we track position param (commitment maxima) updates.
                calcRFS(id, true); // rfs is always closed for DirectLPs.
                _trackCommitment(id, params);
                // active position is being liquidated.
                uint256 s0 = totalSettlementAmount[id][0];
                uint256 s1 = totalSettlementAmount[id][1];
                uint256 excess0 = 0;
                uint256 excess1 = 0;
                if (liq == 0) {
                    // full liquidation
                    excess0 = s0;
                    excess1 = s1;
                } else {
                    // a partial liquidation results in removal of the settlements above the NEW commitment maxima.
                    if (s0 > commitmentMaxima[id][0]) {
                        excess0 = s0 - commitmentMaxima[id][0];
                    }
                    if (s1 > commitmentMaxima[id][1]) {
                        excess1 = s1 - commitmentMaxima[id][1];
                    }
                }
                // ? Update settlement for all positions.
                if (excess0 > 0) {
                    _updateSettlement(id, 0, -SafeCast.toInt256(excess0));
                }
                if (excess1 > 0) {
                    _updateSettlement(id, 1, -SafeCast.toInt256(excess1));
                }
                // ? Only save the settlement delta for MMPs.
                if (isMMPosition) {
                    // this sets the required settlement because we changes the position.
                    TransientSlots.addPositionRequiredSettlementDelta(
                        LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true)
                    );
                }
            } else if (params.liquidityDelta > 0) {
                // POSITION DELTA INCREASE:

                _trackCommitment(id, params);

                uint256 s0 = totalSettlementAmount[id][0];
                uint256 s1 = totalSettlementAmount[id][1];

                if (isMMPosition) {
                    // commitment maxima increases, and therefore base settlement requirements do too.
                    // Therefore, recalculate the base settlement requirements, and determine excess over s0,s1 to settle IN.
                    MarketVTSConfiguration memory vtsConfiguration = getMarketVTSConfiguration(poolId);
                    (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                        commitmentMaxima[id][0],
                        commitmentMaxima[id][1],
                        vtsConfiguration.token0.baseVTSRate,
                        vtsConfiguration.token1.baseVTSRate
                    );
                    uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
                    uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;

                    // Instruct MMP to source underlying for the excess
                    TransientSlots.addPositionRequiredSettlementDelta(
                        LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false)
                    );

                    // Apply the increase to the position’s settled amounts immediately so bonus weights reflect net state.
                    if (excess0 > 0) {
                        _updateSettlement(id, 0, SafeCast.toInt256(excess0));
                    }
                    if (excess1 > 0) {
                        _updateSettlement(id, 1, SafeCast.toInt256(excess1));
                    }
                } else {
                    // Increase DirectLPs settlement amounts by the difference between the commitment maxima and the last settled amounts.
                    _updateSettlement(id, 0, SafeCast.toInt256(commitmentMaxima[id][0] - s0));
                    _updateSettlement(id, 1, SafeCast.toInt256(commitmentMaxima[id][1] - s1));
                }
            }

            int256 newLiquidity = meta[id].liquidity += params.liquidityDelta;
            if (newLiquidity < 0) {
                // this should never happen in theory but check is performed to be safe since it is a uint256 and a position must not have a negative liquidity
                // revert InvalidLiquidityDelta(newLiquidity);
                meta[id].liquidity = 0;
            } else {
                meta[id].liquidity = newLiquidity;
            }
        } else {
            revert Errors.NotActive(id);
        }
        if (liq == 0) {
            meta[id].isActive = false;
        } else {
            meta[id].isActive = true;
        }
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

        (uint256 fg0, uint256 fg1) = poolManager.getFeeGrowthInside(p, m.tickLower, m.tickUpper);
        feeGrowthInsideLast[id][0] = fg0;
        feeGrowthInsideLast[id][1] = fg1;

        // Coverage usage snapshot
        (uint256 cu0, uint256 cu1) =
            GrowthAccounting.inside(coverageUseGrowthGlobal, coverageUseGrowthOutside, p, m.tickLower, m.tickUpper);
        coverageUseGrowthInsideLast[id][0] = cu0;
        coverageUseGrowthInsideLast[id][1] = cu1;
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

        // PoolId pId = meta[positionId].poolId; // unused after coverage units removal

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            uint128 liquidityAdded = SafeCast.toUint128(uint256(params.liquidityDelta));
            (uint256 addC0, uint256 addC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            commitmentMaxima[positionId][0] = currentC0 + addC0;
            commitmentMaxima[positionId][1] = currentC1 + addC1;
            // (coverage units removed)
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = SafeCast.toUint128(uint256(-params.liquidityDelta));
            (uint256 subC0, uint256 subC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            commitmentMaxima[positionId][0] = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            commitmentMaxima[positionId][1] = currentC1 > subC1 ? (currentC1 - subC1) : 0;
            // (coverage units removed)
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    /**
     * @notice Records the settlement of underlying assets on a position. Occurs entirely independently of position-required settlements. Never to be called alongside MMPositionManager.callModifyLiquidity.
     * @dev make sure this function can only be called by the MMPositionManager since it is the interface through which underlying asset settlements are going to be made.
     * @param positionId The id of the position
     * @param lccCurrency0 The pool currency of the LCC token for token0
     * @param lccCurrency1 The pool currency of the LCC token for token1
     * @param delta The balance delta of the settlement
     * @return settlementDelta The balance delta of the settlement amounts relative to the position that was actually modified. The amount of underlying native assets actually reallocated/adjusted.
     * @return rfsOpen Whether the RfS is open for the position
     */
    function onMMSettle(PositionId positionId, Currency lccCurrency0, Currency lccCurrency1, BalanceDelta delta)
        external
        onlyMMPosition(positionId)
        onlyPositionValid(positionId)
        returns (BalanceDelta settlementDelta, bool rfsOpen)
    {
        PositionMeta memory m = meta[positionId];
        PoolId poolId = m.poolId;

        // Only assert closed RfS if pure underlying liquidity WITHDRAWAL. calcRFS includes settle growth accounting since last touch
        bool isWithdrawal = delta.amount0() < 0 || delta.amount1() < 0;
        (rfsOpen,) = calcRFS(positionId, isWithdrawal);

        // during withdrawals, delta 0 - negative modifyDelta < 0. during deposits, delta 0 + positive modifyDelta > 0. //
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());
        if (amount0 > 0) {
            amount0 = _updateSettlement(positionId, 0, int256(amount0));
        } else if (amount0 < 0) {
            amount0 = _updateSettlement(positionId, 0, int256(amount0));
        }
        if (amount1 > 0) {
            amount1 = _updateSettlement(positionId, 1, int256(amount1));
        } else if (amount1 < 0) {
            amount1 = _updateSettlement(positionId, 1, int256(amount1));
        }

        // Clamps within _updateSettlement may modify the return delta.
        settlementDelta = LiquidityUtils.safeToBalanceDelta(amount0, amount1);

        // Proactive extraction (incremental): fund only increases in pending slashes since last observation to avoid over-funding.
        /**
         * Proactive extraction rationale:
         * We fund the fee pot here (onMMSettle) only for newly accrued pending slashes since the last observation.
         * Slashes arise when protocol coverage is exercised against positions (via coverage-usage settlement and fee burn),
         * and onMMSettle calls into growth settlement so pending slashes can increase between position modifications.
         * To ensure there is sufficient LCC in the shared pot to pay bonuses to contributing positions, we proactively
         * take only the incremental increase in pending slashes (vs lastFundedPendingAdj). This avoids double-funding
         * when multiple settles occur before the next position modification.
         *
         * We intentionally do NOT fund inside _updateSettlement: it is a core storage routine called from many paths,
         * and slashing is not linearly tied to every settlement delta. Position modifications will also handle pot
         * funding/draining and finalisation atomically via _processPositionFees. Thus, pot operations live only in:
         *  - onMMSettle: incremental funding of new pending slashes, and
         *  - _processPositionFees: final funding/draining and fee adjustment finalisation during modification.
         */
        {
            (int256 adj0, int256 adj1) = _peekFeeAdjustment(positionId);
            int256 prev0 = lastFundedPendingAdj[positionId][0];
            int256 prev1 = lastFundedPendingAdj[positionId][1];

            if (adj0 > prev0) {
                _fundFeePot(poolId, lccCurrency0, 0, uint256(adj0 - prev0));
            }
            if (adj1 > prev1) {
                _fundFeePot(poolId, lccCurrency1, 1, uint256(adj1 - prev1));
            }

            // snapshot current pending as baseline for the next settle
            lastFundedPendingAdj[positionId][0] = adj0;
            lastFundedPendingAdj[positionId][1] = adj1;
        }

        emit MMPositionSettle(poolId, positionId, settlementDelta.amount0(), settlementDelta.amount1());
    }

    // --------------------------------------------------
    // Fee-Share and Coverage Management Functions
    // --------------------------------------------------

    /**
     * @dev Called by MarketFactory to increment unwrap coverage. (ie. if liquidity taken by LiquidityHub for unwraps)
     * @param poolId The pool id
     * @param amount0 The amount to increment the coverage by for token0
     * @param amount1 The amount to increment the coverage by for token1
     */
    function incrementCoverage(PoolId poolId, uint256 amount0, uint256 amount1) external onlyFactory {
        if (amount0 > 0) {
            _incrementCoverage(poolId, 0, amount0);
        }
        if (amount1 > 0) {
            _incrementCoverage(poolId, 1, amount1);
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

    /// @dev Peek the current pending fee adjustments for a position without mutating state.
    ///      Returns signed adjustments per token: +slash (hook takes), -bonus (hook gives).
    function _peekFeeAdjustment(PositionId id) internal view returns (int256 adj0, int256 adj1) {
        adj0 = pendingFeeAdj[id][0];
        adj1 = pendingFeeAdj[id][1];
    }

    /// @dev Finalise a portion of the pending fee adjustment as materialised in the current hook call.
    ///      Materialised values are signed and MUST be bounded by the current pending values.
    ///      Any non-materialised remainder stays in pending to be retried on future hook calls.
    ///      Returns the materialised delta as BalanceDelta for the hook to apply this call only.
    function _finaliseFeeAdjustment(PositionId id, int256 materialised0, int256 materialised1)
        internal
        returns (BalanceDelta)
    {
        // Clamp materialised values to current pending to avoid over-finalisation.
        int256 p0 = pendingFeeAdj[id][0];
        int256 p1 = pendingFeeAdj[id][1];

        // For positive pending, materialised must be in [0, p]; for negative pending, in [p, 0].
        if (p0 >= 0) {
            if (materialised0 < 0) materialised0 = 0;
            if (materialised0 > p0) materialised0 = p0;
        } else {
            if (materialised0 > 0) materialised0 = 0;
            if (materialised0 < p0) materialised0 = p0;
        }
        if (p1 >= 0) {
            if (materialised1 < 0) materialised1 = 0;
            if (materialised1 > p1) materialised1 = p1;
        } else {
            if (materialised1 > 0) materialised1 = 0;
            if (materialised1 < p1) materialised1 = p1;
        }

        // Subtract the materialised portion from pending (note: signed arithmetic).
        pendingFeeAdj[id][0] = p0 - materialised0;
        pendingFeeAdj[id][1] = p1 - materialised1;

        BalanceDelta adj = LiquidityUtils.safeToBalanceDelta(materialised0, materialised1);
        // Publish this-call adjustment to transient storage for MM-managed positions only;
        // MMPositionManager will consume it to classify principal vs effective fees.
        if (_isMMPosition(id)) {
            TransientSlots.addFeeAdjDelta(adj);
        }
        return adj;
    }

    /// @dev Consolidated fee processing for a position during modification: applies and zeros nets, queues bonus using net weighting,
    ///      funds/drains pot based on pending adjustments, and finalises materialised delta for this call.
    function _processPositionFees(PositionId id, Currency currency0, Currency currency1)
        internal
        returns (BalanceDelta)
    {
        PoolId p = meta[id].poolId;

        // Read per-position nets (already applied to totalSettlementAmount via _updateSettlement). Do not mutate yet.
        int256 selfNet0 = netSettlementSinceLastMod[id][0];
        int256 selfNet1 = netSettlementSinceLastMod[id][1];

        // Queue bonuses using positive nets since last modification
        for (uint8 t = 0; t < 2; t++) {
            int256 selfNet = (t == 0) ? selfNet0 : selfNet1;
            if (selfNet <= 0) continue;

            uint256 pot = protocolFeeAccrued[p][t];
            uint256 selfContrib = feesSharedByPosition[id][t];
            uint256 potAvail = pot > selfContrib ? (pot - selfContrib) : 0;
            if (potAvail == 0) continue;

            uint256 totalNetBefore = poolNetSinceLastMod[p][t];
            // totalNetBefore is UNSIGNED. Only positive when totalSettlementAmount > 0 - preventing positive nets that cover deficits from being used.
            if (totalNetBefore == 0) continue;

            // Dust guard
            if (uint256(selfNet) < 1e12) continue;

            uint256 bonus = FullMath.mulDiv(potAvail, uint256(selfNet), totalNetBefore);
            if (bonus > potAvail) bonus = potAvail;

            // Deduct from pot, keep self-contrib excluded
            protocolFeeAccrued[p][t] = potAvail - bonus + selfContrib;
            // Queue negative pending (bonus increases payout at materialisation)
            pendingFeeAdj[id][t] -= SafeCast.toInt256(bonus);
        }

        // After allocation, zero/decrement nets so future allocations don't double-count
        if (selfNet0 != 0) {
            netSettlementSinceLastMod[id][0] = 0;
            if (selfNet0 > 0) {
                uint256 cur0 = poolNetSinceLastMod[p][0];
                uint256 dec0 = uint256(selfNet0);
                poolNetSinceLastMod[p][0] = dec0 > cur0 ? 0 : (cur0 - dec0);
            }
        }
        if (selfNet1 != 0) {
            netSettlementSinceLastMod[id][1] = 0;
            if (selfNet1 > 0) {
                uint256 cur1 = poolNetSinceLastMod[p][1];
                uint256 dec1 = uint256(selfNet1);
                poolNetSinceLastMod[p][1] = dec1 > cur1 ? 0 : (cur1 - dec1);
            }
        }

        // Materialise pending: fund slashed pot for +ve; drain to LP for -ve
        (int256 pend0, int256 pend1) = _peekFeeAdjustment(id);
        int256 mat0 = 0;
        int256 mat1 = 0;

        if (pend0 > 0) {
            _fundFeePot(p, currency0, 0, uint256(pend0));
            mat0 = pend0;
        } else if (pend0 < 0) {
            uint256 need0 = uint256(-pend0);
            uint256 pot0 = slashedPot[p][0];
            uint256 pay0 = pot0 < need0 ? pot0 : need0;
            if (pay0 > 0) {
                _drainFeePot(p, currency0, 0, pay0);
                mat0 = -SafeCast.toInt256(pay0);
            }
        }

        if (pend1 > 0) {
            _fundFeePot(p, currency1, 1, uint256(pend1));
            mat1 = pend1;
        } else if (pend1 < 0) {
            uint256 need1 = uint256(-pend1);
            uint256 pot1 = slashedPot[p][1];
            uint256 pay1 = pot1 < need1 ? pot1 : need1;
            if (pay1 > 0) {
                _drainFeePot(p, currency1, 1, pay1);
                mat1 = -SafeCast.toInt256(pay1);
            }
        }

        BalanceDelta ret = _finaliseFeeAdjustment(id, mat0, mat1);

        // Snapshot current pending after finalisation to keep future settle-time funding incremental
        {
            (int256 cur0, int256 cur1) = _peekFeeAdjustment(id);
            lastFundedPendingAdj[id][0] = cur0;
            lastFundedPendingAdj[id][1] = cur1;
        }

        return ret;
    }

    /// @dev Increase the slashed pot for a pool/token when a take() succeeds.
    function _fundFeePot(PoolId poolId, Currency lccCurrency, uint8 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;
        lccCurrency.take(poolManager, address(this), amount, true);
        slashedPot[poolId][tokenIndex] += amount;
    }

    /// @dev Decrease the slashed pot when settling bonuses (giving out from CoreHook to PoolManager).
    function _drainFeePot(PoolId poolId, Currency lccCurrency, uint8 tokenIndex, uint256 amount) internal {
        if (amount == 0) return;
        lccCurrency.settle(poolManager, address(this), amount, true);
        uint256 pot = slashedPot[poolId][tokenIndex];
        // Clamp to available pot to avoid underflow; caller must have already bounded the amount.
        if (amount > pot) amount = pot;
        slashedPot[poolId][tokenIndex] = pot - amount;
    }

    // --------------------------------------------------
    // Growth Accounting Functions
    // --------------------------------------------------

    /// @dev Internal helper to settle both deficit and inflow growth for a position
    function _settlePositionGrowths(PositionId positionId) internal {
        _settlePositionDeficitGrowth(positionId);
        _settlePositionInflowGrowth(positionId);
        _settleCoverageUsage(positionId);
    }

    /// @dev Settle coverage-usage growth and burn fees only on exercised deficits
    function _settleCoverageUsage(PositionId positionId) internal {
        PositionMeta memory m = meta[positionId];
        PoolId poolId = m.poolId;
        uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(positionId));

        (uint256 cov0, uint256 cov1) = GrowthAccounting.deltaAndCheckpoint(
            coverageUseGrowthGlobal,
            coverageUseGrowthOutside,
            coverageUseGrowthInsideLast[positionId],
            poolId,
            m.tickLower,
            m.tickUpper,
            liq
        );

        if (cov0 > 0) {
            _applyCoverageBurn(positionId, poolId, 0, cov0, liq);
        }
        if (cov1 > 0) {
            _applyCoverageBurn(positionId, poolId, 1, cov1, liq);
        }
    }

    function _applyCoverageBurn(PositionId id, PoolId p, uint8 tokenIndex, uint256 cov, uint128 positionLiquidity)
        internal
    {
        uint256 d = cumulativeDeficit[id][tokenIndex];
        uint256 s = totalSettlementAmount[id][tokenIndex];
        if (cov == 0 || (d == 0 && s == 0)) return;

        // Enforce c <= d + s, then burn only deficit portion
        uint256 cEff = cov <= (d + s) ? cov : (d + s);
        if (cEff == 0 || d == 0) return;
        uint256 burnBase = cEff <= d ? cEff : d; // min(coverage, deficit)

        (uint256 fees, uint256 ofDelta) = _readFeesAndCheckpoint(id, p, tokenIndex, positionLiquidity);
        if (fees == 0 || ofDelta == 0) return;

        uint256 bps = corePoolToVTSConfiguration[p].coverageFeeShare;
        if (bps == 0) return;

        // feesBurn = fees * (burnBase / ofDelta) * bps/10000
        uint256 feesBurn = FullMath.mulDiv(fees, burnBase, ofDelta);
        feesBurn = FullMath.mulDiv(feesBurn, bps, LiquidityUtils.ONE_BIP);
        if (feesBurn == 0) return;
        if (feesBurn > fees) feesBurn = fees; // clamp to fees accrued

        uint256 growthInc = 0;
        if (positionLiquidity > 0) {
            growthInc = FullMath.mulDiv(feesBurn, FixedPoint128.Q128, positionLiquidity);
            // Burn by advancing fee growth baseline
            // The following is “burning” their claimable fees by advancing feeGrowthInsideLast by the share-equivalent growth.
            // In Uniswap-style accounting, a position’s owed fees = (feeGrowthInside − feeGrowthInsideLast) × liquidity.
            // By increasing feeGrowthInsideLast by share/Q128/liquidity, we reduce their future fee delta exactly by share.
            feeGrowthInsideLast[id][tokenIndex] += growthInc;
        }
        protocolFeeAccrued[p][tokenIndex] += feesBurn;
        // Record contributor’s share for self-exclusion and queue pending slash (reduces payout at hook materialisation)
        feesSharedByPosition[id][tokenIndex] += feesBurn;
        // Fee sharing/slashing is applied to the pending fee adjustment mapping to be consumed at the point of position modification.
        pendingFeeAdj[id][tokenIndex] += SafeCast.toInt256(feesBurn);
        emit FeeShareHandled(p, id, tokenIndex, feesBurn, growthInc);
    }

    // (legacy fee-pot settlement removed)

    /// @dev Increment protocol or proactive excess liquidity coverage on LCC unwrap, consuming proactive pool first
    function _incrementCoverage(PoolId poolId, uint8 tokenIndex, uint256 coveredAmount) internal {
        if (tokenIndex > 1 || coveredAmount == 0) return;
        uint128 liq = poolManager.getLiquidity(poolId);
        if (liq > 0) {
            // Accrue coverage usage growth per-liquidity (outflow weight basis at current tick)
            uint256 deltaG = FullMath.mulDiv(coveredAmount, FixedPoint128.Q128, uint256(liq));
            coverageUseGrowthGlobal[poolId][tokenIndex] += deltaG;
        } else {
            // No in-range liquidity; defer to residual
            coverageResidual[poolId][tokenIndex] += coveredAmount;
        }
    }

    /// @notice Called by the hook on tick cross to flip outside growth for a tick
    function _onTickCross(PoolId corePoolId, int24 tick, uint8 token) internal {
        GrowthAccounting.flipOutside(deficitGrowthGlobal, deficitGrowthOutside, corePoolId, tick, token);
        GrowthAccounting.flipOutside(inflowGrowthGlobal, inflowGrowthOutside, corePoolId, tick, token);
        GrowthAccounting.flipOutside(coverageUseGrowthGlobal, coverageUseGrowthOutside, corePoolId, tick, token);

        // Apply residual if any when liquidity becomes active
        uint256 residual = coverageResidual[corePoolId][token];
        if (residual > 0) {
            uint128 liq = poolManager.getLiquidity(corePoolId);
            if (liq > 0) {
                uint256 deltaG = FullMath.mulDiv(residual, FixedPoint128.Q128, uint256(liq));
                coverageUseGrowthGlobal[corePoolId][token] += deltaG;
                coverageResidual[corePoolId][token] = 0;
            }
        }
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
                _updateSettlement(positionId, 0, -(SafeCast.toInt256(add0))); // reduce total settlement amount by add0
            } else {
                uint256 netAdd0 = add0 - s0;
                cumulativeDeficit[positionId][0] += netAdd0;
                globalDeficit[corePoolId][0] += netAdd0;
                _updateSettlement(positionId, 0, -(SafeCast.toInt256(s0))); // set total settlement amount to 0
            }
        }
        if (add1 > 0) {
            cumulativeOutflows[positionId][1] += add1;

            uint256 s1 = totalSettlementAmount[positionId][1];
            if (s1 >= add1) {
                _updateSettlement(positionId, 1, -(SafeCast.toInt256(add1))); // reduce total settlement amount by add1
            } else {
                uint256 netAdd1 = add1 - s1;
                cumulativeDeficit[positionId][1] += netAdd1;
                globalDeficit[corePoolId][1] += netAdd1;
                _updateSettlement(positionId, 1, -(SafeCast.toInt256(s1))); // set total settlement amount to 0
            }
        }
    }

    /// @dev Accrue inflow growth to the global accumulator (per token) using current in-range liquidity
    ///      inflowAmount should be net of Uniswap LP/protocol fees (use no-fee input per segment)
    function _accrueInflowGrowth(PoolId corePoolId, uint8 token, uint256 inflowAmount) internal {
        uint128 liq = poolManager.getLiquidity(corePoolId);
        GrowthAccounting.accrue(inflowGrowthGlobal, corePoolId, token, inflowAmount, liq);
    }

    /// @dev Compute inflow inside accumulator for a position bounds

    /// @dev Settle inflow growth for a position: first extinguish deficits, then credit remaining as proactive liquidity
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

        // Token0: net against deficit first
        if (add0 > 0) {
            // Auto-net and apply via centralised updater
            _updateSettlement(positionId, 0, SafeCast.toInt256(add0));
        }

        // Token1: net against deficit first
        if (add1 > 0) {
            // Auto-net and apply via centralised updater
            _updateSettlement(positionId, 1, SafeCast.toInt256(add1));
        }
    }

    // --------------------------------------------------
    // Lens Functions
    // --------------------------------------------------

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
        (uint256 c0, uint256 c1) = _getCommitment(positionId);
        uint256 d0 = cumulativeDeficit[positionId][0];
        uint256 d1 = cumulativeDeficit[positionId][1];
        uint256 one = 1e18;
        vtsRequired0 = c0 == 0 ? 0 : (d0 >= c0 ? one : FullMath.mulDiv(d0, one, c0));
        vtsRequired1 = c1 == 0 ? 0 : (d1 >= c1 ? one : FullMath.mulDiv(d1, one, c1));
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
                revert Errors.RFSOpenForPosition(positionId);
            }
        }
        return (rfsOpen, delta);
    }

    /**
     * @notice Gets the liquidity amount to be seized from a position
     * @dev This method is called BEFORE the position is modified by the seizure.
     * @param positionId The position id
     * @param settleDelta The balance delta of the amounts settled during seizure.
     * @return seizedLiquidityUnits The amount of position liquidity units that can be seized
     */
    function calcSeizure(PositionId positionId, BalanceDelta settleDelta, RFSCheckpoint calldata checkpoint)
        external
        onlyMMPosition(positionId)
        onlyPositionValid(positionId)
        returns (uint256 seizedLiquidityUnits)
    {
        _settlePositionGrowths(positionId);
        PositionMeta memory m = meta[positionId];
        (bool rfsOpen, BalanceDelta rfsDelta) = _getRFS(positionId);
        if (!rfsOpen) {
            revert Errors.InvalidPosition(0, 0, positionId);
        }

        // Commitments and RfS amounts
        uint256 c0 = commitmentMaxima[positionId][0];
        uint256 c1 = commitmentMaxima[positionId][1];
        uint256 r0 = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0());
        uint256 r1 = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1());
        uint256 s0 = LiquidityUtils.safeInt128ToUint256(settleDelta.amount0());
        uint256 s1 = LiquidityUtils.safeInt128ToUint256(settleDelta.amount1());

        // Clamp settles by RfS per token to avoid over-seizure via over-settlement
        if (s0 > r0) {
            s0 = r0;
        }
        if (s1 > r1) {
            s1 = r1;
        }

        // Grace gating per token being intervened
        // TODO: update validation logic per ProofOfSettlement mechanic
        MarketVTSConfiguration memory cfg = getMarketVTSConfiguration(m.poolId);
        uint256 openAt = checkpoint.timeOfLastTransition;
        if (r0 > 0 && s0 > 0) {
            if (block.timestamp < openAt + cfg.token0.gracePeriodTime) {
                revert Errors.GracePeriodNotElapsed(0, 0, positionId, RFSCheckpoint(0, false, 0, 0));
            }
        }
        if (r1 > 0 && s1 > 0) {
            if (block.timestamp < openAt + cfg.token1.gracePeriodTime) {
                revert Errors.GracePeriodNotElapsed(0, 0, positionId, RFSCheckpoint(0, false, 0, 0));
            }
        }

        // Force the clamped settlement via transient slot; MMPositionManager._settleUnderlying will consume this
        // TransientSlots.setSettlementDelta(LiquidityUtils.safeToBalanceDelta(s0, s1, false, false));

        // Pre-deduct the seizer's settlement from the position's settled amounts so the LCCs
        // transferred on _decrease include claim to the newly funded underlying post-obligation.
        // Clamp deductions to current settled balances to avoid underflow.
        // TODO: settle in to the position, which closes the deficit and does NOT increase settled amount for deficit closed.
        // TODO: Therefore, the seizure is paying back the protocol for the amount owed by the position.
        // (legacy references to proactive obligation removed)
        // {
        //     uint256 curS0 = totalSettlementAmount[positionId][0];
        //     uint256 curS1 = totalSettlementAmount[positionId][1];
        //     uint256 dec0 = s0 > curS0 ? curS0 : s0;
        //     uint256 dec1 = s1 > curS1 ? curS1 : s1;
        //     if (dec0 > 0) {
        //         _updateSettlement(m.poolId, positionId, 0, -SafeCast.toInt256(dec0));
        //     }
        //     if (dec1 > 0) {
        //         _updateSettlement(m.poolId, positionId, 1, -SafeCast.toInt256(dec1));
        //     }
        // }

        // Exposures and settle proportions (apply base VTS as minimum buffer)
        uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
        uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
        if (cfg.token0.baseVTSRate > e0bps) {
            e0bps = cfg.token0.baseVTSRate;
        }
        if (cfg.token1.baseVTSRate > e1bps) {
            e1bps = cfg.token1.baseVTSRate;
        }
        // \phi_settle ensures seizure calculation is proportional to the settled amount in this transaction.
        uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
        uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);

        uint256 liq = uint256(m.liquidity);
        uint256 u0 = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps);
        uint256 u1 = LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);
        uint256 total = u0 + u1;
        return total > liq ? liq : total;
    }

    /**
     * @notice Gets (view) the RFS for a position
     * @param _positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
     */
    function _getRFS(PositionId _positionId) internal view returns (bool, BalanceDelta) {
        (uint256 c0, uint256 c1) = _getCommitment(_positionId);

        uint256 s0 = totalSettlementAmount[_positionId][0];
        uint256 s1 = totalSettlementAmount[_positionId][1];
        uint256 d0 = cumulativeDeficit[_positionId][0];
        uint256 d1 = cumulativeDeficit[_positionId][1];
        uint256 req0 = d0 < c0 ? d0 : c0; // cap deficit by commitment
        uint256 req1 = d1 < c1 ? d1 : c1;

        int128 amount0 = _rfsDeltaRaw(s0, req0, 0);
        int128 amount1 = _rfsDeltaRaw(s1, req1, 0);

        // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
        bool open = (amount0 > 0) || (amount1 > 0);
        return (open, toBalanceDelta(amount0, amount1));
    }

    /// @dev Return signed delta in raw units: positive => needs settlement, negative => withdrawable
    function _rfsDeltaRaw(uint256 settled, uint256 required, uint256 obligation) internal pure returns (int128) {
        uint256 need = required + obligation; // safe add (Solidity 0.8 checks overflow)
        if (need >= settled) {
            uint256 pos = need - settled; // rfs is the needed minus the already settled.
            if (pos > INT128_MAX_U) return type(int128).max;
            return SafeCast.toInt128(SafeCast.toInt256(pos));
        }
        uint256 neg = settled - need; // withdrawable
        if (neg > INT128_MAX_U) return type(int128).min;
        int128 magnitude = SafeCast.toInt128(SafeCast.toInt256(neg));
        return -magnitude;
    }

    // --------------------------------------------------
    // Core Accounting Functions
    // --------------------------------------------------

    /**
     * @notice Updates the settlement amount by a delta which could be positive or negative
     * @param id The position id
     * @param tokenIndex The token index
     * @param delta The delta of the settlement
     */
    function _updateSettlement(PositionId id, uint8 tokenIndex, int256 delta) internal returns (int256) {
        uint256 cur = totalSettlementAmount[id][tokenIndex];
        if (delta == 0) {
            return 0;
        }
        uint256 next = cur;
        uint256 c = commitmentMaxima[id][tokenIndex];

        if (delta > 0) {
            // Auto-net any lingering deficit first
            uint256 def = cumulativeDeficit[id][tokenIndex];
            if (def > 0) {
                uint256 cover = uint256(delta) > def ? def : uint256(delta);
                if (cover > 0) {
                    cumulativeDeficit[id][tokenIndex] = def - cover;
                    // keep global coherent
                    PoolId p = meta[id].poolId;
                    uint256 gD = globalDeficit[p][tokenIndex];
                    globalDeficit[p][tokenIndex] = cover <= gD ? (gD - cover) : 0;
                    delta -= int256(cover);
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

        totalSettlementAmount[id][tokenIndex] = next;
        int256 applied = SafeCast.toInt256(next) - SafeCast.toInt256(cur); // output delta

        // Accrue persistent nets since last fee finalisation
        {
            PoolId p = meta[id].poolId;
            // Track per-position net
            netSettlementSinceLastMod[id][tokenIndex] += applied;
            // Track pool-wide sum of positive nets (used for net-weighted bonus allocation)
            // applied > 0 means UNSIGNED totalSettlementAmount > 0 - preventing positive nets that cover deficits from being used.
            if (applied >= 0) {
                poolNetSinceLastMod[p][tokenIndex] += uint256(applied);
            } else {
                uint256 dec = uint256(-applied);
                uint256 curPoolNet = poolNetSinceLastMod[p][tokenIndex];
                poolNetSinceLastMod[p][tokenIndex] = dec > curPoolNet ? 0 : (curPoolNet - dec);
            }
        }

        return applied;
    }
}
