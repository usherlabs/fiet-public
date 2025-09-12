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

abstract contract VTSManager is IVTSManager {
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

    error InvalidCaller();
    error InvalidMarketVTSConfiguration(PoolId corePoolId);

    // Event to notify that the VTS configuration has been set/initialized for a core pool
    event VTSConfigurationSet(PoolId indexed corePoolId, MarketVTSConfiguration indexed vtsConfiguration);
    // Event to notify that the assets have been settled on a position
    event AssetsSettled(PositionId indexed positionId, uint256 amount0, uint256 amount1);

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
     * @notice Calculates the maximum potential commitment for two tokens in a position
     * @param corePoolKey The core pool key
     * @param amountToken0 The amount of token0 in the position
     * @param amountToken1 The amount of token1 in the position
     * @return c0 The maximum potential commitment for token0
     * @return c1 The maximum potential commitment for token1
     */
    function calculateMaxPotentialCommitment(PoolKey memory corePoolKey, uint256 amountToken0, uint256 amountToken1)
        public
        view
        returns (uint256 c0, uint256 c1)
    {
        // get the market oracle factory
        uint256 lcc0Decimals = LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency0)).decimals();
        uint256 lcc1Decimals = LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency1)).decimals();

        // The commitment formula is:
        // C(r) = ½(V₀ · C₀(r) + V₁ · C₁(r))
        // C(r) = xr + yr
        // By substitution: C₀(r) = (2xr) / V₀, C₁(r) = (2yr) / V₁

        // In our context:
        // - V₀ = price (token1 per token0) - the pool's exchange rate
        // - V₁ = 1 (token1 per token1) - token1 is our base currency
        // - xr = amountToken0 * price (value of token0 in token1 units)
        // - yr = amountToken1 (value of token1 in token1 units)

        // Applying the formula:
        // C₀(r) = (2xr) / V₀ = (2 * amountToken0 * price) / price = 2 * amountToken0
        // C₁(r) = (2yr) / V₁ = (2 * amountToken1) / 1 = 2 * amountToken1

        // The price terms cancel out because:
        // - We're using the pool's exchange rate as the "price"
        // - When we multiply by price to get value, then divide by price to get back to units
        // - The price scaling cancels out, leaving just the 2x multiplier

        // This means the "maximum potential commitment" is simply 2x the deposited amounts
        // The formula doesn't add complexity when using pool price as relative price

        // calculate Commitments and scale the amounts by the decimals of the LCC tokens
        c0 = ((2 * amountToken0) / (10 ** lcc0Decimals));
        c1 = ((2 * amountToken1) / (10 ** lcc1Decimals));
    }

    /**
     * @notice Tracks the maximum potential commitment for both tokens in a position
     * @param corePoolKey The core pool key
     * @param router The sender of the transaction
     * @param params The parameters of the transaction
     * @param delta The delta of the transaction
     */
    function _trackMaxPotentialCommitment(
        PoolKey memory corePoolKey,
        address router,
        ModifyLiquidityParams calldata params,
        BalanceDelta delta
    ) public {
        PositionId positionId = PositionLibrary.generateId(router, params);

        bool isLiquidityAddition = params.liquidityDelta > 0;

        uint256 amount0 = LiquidityUtils.safeInt128ToUint256(delta.amount0());
        uint256 amount1 = LiquidityUtils.safeInt128ToUint256(delta.amount1());

        uint256 c0 = 0;
        uint256 c1 = 0;
        if (isLiquidityAddition) {
            (c0, c1) = calculateMaxPotentialCommitment(corePoolKey, amount0, amount1);
        }
        // update the max potential commitments for the tokens in the range of the position
        maxPotentialCommitment[positionId][0] = c0;
        maxPotentialCommitment[positionId][1] = c1;
    }

    /**
     * @notice Records the settlement of assets on a position
     * @dev make sure this function can only be called by the position manager since that is the interface through which settlements are going to be made
     * @param positionId The id of the position
     * @param amount0 The amount of token0 settled
     * @param amount1 The amount of token1 settled
     */
    function onSettleAssets(PositionId positionId, uint256 amount0, uint256 amount1) external {
        if (msg.sender != mmPositionManager) {
            revert InvalidCaller();
        }

        totalSettlementAmount[positionId][0] += amount0;
        totalSettlementAmount[positionId][1] += amount1;

        // emit an event to notify that the assets have been settled on a position
        emit AssetsSettled(positionId, amount0, amount1);
    }

    /**
     * @notice Gets the current vts for a position
     * @param corePoolId The core pool id
     * @param positionId The position id
     * @return vtsCurrent0 The current vts for token0
     * @return vtsCurrent1 The current vts for token1
     */
    function getVTSCurrent(PoolId corePoolId, PositionId positionId)
        public
        pure
        returns (uint256 vtsCurrent0, uint256 vtsCurrent1)
    {
        // MarketVTSConfiguration memory vtsConfiguration = corePoolToVTSConfiguration[corePoolId];
        corePoolId;
        positionId;
        // TODO: Call the library method to get the current vts using the linked library
        return (0, 0);
    }
}
