// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.26;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {EventRing} from "../libraries/EventRing.sol";
import {VTSEvents} from "./VTSEvents.sol";
import {VTSCalculatorLib} from "../libraries/VTSCalculator.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {IPositionIndex, PositionMeta} from "../interfaces/IPositionIndex.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TimeBucketOutflowTracker, TimeBucketOutflowTrackerLibrary} from "../libraries/TimeBucket.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {SafeCastLib} from "v4-periphery/lib/v4-core/lib/solmate/src/utils/SafeCastLib.sol";
import {PositionLibrary, PositionId} from "../types/Position.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {IVTSCalculator} from "../interfaces/IVTSCalculator.sol";
import {IVTSOracleAdapter} from "../interfaces/IVTSOracleAdapter.sol";
import {toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
// import {IMMPositionManager} from "../interfaces/IMMPositionManager.sol";

import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";

abstract contract VTSManager is IVTSManager, VTSEvents {
    using SafeCastLib for *;
    using TimeBucketOutflowTrackerLibrary for TimeBucketOutflowTracker;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using EventRing for EventRing.Ring;

    // Mapping from core pool ID to VTS configuration
    mapping(PoolId => MarketVTSConfiguration) public corePoolToVTSConfiguration;
    // Mapping from core pool ID to rolling outflow tracker
    mapping(PoolId => TimeBucketOutflowTracker) public marketOutflow;
    // Event ring storage and flush roots now live in VTSEvents
    // Mapping to store maximum potential commitment for each position
    mapping(PositionId => uint256[2]) internal commitmentMaxima;
    // Mapping to store the total settlement amount for each position
    mapping(PositionId => uint256[2]) internal totalSettlementAmount;
    // // Pool-wide aggregates (market-level; future refinement to in-range tracking)
    // // Total settled amounts across positions for each token (MM settlements path)
    // mapping(PoolId => uint256[2]) internal marketSettled;
    // // Total committed maxima across positions for each token
    // mapping(PoolId => uint256[2]) internal marketCommitted;
    // // Outstanding market deficit per token (queued deficits minus settlements)
    // mapping(PoolId => uint256[2]) internal marketDeficitOutstanding;
    // Mapping from position to its core pool id (for reading window outflows)
    mapping(PositionId => PoolId) internal positionPoolId;
    // Deprecated: previous per-position committed-at-add amounts (replaced by commitmentMaxima)
    // mapping(PositionId => uint256[2]) internal commitment;

    error InvalidCaller();
    error InvalidMarketVTSConfiguration(PoolId corePoolId);
    error NotEnoughSettlementBalance(uint256 amount0, uint256 amount1);
    error InvalidPosition(PositionId positionId);

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event MarketVTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    // Per-entry events are declared in VTSEvents

    address private immutable marketFactory;
    address private immutable mmPositionManager;
    IPoolManager private immutable poolManager;
    IVTSCalculator private calculator; // optional external calculator (Stylus or pure)
    IVTSOracleAdapter private oracleAdapter; // optional external oracle adapter for deficits attribution
    IPositionIndex internal positionIndex; // external index for position metadata and liquidity history

    modifier onlyMarketFactory() {
        if (msg.sender != marketFactory) revert InvalidCaller();
        _;
    }

    modifier onlyMarketAssets(PoolId corePoolId) {
        address[2] memory currencies = IMarketFactory(marketFactory).corePoolToCurrencyPair(corePoolId);
        if (msg.sender != currencies[0] && msg.sender != currencies[1]) revert InvalidCaller();
        _;
    }

    modifier isPositionValid(PositionId _positionId) {
        PositionMeta memory meta = positionIndex.getMeta(_positionId);
        PoolId corePoolId = meta.poolId;
        if (PoolId.unwrap(corePoolId) == bytes32(0)) {
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

    constructor(address _poolManager, address _marketFactory, address _mmPositionManager, address _calculator) {
        poolManager = IPoolManager(_poolManager);
        marketFactory = _marketFactory;
        mmPositionManager = _mmPositionManager;
        if (_calculator != address(0)) {
            calculator = IVTSCalculator(_calculator);
        }
    }

    /**
     * @notice Sets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @param vtsConfiguration The VTS configuration
     */
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration)
        public
        onlyMarketFactory
    {
        corePoolToVTSConfiguration[corePoolId] = vtsConfiguration;
        marketOutflow[corePoolId].initialize(vtsConfiguration.timeWindow);
        (uint16 defaultSwap, uint16 defaultDeficit, uint16 defaultSettlement) = VTSCalculatorLib.getSizeDefaults();
        // If a ring size is zero, use default; else use provided
        uint16 spsz = vtsConfiguration.swapRingSize == 0 ? defaultSwap : vtsConfiguration.swapRingSize;
        uint16 dsz = vtsConfiguration.deficitRingSize == 0 ? defaultDeficit : vtsConfiguration.deficitRingSize;
        uint16 ssz = vtsConfiguration.settlementRingSize == 0 ? defaultSettlement : vtsConfiguration.settlementRingSize;
        _initRings(corePoolId, spsz, dsz, ssz);

        emit MarketVTSConfigurationSet(corePoolId, vtsConfiguration);
    }

    // TODO: Should be passed in constructor, or inherited.
    function setPositionIndex(address index) external onlyMarketFactory {
        positionIndex = IPositionIndex(index);
    }

    // TODO: Should be onlyOwner...
    function setOracleAdapter(address adapter) external onlyMarketFactory {
        oracleAdapter = IVTSOracleAdapter(adapter);
    }

    // --- Event recording (protocol bounds only) ---
    // Deficits occur on _addToSettlementQueue within the LCC.confirmTake -- called whenever liquidity leaves the protocol, and no excess liquidity exists to cover.
    function recordDeficitEvent(PoolId corePoolId, uint8 token, uint128 deficit)
        external
        onlyMarketAssets(corePoolId)
    {
        _recordDeficit(corePoolId, token, deficit);
        // if (token == 0) {
        //     marketDeficitOutstanding[corePoolId][0] += uint256(deficit);
        // } else {
        //     marketDeficitOutstanding[corePoolId][1] += uint256(deficit);
        // }
    }

    // Settlements occur whenever liquidity in/out of the protocol.
    // Positive settled amount is IN, and negative is OUT.
    // ? If position is unknown, and liquidity OUT, then deficits are processed by pool - ie. via _annulUserSettlement (LCC re-use), or _processSettlementQueue (within MarketVault.settleObligations)
    //      MarketVault.settleObligations is called whenever new liquidity enters on the protocol - ie. via DirectSwap, MM Settlement, DirectLP AddLiquidity
    // ? If position is known, and liquidity OUT, then liquidity derived from MM withdrawals.
    // ? If position is unknown, and liquidity IN, then liquidity derived from swaps, etc.
    // ? If position is known, and liquidity IN, then liquidity derived from MM settlements.
    function recordSettlementEvent(
        PoolId corePoolId,
        uint8 token,
        int128 settled,
        uint128 marketDeficitBefore,
        bytes32 positionId,
        bool burnTokens
    ) external onlyMarketAssets(corePoolId) {
        _recordSettlement(corePoolId, token, settled, marketDeficitBefore, positionId, burnTokens);
        // if (token == 0) {
        //     uint256 d0 = marketDeficitOutstanding[corePoolId][0];
        //     marketDeficitOutstanding[corePoolId][0] = settled > d0 ? 0 : (d0 - uint256(settled));
        // } else {
        //     uint256 d1 = marketDeficitOutstanding[corePoolId][1];
        //     marketDeficitOutstanding[corePoolId][1] = settled > d1 ? 0 : (d1 - uint256(settled));
        // }
    }

    function getPositionSettledAmounts(PositionId positionId) public view returns (uint256 amount0, uint256 amount1) {
        return (totalSettlementAmount[positionId][0], totalSettlementAmount[positionId][1]);
    }

    /**
     * @notice Gets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @return The VTS configuration
     */
    function getMarketVTSConfiguration(PoolId corePoolId) public view returns (MarketVTSConfiguration memory) {
        return corePoolToVTSConfiguration[corePoolId];
    }

    /// @dev Register/update position metadata and liquidity snapshots in the PositionIndex
    function _touchPositionIndex(address router, PoolId corePoolId, ModifyLiquidityParams calldata params)
        internal
        returns (bytes32 _positionId)
    {
        if (address(positionIndex) == address(0)){
            return bytes32(0);
        };
        // Derive position id consistent with Uniswap position keying
        PositionId positionId = PositionLibrary.generateId(router, params);
        // Ensure registration exists (owner set) and current liquidity snapshot is appended
        // Read meta; if not registered, owner will be zero address
        PositionMeta memory positionMeta = positionIndex.getMeta(positionId);
        if (positionMeta.owner == address(0)) {
            positionIndex.register(
                positionId, corePoolId, params.tickLower, params.tickUpper, router, uint64(block.timestamp)
            );
        }
        // Snapshot current on-chain liquidity
        uint128 liq = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
        positionIndex.updateLiquidity(positionId, liq);

        return PositionId.unwrap(positionId);
    }

    /**
     * @notice Gets the total outflow for the currencies in a core pool/Market
     * @param corePoolId The core pool ID
     * @return totalOutflow0 Total outflow for currency0
     * @return totalOutflow1 Total outflow for currency1
     */
    function getMarketOutflow(PoolId corePoolId) public view returns (uint256 totalOutflow0, uint256 totalOutflow1) {
        return marketOutflow[corePoolId].getTotalOutflow();
    }

    /**
     * @notice Records the outflow for the currencies in a core pool/Market
     * @param corePoolId The core pool ID
     * @param delta The balance delta
     */
    // TODO: Determine whether this is necessary considering we're swap recording...
    // function _recordOutflow(PoolId corePoolId, BalanceDelta delta) internal {
    //     // Extract outflow amounts (negative deltas indicate outflow)
    //     int256 delta0 = delta.amount0();
    //     int256 delta1 = delta.amount1();

    //     uint256 outflow0 = delta0 < 0 ? uint256(-delta0) : 0;
    //     uint256 outflow1 = delta1 < 0 ? uint256(-delta1) : 0;

    //     // Record both outflows (even if one is 0)
    //     marketOutflow[corePoolId].recordOutflow(outflow0, outflow1);
    // }

    /**
     * @notice Calculates the maximum potential commitment for both tokens over a tick range for a given liquidity
     * @dev Uses CLMM formulas based on tick bounds and liquidity. Results are in raw token units.
     * @param tickLower The lower tick bound of the position
     * @param tickUpper The upper tick bound of the position
     * @param liquidity The position liquidity to evaluate against the tick range
     * @return c0 The maximum potential commitment for token0 over [tickLower, tickUpper]
     * @return c1 The maximum potential commitment for token1 over [tickLower, tickUpper]
     */
    function calculateCommitmentMaxima(int24 tickLower, int24 tickUpper, uint128 liquidity)
        public
        pure
        returns (uint256 c0, uint256 c1)
    {
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        // Token0 amount across the full range for this liquidity
        c0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
        // Token1 amount across the full range for this liquidity
        c1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, true);
    }

    /**
     * @notice Tracks the maximum potential commitment for both tokens in a position
     * @param router The sender of the transaction
     * @param params The parameters of the transaction
     */
    function _trackCommitment(address router, PoolId corePoolId, ModifyLiquidityParams calldata params) internal {
        PositionId positionId = PositionLibrary.generateId(router, params);
        // Associate position with its core pool id for later reads
        positionPoolId[positionId] = corePoolId;

        // Current tracked maxima for this position
        uint256 currentC0 = commitmentMaxima[positionId][0];
        uint256 currentC1 = commitmentMaxima[positionId][1];

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            uint128 liquidityAdded = SafeCastLib.safeCastTo128(uint256(params.liquidityDelta));
            (uint256 addC0, uint256 addC1) =
                calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityAdded);

            commitmentMaxima[positionId][0] = currentC0 + addC0;
            commitmentMaxima[positionId][1] = currentC1 + addC1;
            // marketCommitted[corePoolId][0] += addC0;
            // marketCommitted[corePoolId][1] += addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = SafeCastLib.safeCastTo128(uint256(-params.liquidityDelta));
            (uint256 subC0, uint256 subC1) =
                calculateCommitmentMaxima(params.tickLower, params.tickUpper, liquidityRemoved);

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            commitmentMaxima[positionId][0] = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            commitmentMaxima[positionId][1] = currentC1 > subC1 ? (currentC1 - subC1) : 0;
            // uint256 mc0 = marketCommitted[corePoolId][0];
            // uint256 mc1 = marketCommitted[corePoolId][1];
            // marketCommitted[corePoolId][0] = subC0 > mc0 ? 0 : (mc0 - subC0);
            // marketCommitted[corePoolId][1] = subC1 > mc1 ? 0 : (mc1 - subC1);
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    // // Placeholder: without duplicating enumeration, we approximate share using position's own liquidity vs pool liquidity
    // // For exact per-position allocation, wire a pool-wide position iterator (e.g., from MMPositionManager) later.
    // function _getLiquidityShareForPosition(PoolId corePoolId, PositionId positionId)
    //     internal
    //     view
    //     returns (uint128 positionLiquidity, uint256 inRangeTotal)
    // {
    //     // Position-specific liquidity
    //     uint128 liqPos = poolManager.getPositionLiquidity(corePoolId, PositionId.unwrap(positionId));
    //     // Use pool total in-range liquidity as denominator approximation - See explaination: static/poolManager-getLiquidity.md
    //     uint128 poolLiq = poolManager.getLiquidity(corePoolId);
    //     return (liqPos, uint256(poolLiq));
    // }

    /**
     * @notice Records the settlement of assets on a position
     * @dev make sure this function can only be called by the position manager since that is the interface through which settlements are going to be made
     * @param positionId The id of the position
     * @param balanceDelta The balance delta of the settlement
     */
    function onMMLiquidityModify(PositionId positionId, BalanceDelta balanceDelta)
        external
        onlyMMP
        isPositionValid(positionId)
    {
        int128 amount0 = balanceDelta.amount0();
        int128 amount1 = balanceDelta.amount1();

        totalSettlementAmount[positionId][0] = _updateSettlement(totalSettlementAmount[positionId][0], amount0);
        totalSettlementAmount[positionId][1] = _updateSettlement(totalSettlementAmount[positionId][1], amount1);

        // // Update pool-wide settled aggregates for the position's market
        // int128 a0 = balanceDelta.amount0();
        // int128 a1 = balanceDelta.amount1();
        // if (a0 > 0) {
        //     marketSettled[corePoolId][0] += uint256(uint128(a0));
        // } else if (a0 < 0) {
        //     uint256 s0abs = uint256(uint128(-a0));
        //     uint256 curS0 = marketSettled[corePoolId][0];
        //     marketSettled[corePoolId][0] = s0abs > curS0 ? 0 : (curS0 - s0abs);
        // }
        // if (a1 > 0) {
        //     marketSettled[corePoolId][1] += uint256(uint128(a1));
        // } else if (a1 < 0) {
        //     uint256 s1abs = uint256(uint128(-a1));
        //     uint256 curS1 = marketSettled[corePoolId][1];
        //     marketSettled[corePoolId][1] = s1abs > curS1 ? 0 : (curS1 - s1abs);
        // }

        // Record ring settlement events for both tokens (positive=settle, negative=withdraw)
        if (amount0 != 0) {
            _recordSettlement(positionPoolId[positionId], 0, amount0, 0, PositionId.unwrap(positionId), amount0 < 0); // burn tokens if amount0 is negative
        }
        if (amount1 != 0) {
            _recordSettlement(positionPoolId[positionId], 1, amount1, 0, PositionId.unwrap(positionId), amount1 < 0); // burn tokens if amount1 is negative
        }
    }

    // /**
    //  * @notice Gets the current vts for a position
    //  * @param positionId The position id
    //  * @return vtsCurrent0 The current vts for token0
    //  * @return vtsCurrent1 The current vts for token1
    //  */
    // function getVTSCurrent(PositionId positionId)
    //     public
    //     view
    //     virtual
    //     returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    // {
    //     uint256 c0 = commitmentMaxima[positionId][0];
    //     uint256 c1 = commitmentMaxima[positionId][1];
    //     if (c0 == 0 && c1 == 0) {
    //         revert InvalidPosition(positionId);
    //     }

    //     uint256 s0 = totalSettlementAmount[positionId][0];
    //     uint256 s1 = totalSettlementAmount[positionId][1];

    //     return VTSCalculatorLib.calcVTSCurrent(s0, s1, c0, c1);
    // }

    // /**
    //  * @notice Gets the required vts for a position
    //  * @dev this function is virtual and can be overridden in order to mock the values
    //  * @param _positionId The position id
    //  * @return vtsRequired0 The required vts for token0
    //  * @return vtsRequired1 The required vts for token1
    //  */
    // function getVTSRequired(PositionId _positionId)
    //     public
    //     view
    //     virtual
    //     returns (uint256 vtsRequired0, uint256 vtsRequired1)
    // {
    //     // Position metadata
    //     PositionMeta memory meta = positionIndex.getMeta(_positionId);
    //     PoolId corePoolId = meta.poolId;
    //     if (PoolId.unwrap(corePoolId) == bytes32(0)) {
    //         revert InvalidPosition(_positionId);
    //     }

    //     // Commitment caps
    //     uint256 c0 = commitmentMaxima[_positionId][0];
    //     uint256 c1 = commitmentMaxima[_positionId][1];
    //     if (c0 == 0 && c1 == 0) {
    //         revert InvalidPosition(_positionId);
    //     }

    //     // If calculator is set, try calculator first (not implemented here)
    //     if (address(calculator) != address(0)) {
    //         return (0, 0);
    //     }

    //     // Delegate to oracle-aware calculator library (falls back to on-chain if coverage ok)
    //     (uint256 v0, uint256 v1,) = VTSCalculatorLib.calcVTSRequiredWithOracleSupport(
    //         this, _positionId, meta, positionIndex, c0, c1, oracleAdapter
    //     );
    //     return (v0, v1);
    // }

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
     * @notice Gets the RFS for a position
     * @param _positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
     */
    function getRFS(PositionId _positionId) public view isPositionValid(_positionId) returns (bool, BalanceDelta) {
        // Commitment caps
        (uint256 c0, uint256 c1) = _getCommitment(_positionId);

        uint256 s0 = totalSettlementAmount[_positionId][0];
        uint256 s1 = totalSettlementAmount[_positionId][1];

        // If calculator is set, try calculator first (not implemented here)
        if (address(calculator) != address(0)) {
            return (false, toBalanceDelta(0, 0));
        }

        // TODO: Use usedOracle to determine excess gas to compensate?
        // Compute weight inputs from on-chain liquidity
        // (uint128 liqPos, uint256 liqPool) = _getLiquidityShareForPosition(corePoolId, _positionId);

        // Pull aggregates for market-level settled/committed/deficit and window outflows
        // uint256 aggS0 = marketSettled[corePoolId][0];
        // uint256 aggS1 = marketSettled[corePoolId][1];
        // uint256 aggC0 = marketCommitted[corePoolId][0];
        // uint256 aggC1 = marketCommitted[corePoolId][1];
        // uint256 aggD0 = marketDeficitOutstanding[corePoolId][0];
        // uint256 aggD1 = marketDeficitOutstanding[corePoolId][1];
        // uint256 aggS0 = 0;
        // uint256 aggS1 = 0;
        // uint256 aggC0 = 0;
        // uint256 aggC1 = 0;
        // uint256 aggD0 = 0;
        // uint256 aggD1 = 0;
        // (uint256 totalOutflow0, uint256 totalOutflow1) = getMarketOutflow(corePoolId);

        (bool rfsOpen, BalanceDelta balanceDelta,) = VTSCalculatorLib.calcRFS(
            this, _positionId, positionIndex.getMeta(_positionId), positionIndex, c0, c1, s0, s1, oracleAdapter
        );
        return (rfsOpen, balanceDelta);
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
