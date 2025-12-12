// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract MockMarketFactory {
    mapping(PoolId => address[2]) public currencies;
    address public coreHook;

    function setCoreHook(address _hook) external {
        coreHook = _hook;
    }

    function setCurrencies(PoolId poolId, address c0, address c1) external {
        currencies[poolId] = [c0, c1];
    }

    function corePoolToCurrencyPair(PoolId poolId) external view returns (address[2] memory) {
        return currencies[poolId];
    }

    function getCoreHook() external view returns (address) {
        return coreHook;
    }

    function bounds(address) external pure returns (bool) {
        return false;
    }
}
