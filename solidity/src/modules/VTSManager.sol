// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.0;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TimeBucketOutflowTracker, TimeBucketOutflowTrackerLibrary} from "../libraries/TimeBucket.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityCommitmentCertificate} from "../LCC.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SafeCastLib} from "v4-periphery/lib/v4-core/lib/solmate/src/utils/SafeCastLib.sol";
import {LiquidityUtils} from "../libraries/LiquidityUtils.sol";
import {console} from "forge-std/console.sol";
import {PositionLibrary, PositionId} from "../types/Position.sol";
import {IVTSManager} from "../interfaces/IVTSManager.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {FixedPoint96} from "v4-periphery/lib/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "v4-periphery/lib/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "v4-periphery/lib/v4-core/src/libraries/SqrtPriceMath.sol";
import {BalanceDeltaLibrary, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

abstract contract VTSManager is IVTSManager {
    using SafeCastLib for *;
    using TimeBucketOutflowTrackerLibrary for TimeBucketOutflowTracker;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;

    // Mapping from core pool ID to VTS configuration
    mapping(PoolId => MarketVTSConfiguration) public corePoolToVTSConfiguration;
    // Mapping from core pool ID to rolling outflow tracker
    mapping(PoolId => TimeBucketOutflowTracker) public marketOutflow;
    // Mapping to store maximum potential commitment for each position
    mapping(PositionId => uint256[2]) internal maxPotentialCommitment;
    // Mapping to store the total settlement amount for each position
    mapping(PositionId => uint256[2]) internal totalSettlementAmount;
    // Mapping to store the commitment
    mapping(PositionId => uint256[2]) internal commitment;

    error InvalidCaller();
    error InvalidMarketVTSConfiguration(PoolId corePoolId);
    error NotEnoughSettlementBalance(uint256 amount0, uint256 amount1);

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event VTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    // Event to notify that the assets have been settled on a position
    event AssetsSettled(PositionId indexed positionId, int128 amount0, int128 amount1);

    address private immutable marketFactory;
    address private immutable mmPositionManager;
    IPoolManager private immutable poolManager;

    constructor(address _poolManager, address _marketFactory, address _mmPositionManager) {
        poolManager = IPoolManager(_poolManager);
        marketFactory = _marketFactory;
        mmPositionManager = _mmPositionManager;
    }

    /**
     * @notice Sets the VTS configuration for a core pool
     * @param corePoolId The core pool ID
     * @param vtsConfiguration The VTS configuration
     */
    function setMarketVTSConfiguration(PoolId corePoolId, MarketVTSConfiguration memory vtsConfiguration) public {
        if (msg.sender != marketFactory) {
            revert InvalidCaller();
        }
        corePoolToVTSConfiguration[corePoolId] = vtsConfiguration;
        marketOutflow[corePoolId].initialize(vtsConfiguration.timeWindow);

        emit VTSConfigurationSet(corePoolId, vtsConfiguration);
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
    function _recordOutflow(PoolId corePoolId, BalanceDelta delta) internal {
        // Extract outflow amounts (negative deltas indicate outflow)
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        uint256 outflow0 = delta0 < 0 ? uint256(-delta0) : 0;
        uint256 outflow1 = delta1 < 0 ? uint256(-delta1) : 0;

        // Record both outflows (even if one is 0)
        marketOutflow[corePoolId].recordOutflow(outflow0, outflow1);
    }

    /**
     * @notice Calculates the maximum potential commitment for both tokens over a tick range for a given liquidity
     * @dev Uses CLMM formulas based on tick bounds and liquidity. Results are in raw token units.
     * @param tickLower The lower tick bound of the position
     * @param tickUpper The upper tick bound of the position
     * @param liquidity The position liquidity to evaluate against the tick range
     * @return c0 The maximum potential commitment for token0 over [tickLower, tickUpper]
     * @return c1 The maximum potential commitment for token1 over [tickLower, tickUpper]
     */
    function calculateMaxPotentialCommitment(int24 tickLower, int24 tickUpper, uint128 liquidity)
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
     * @param corePoolKey The core pool key
     * @param router The sender of the transaction
     * @param params The parameters of the transaction
     * @param delta The delta of the transaction
     */
    function _trackCommitment(
        PoolKey memory corePoolKey,
        address router,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta
    ) public {
        PositionId positionId = PositionLibrary.generateId(router, params);

        bool isLiquidityAddition = params.liquidityDelta > 0;

        // the maximum potential commitment for the token0
        uint256 c0 = 0;
        // the maximum potential commitment for the token1
        uint256 c1 = 0;
        // the amounts committed for the token0
        uint256 a0 = 0;
        // the amounts committed for the token1
        uint256 a1 = 0;
        if (isLiquidityAddition) {
            // Compute maxima for the liquidity being added over the specified tick range
            uint128 liquidityAdded = SafeCastLib.safeCastTo128(uint256(params.liquidityDelta));
            (c0, c1) = calculateMaxPotentialCommitment(params.tickLower, params.tickUpper, liquidityAdded);
            a0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
            a1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());
        }

        // in the case of liquidity removal, all these values will be s
        // update the max potential commitments for the tokens in the range of the position
        maxPotentialCommitment[positionId][0] = c0;
        maxPotentialCommitment[positionId][1] = c1;
        // update the amounts committed for the tokens in the range of the position
        commitment[positionId][0] = a0;
        commitment[positionId][1] = a1;
    }

    /**
     * @notice Records the settlement of assets on a position
     * @dev make sure this function can only be called by the position manager since that is the interface through which settlements are going to be made
     * @param positionId The id of the position
     * @param balanceDelta The balance delta of the settlement
     */
    function onMMLiquidityModify(PositionId positionId, BalanceDelta balanceDelta) external {
        if (msg.sender != mmPositionManager) {
            revert InvalidCaller();
        }
        int128 amount0 = balanceDelta.amount0();
        int128 amount1 = balanceDelta.amount1();

        totalSettlementAmount[positionId][0] =
            _updateSettlement(totalSettlementAmount[positionId][0], balanceDelta.amount0());
        totalSettlementAmount[positionId][1] =
            _updateSettlement(totalSettlementAmount[positionId][1], balanceDelta.amount1());

        // emit an event to notify that the assets have been settled on a position
        emit AssetsSettled(positionId, amount0, amount1);
    }

    /**
     * @notice Gets the current vts for a position
     * @param positionId The position id
     * @return vtsCurrent0 The current vts for token0
     * @return vtsCurrent1 The current vts for token1
     */
    function getVTSCurrent(PositionId positionId) public view returns (uint256 vtsCurrent0, uint256 vtsCurrent1) {
        uint256 commitment0 = commitment[positionId][0];
        uint256 commitment1 = commitment[positionId][1];
        uint256 totalSettlementAmount0 = totalSettlementAmount[positionId][0];
        uint256 totalSettlementAmount1 = totalSettlementAmount[positionId][1];

        // VTS  is total commited / total settled expressed in basis points
        vtsCurrent0 = commitment0 > 0 ? (totalSettlementAmount0 * 10000) / commitment0 : 0;
        vtsCurrent1 = commitment1 > 0 ? (totalSettlementAmount1 * 10000) / commitment1 : 0;
    }

    /**
     * @notice Gets the required vts for a position
     * @dev this function is virtual and can be overridden in order to mock the values
     * @param _positionId The position id
     * @return vtsRequired0 The required vts for token0
     * @return vtsRequired1 The required vts for token1
     */
    function getVTSRequired(PositionId _positionId)
        public
        view
        virtual
        returns (uint256 vtsRequired0, uint256 vtsRequired1)
    {
        // TODO: use linked libraries to derive the required vts for this position using the stateful parameters
        return (0, 0);
    }

    /**
     * @notice Gets the RFS for a position
     * @param positionId The position id
     * @return rfsOpen Whether the RFS is open
     * @return balanceDelta The balance delta of the amount of required to be settled or allowed to be withdrawn depending on if it is negative or positive
     */
    function getRFS(PositionId positionId) public view returns (bool, BalanceDelta) {
        uint256 commitment0 = commitment[positionId][0];
        uint256 commitment1 = commitment[positionId][1];

        // get vts current
        (uint256 vtsCurrent0, uint256 vtsCurrent1) = getVTSCurrent(positionId);
        // get vts required
        (uint256 vtsRequired0, uint256 vtsRequired1) = getVTSRequired(positionId);

        // is rfs open if vts current is less than vts required for either currency0 or currency 1
        bool rfsOpen = vtsCurrent0 < vtsRequired0 || vtsCurrent1 < vtsRequired1;

        // get the balance delta required to be settled
        // the delta could either be positive or negative
        // if positive, it means the mm can withdraw the positive amount specified
        // if negative, it means the mm needs to settle the negative amount specified to at least meet the required vts treshold
        int128 delta0 = int128(int256(vtsCurrent0) - int256(vtsRequired0));
        int128 delta1 = int128(int256(vtsCurrent1) - int256(vtsRequired1));

        // calculate the fraction of commitment based on delta (in bps)
        int128 commitmentFraction0 = (int128(int256(commitment0)) * delta0) / 10000;
        int128 commitmentFraction1 = (int128(int256(commitment1)) * delta1) / 10000;

        BalanceDelta balanceDelta = toBalanceDelta(commitmentFraction0, commitmentFraction1);

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
