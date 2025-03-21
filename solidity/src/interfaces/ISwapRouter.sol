// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.24;

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

interface ISwapRouter {
    struct TestSettings {
        bool takeClaims;
        bool settleUsingBurn;
    }

    /**
     * @notice Executes a swap in the pool
     * @dev Swaps assets based on the provided pool key and swap parameters
     * @param key The pool key containing currency information
     * @param params The swap parameters including direction and amounts
     * @param testSettings Configuration settings for settlement and claims
     * @param hookData Additional data for hooks
     * @return delta The balance delta resulting from the swap
     */
    function swap(
        PoolKey memory key,
        IPoolManager.SwapParams memory params,
        TestSettings memory testSettings,
        bytes memory hookData
    ) external payable returns (BalanceDelta delta);
}
