// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/**
 * @title IHookPausable
 * @notice Interface for the PausableMarket contract that provides per-pool pausing functionality.
 */
interface IHookPausable {
    function pause(PoolId poolId) external;

    function unpause(PoolId poolId) external;
}
