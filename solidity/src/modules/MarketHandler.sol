// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Abstract handler for market operations. Receives the MarketFactory in the constructor for read and write access.
abstract contract MarketHandler {
    error InvalidCaller();

    address public immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
    }

    modifier onlyMarketFactory() {
        if (msg.sender != marketFactory) revert InvalidCaller();
        _;
    }

    modifier onlyBounds() {
        if (!IMarketFactory(marketFactory).bounds(msg.sender)) {
            revert InvalidCaller();
        }
        _;
    }

    modifier onlyMarketAssets(PoolId poolId) {
        address[2] memory currencies = IMarketFactory(marketFactory).corePoolToCurrencyPair(poolId);
        if (msg.sender != currencies[0] && msg.sender != currencies[1]) {
            revert InvalidCaller();
        }
        _;
    }
}
