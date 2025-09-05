// SPDX-License-Identifier: MIT
// This contract is inherited by the core hook contract and it is responsible for tracking state wide variables for the VTS
pragma solidity ^0.8.0;

import {MarketVTSConfiguration} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {RollingOutflowTracker, RollingOutflowTrackerLibrary} from "../libraries/RollingOutflow.sol";

abstract contract VTSManager {
    using RollingOutflowTrackerLibrary for RollingOutflowTracker;

    // Mapping from core pool ID to VTS configuration
    mapping(PoolId => MarketVTSConfiguration) public corePoolToVTSConfiguration;
    // Mapping from core pool ID to rolling outflow tracker
    mapping(PoolId => RollingOutflowTracker) public marketOutflow;

    error InvalidCaller();
    error InvalidMarketVTSConfiguration(PoolId corePoolId);

    address private immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
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
        // get the time window from the VTS configuration
        int256 delta0 = delta.amount0();
        int256 delta1 = delta.amount1();

        // Extract outflow amounts (negative deltas indicate outflow)
        uint256 outflow0 = delta0 < 0 ? uint256(-delta0) : 0;
        uint256 outflow1 = delta1 < 0 ? uint256(-delta1) : 0;

        // Record both outflows (even if one is 0)
        marketOutflow[corePoolId].recordOutflow(outflow0, outflow1);
    }
}
