// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PositionIndex} from "../modules/PositionIndex.sol";
import {PositionMeta} from "../types/Position.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCastLib} from "v4-periphery/lib/v4-core/lib/solmate/src/utils/SafeCastLib.sol";
import {PositionLibrary, PositionId} from "../types/Position.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {console} from "forge-std/console.sol";
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
    uint256 internal constant Q128 = 1 << 128;
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

    error InvalidMarketVTSConfiguration(PoolId corePoolId);
    error NotEnoughSettlementBalance(uint256 amount0, uint256 amount1);
    error InvalidPosition(PositionId positionId);
    error RFSOpenForPosition(PositionId positionId);

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event MarketVTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    // Per-entry events are declared in VTSEvents

    address private immutable mmPositionManager;
    IPoolManager private immutable poolManager;
    address private calculator; // optional external calculator (Stylus or pure)

    modifier onlyPositionValid(PositionId _positionId) {
        if (!isPositionValid(_positionId, true)) {
            console.log("invalid position");
            revert InvalidPosition(_positionId);
        }
        _;
    }

    modifier onlyMMP() {
        if (msg.sender != mmPositionManager) {
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
     * @notice Upsert a position and its Metadata
     * @param owner The owner of the position
     * @param poolId The pool id of the position
     * @param params The parameters of the position
     */
    function _touchPosition(address owner, PoolId poolId, ModifyLiquidityParams calldata params) internal virtual {
        PositionId id = PositionLibrary.generateId(owner, params);
        PositionMeta memory m = meta[id];
        if (m.owner == address(0)) {
            // new position, initialize the liquidity to the liquidity delta, assuming it will always be positive
            _registerPosition(owner, poolId, params);
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
    }

    /**
     * @notice Tracks the maximum potential commitment for both tokens in a position
     * @param router The sender of the transaction
     * @param params The parameters of the transaction
     */
    function _trackCommitment(address router, ModifyLiquidityParams calldata params) internal {
        PositionId positionId = PositionLibrary.generateId(router, params);

        // Current tracked maxima for this position
        uint256 currentC0 = commitmentMaxima[positionId][0];
        uint256 currentC1 = commitmentMaxima[positionId][1];

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            uint128 liquidityAdded = SafeCastLib.safeCastTo128(uint256(params.liquidityDelta));
            (uint256 addC0, uint256 addC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            commitmentMaxima[positionId][0] = currentC0 + addC0;
            commitmentMaxima[positionId][1] = currentC1 + addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = SafeCastLib.safeCastTo128(uint256(-params.liquidityDelta));
            (uint256 subC0, uint256 subC1) =
                LiquidityUtils.calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            commitmentMaxima[positionId][0] = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            commitmentMaxima[positionId][1] = currentC1 > subC1 ? (currentC1 - subC1) : 0;
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    /**
     * @notice Records the settlement of assets on a position
     * @dev make sure this function can only be called by the position manager since that is the interface through which settlements are going to be made
     * @param positionId The id of the position
     * @param balanceDelta The balance delta of the settlement
     */
    function onMMLiquidityModify(PositionId positionId, BalanceDelta balanceDelta)
        external
        onlyMMP
        onlyPositionValid(positionId)
    {
        // First, settle both growths since last touch
        _settlePositionGrowths(positionId);

        int128 amount0 = balanceDelta.amount0();
        int128 amount1 = balanceDelta.amount1();

        totalSettlementAmount[positionId][0] = _updateSettlement(totalSettlementAmount[positionId][0], amount0);
        totalSettlementAmount[positionId][1] = _updateSettlement(totalSettlementAmount[positionId][1], amount1);

        // Net settlements against cumulative deficit (reduce debt when MM settles)
        // if the delta is positive, then it means the MM is settling the position
        // and since they are settling the position, we need to reduce the deficit
        // if the amount being settled is greater than teh deficit, then we need to set the deficit to 0
        if (amount0 > 0) {
            uint256 a0 = uint256(uint128(amount0));
            uint256 cur0 = cumulativeDeficit[positionId][0];
            cumulativeDeficit[positionId][0] = a0 >= cur0 ? 0 : (cur0 - a0);
        }
        if (amount1 > 0) {
            uint256 a1 = uint256(uint128(amount1));
            uint256 cur1 = cumulativeDeficit[positionId][1];
            cumulativeDeficit[positionId][1] = a1 >= cur1 ? 0 : (cur1 - a1);
        }
    }

    /// @dev Internal helper to settle both deficit and inflow growth for a position
    function _settlePositionGrowths(PositionId positionId) internal {
        _settlePositionDeficitGrowth(positionId);
        _settlePositionInflowGrowth(positionId);
    }

    /// @notice Called by the hook on tick cross to flip outside growth for a tick
    function _onTickCross(PoolId corePoolId, int24 tick, uint8 token) internal {
        _flipDeficitGrowthOutside(corePoolId, tick, token);
        _flipInflowGrowthOutside(corePoolId, tick, token);
    }

    /// @dev Accrue deficit growth to the global accumulator (per token) using current in-range liquidity
    /**
     * - Growth accrues globally per swap as a per‑liquidity‑unit increment. Bound (initialised) ticks are only the partition points we flip at to compute “inside” for any range.
     *     - “Normalise over liquidity depth” happens implicitly: growth is per unit liquidity, then you multiply by the position’s liquidity to get raw token units; you don’t divide by L again.
     *
     *     The flow:
     *     - On each swap outflow for token A: Δg = outflowA / L_current → add to `deficitGrowthGlobal_A`.
     *     - On each initialised tick crossed (both directions): flip `deficitGrowthOutside_A(tick)` for A=0,1.
     *     - For a position r = [tickLower, tickUpper]:
     *     - `inside_A = global_A − outside_A(lower) − outside_A(upper)`.
     *     - `ΔD_attr = (inside_A − insideLast_A(r)) * L(r)` (raw token A units).
     *     - Net against in‑market settlements: consume `S_A(r)` first; only `max(0, ΔD_attr − S_A(r))` is added to `cumulativeDeficit_A(r)`.
     *     - Update `insideLast_A(r) = inside_A`.
     *
     *     - VTS_required(r, A) = min(1, `cumulativeDeficit_A(r)` / `C_A(r)`).
     *
     *     So: deficits are accrued globally per outflow, ticks just enable exact “inside” slice for your bounds, and the position’s attributed deficit is the inside growth times its liquidity, netted against its settled balance.
     */
    function _accrueDeficitGrowth(PoolId corePoolId, uint8 token, uint256 deficitAmount) internal {
        // Guard invalid token index
        if (token > 1) return;
        // Use pool total in-range liquidity as denominator (Uniswap v4 core)
        uint128 liq = poolManager.getLiquidity(corePoolId);
        if (liq == 0 || deficitAmount == 0) {
            return;
        }
        // deltaG = deficitAmount / L, scaled by Q128
        uint256 deltaG = (deficitAmount * Q128) / uint256(liq);
        uint256[2] storage g = deficitGrowthGlobal[corePoolId];
        g[token] = g[token] + deltaG;
    }

    /// @dev Flip the outside accumulator for a tick (like feeGrowthOutside flip)
    function _flipDeficitGrowthOutside(PoolId corePoolId, int24 tick, uint8 token) internal {
        if (token > 1) return;
        uint256 globalG = deficitGrowthGlobal[corePoolId][token];
        uint256 currentOutside = deficitGrowthOutside[corePoolId][tick][token];
        deficitGrowthOutside[corePoolId][tick][token] = globalG - currentOutside;
    }

    /// @dev Compute inside accumulator for a position bounds
    function _deficitGrowthInside(PoolId corePoolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 inside0, uint256 inside1)
    {
        uint256 g0 = deficitGrowthGlobal[corePoolId][0];
        uint256 g1 = deficitGrowthGlobal[corePoolId][1];
        uint256 lower0 = deficitGrowthOutside[corePoolId][tickLower][0];
        uint256 lower1 = deficitGrowthOutside[corePoolId][tickLower][1];
        uint256 upper0 = deficitGrowthOutside[corePoolId][tickUpper][0];
        uint256 upper1 = deficitGrowthOutside[corePoolId][tickUpper][1];
        // inside = global - outside(lower) - outside(upper)
        inside0 = g0 - lower0 - upper0;
        inside1 = g1 - lower1 - upper1;
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
        if (PoolId.unwrap(corePoolId) == bytes32(0)) {
            return;
        }
        (uint256 inside0, uint256 inside1) = _deficitGrowthInside(corePoolId, m.tickLower, m.tickUpper);
        uint256 last0 = deficitGrowthInsideLast[positionId][0];
        uint256 last1 = deficitGrowthInsideLast[positionId][1];
        uint256 delta0 = inside0 - last0;
        uint256 delta1 = inside1 - last1;
        if (delta0 == 0 && delta1 == 0) {
            return;
        }
        // Use current position liquidity for scaling back to raw units
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        if (liq > 0) {
            // amount = deltaInside * L / Q128
            uint256 add0 = (delta0 * uint256(liq)) >> 128;
            uint256 add1 = (delta1 * uint256(liq)) >> 128;
            if (add0 > 0) {
                // consume settled coverage first, then accrue shortfall to deficit
                uint256 s0 = totalSettlementAmount[positionId][0];
                if (s0 >= add0) {
                    totalSettlementAmount[positionId][0] = s0 - add0;
                } else {
                    cumulativeDeficit[positionId][0] += (add0 - s0);
                    totalSettlementAmount[positionId][0] = 0;
                }
            }
            if (add1 > 0) {
                uint256 s1 = totalSettlementAmount[positionId][1];
                if (s1 >= add1) {
                    totalSettlementAmount[positionId][1] = s1 - add1;
                } else {
                    cumulativeDeficit[positionId][1] += (add1 - s1);
                    totalSettlementAmount[positionId][1] = 0;
                }
            }
        }
        // Update snapshots
        deficitGrowthInsideLast[positionId][0] = inside0;
        deficitGrowthInsideLast[positionId][1] = inside1;
    }

    /// @dev Accrue inflow growth to the global accumulator (per token) using current in-range liquidity
    ///      inflowAmount should be net of Uniswap LP/protocol fees (use no-fee input per segment)
    function _accrueInflowGrowth(PoolId corePoolId, uint8 token, uint256 inflowAmount) internal {
        if (token > 1) return;
        uint128 liq = poolManager.getLiquidity(corePoolId);
        if (liq == 0 || inflowAmount == 0) {
            return;
        }
        uint256 deltaG = (inflowAmount * Q128) / uint256(liq);
        uint256[2] storage g = inflowGrowthGlobal[corePoolId];
        g[token] = g[token] + deltaG;
    }

    /// @dev Flip the inflow outside accumulator for a tick (like feeGrowthOutside flip)
    function _flipInflowGrowthOutside(PoolId corePoolId, int24 tick, uint8 token) internal {
        if (token > 1) return;
        uint256 globalG = inflowGrowthGlobal[corePoolId][token];
        uint256 currentOutside = inflowGrowthOutside[corePoolId][tick][token];
        inflowGrowthOutside[corePoolId][tick][token] = globalG - currentOutside;
    }

    /// @dev Compute inflow inside accumulator for a position bounds
    function _inflowGrowthInside(PoolId corePoolId, int24 tickLower, int24 tickUpper)
        internal
        view
        returns (uint256 inside0, uint256 inside1)
    {
        uint256 g0 = inflowGrowthGlobal[corePoolId][0];
        uint256 g1 = inflowGrowthGlobal[corePoolId][1];
        uint256 lower0 = inflowGrowthOutside[corePoolId][tickLower][0];
        uint256 lower1 = inflowGrowthOutside[corePoolId][tickLower][1];
        uint256 upper0 = inflowGrowthOutside[corePoolId][tickUpper][0];
        uint256 upper1 = inflowGrowthOutside[corePoolId][tickUpper][1];
        // inside = global - outside(lower) - outside(upper)
        inside0 = g0 - lower0 - upper0;
        inside1 = g1 - lower1 - upper1;
    }

    /// @dev Settle inflow growth for a position into totalSettlementAmount in raw token units
    function _settlePositionInflowGrowth(PositionId positionId) internal {
        PositionMeta memory m = meta[positionId];
        PoolId corePoolId = m.poolId;
        if (PoolId.unwrap(corePoolId) == bytes32(0)) {
            return;
        }
        (uint256 inside0, uint256 inside1) = _inflowGrowthInside(corePoolId, m.tickLower, m.tickUpper);
        uint256 last0 = inflowGrowthInsideLast[positionId][0];
        uint256 last1 = inflowGrowthInsideLast[positionId][1];
        uint256 delta0 = inside0 - last0;
        uint256 delta1 = inside1 - last1;
        if (delta0 == 0 && delta1 == 0) {
            return;
        }
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        if (liq > 0) {
            // amount = deltaInside * L / Q128
            uint256 add0 = (delta0 * uint256(liq)) >> 128;
            uint256 add1 = (delta1 * uint256(liq)) >> 128;
            if (add0 > 0) {
                totalSettlementAmount[positionId][0] += add0;
            }
            if (add1 > 0) {
                totalSettlementAmount[positionId][1] += add1;
            }
        }
        // Update snapshots
        inflowGrowthInsideLast[positionId][0] = inside0;
        inflowGrowthInsideLast[positionId][1] = inside1;
    }

    /**
     * @notice Gets the required vts for a position using cumulative deficits
     * @param positionId The position id
     * @return vtsRequired0 The required vts for token0 (1e18 scale)
     * @return vtsRequired1 The required vts for token1 (1e18 scale)
     */
    function getVTSRequired(PositionId positionId)
        public
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

    /**
     * @notice Gets the current vts for a position
     * @param positionId The position id
     * @return vtsCurrent0 The current vts for token0
     * @return vtsCurrent1 The current vts for token1
     */
    function getVTSCurrent(PositionId positionId)
        public
        view
        virtual
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        uint256 c0 = commitmentMaxima[positionId][0];
        uint256 c1 = commitmentMaxima[positionId][1];
        if (c0 == 0 && c1 == 0) {
            revert InvalidPosition(positionId);
        }

        uint256 s0 = totalSettlementAmount[positionId][0];
        uint256 s1 = totalSettlementAmount[positionId][1];

        uint256 one = 1e18;
        uint256 v0 = FullMath.mulDiv(s0, one, c0);
        uint256 v1 = FullMath.mulDiv(s1, one, c1);
        return (v0, v1);
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
        if (c0 == 0 && c1 == 0) {
            revert InvalidPosition(positionId);
        }
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
        (bool rfsOpen, BalanceDelta balanceDelta) = _getRFS(positionId);
        if (requireClosedRfS) {
            if (rfsOpen) {
                revert RFSOpenForPosition(positionId);
            }
        }
        return (rfsOpen, balanceDelta);
    }

    function prepareLiquidation(PositionId positionId) external onlyMMP returns (uint256, uint256) {
        calcRFS(positionId, true);

        // get total amount settled from the VTS manager
        // important to do this before removing the liquidity from the pool
        // because the position information is cleared after removing the liquidity
        return getPositionSettledAmounts(positionId);
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
    function _getRFS(PositionId _positionId)
        internal
        view
        onlyPositionValid(_positionId)
        returns (bool, BalanceDelta)
    {
        // Commitment caps
        (uint256 c0, uint256 c1) = _getCommitment(_positionId);

        // If calculator is set, try calculator first (not implemented here)
        if (address(calculator) != address(0)) {
            return (false, toBalanceDelta(0, 0));
        }

        (uint256 vtsCurrent0, uint256 vtsCurrent1) = getVTSCurrent(_positionId);
        (uint256 vtsRequired0, uint256 vtsRequired1) = getVTSRequired(_positionId);

        bool open = (vtsCurrent0 < vtsRequired0) || (vtsCurrent1 < vtsRequired1);

        int128 deltaBps0 = int128(int256(vtsCurrent0) - int256(vtsRequired0));
        int128 deltaBps1 = int128(int256(vtsCurrent1) - int256(vtsRequired1));

        uint256 one = 1e18;
        int128 amount0 = (int128(int256(c0)) * deltaBps0) / int128(int256(one));
        int128 amount1 = (int128(int256(c1)) * deltaBps1) / int128(int256(one));

        return (open, toBalanceDelta(amount0, amount1));
    }

    /**
     * @notice Updates the settlement amount by a delta which could be positive or negative
     * @param currentSettled The current settlement amount
     * @param delta The delta of the settlement
     * @return The updated settlement amount
     */
    function _updateSettlement(uint256 currentSettled, int256 delta) internal pure returns (uint256) {
        if (delta > 0) {
            return currentSettled + uint256(delta);
        }

        if (delta < 0) {
            uint256 subtract = uint256(-delta);
            if (currentSettled >= subtract) {
                return currentSettled - subtract;
            } else {
                revert NotEnoughSettlementBalance(currentSettled, subtract);
            }
        }

        return currentSettled;
    }
}
