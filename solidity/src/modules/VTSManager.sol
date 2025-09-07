// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.0;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {RollingOutflowTracker, RollingOutflowTrackerLibrary} from "../libraries/RollingOutflow.sol";
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

abstract contract VTSManager is IVTSManager {
    using RollingOutflowTrackerLibrary for RollingOutflowTracker;

    // Mapping from core pool ID to VTS configuration
    mapping(PoolId => MarketVTSConfiguration) public corePoolToVTSConfiguration;
    // Mapping from core pool ID to rolling outflow tracker
    mapping(PoolId => RollingOutflowTracker) public marketOutflow;
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

    constructor(address _marketFactory, address _mmPositionManager) {
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
        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency0));
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(Currency.unwrap(corePoolKey.currency1));
        // get the total usd commitment for this position
        // decimals are negligable for price
        (uint256 lcc0Price, uint256 lcc0PriceDecimals) = lcc0.usdPrice();
        (uint256 lcc1Price, uint256 lcc1PriceDecimals) = lcc1.usdPrice();

        // Normalize to 18 decimals from whatever decimals it was(it should be 8 decimal from the oracle) for consistent calculations
        uint256 v0 = lcc0Price * (10 ** (18 - lcc0PriceDecimals));
        uint256 v1 = lcc1Price * (10 ** (18 - lcc1PriceDecimals));

        // we have a rool equation representing the relationship between the total commitment USD value for this position
        // and the maximum potential commitments for the tokens in the range of the position
        // C(r) = ½(V₀ · C₀(r) + V₁ · C₁(r))
        // C(r) = xr + yr
        // by substitution we get:
        // C₀(r) = (2xr) / V₀
        // C₁(r) = (2yr) / V₁
        // C₀(r) and C₁(r) are the maximum potential commitments for the tokens in the range of the position
        // xr and yr are the USD values of the total tokens in the position
        // V₀ and V₁ are the USD values of 1 unit of the token 0 and 1
        uint256 xr = (amountToken0 * v0) / 1e18;
        uint256 yr = (amountToken1 * v1) / 1e18;

        c0 = (2 * xr) / v0;
        c1 = (2 * yr) / v1;
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
    ) internal {
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
