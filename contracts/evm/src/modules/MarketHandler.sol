// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Errors} from "../libraries/Errors.sol";

/// @notice Abstract handler for market operations. Receives the MarketFactory in the constructor for read and write access.
abstract contract MarketHandler {
    address public immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = _marketFactory;
    }

    modifier onlyMarketFactory() {
        if (msg.sender != marketFactory) revert Errors.InvalidSender();
        _;
    }

    modifier onlyBounds() {
        if (!IMarketFactory(marketFactory).bounds(msg.sender)) {
            revert Errors.InvalidSender();
        }
        _;
    }

    modifier onlyMarketAssets(PoolId poolId) {
        _getTokenIndexFromCaller(poolId);
        _;
    }

    function _getTokenIndexFromCaller(PoolId poolId) internal view returns (uint8) {
        return _getTokenIndex(poolId, msg.sender);
    }

    function _getTokenIndex(PoolId poolId, address token) internal view returns (uint8) {
        address[2] memory currencies = IMarketFactory(marketFactory).corePoolToCurrencyPair(poolId);
        if (token == currencies[0]) {
            return 0;
        } else if (token == currencies[1]) {
            return 1;
        } else {
            revert Errors.InvalidSender();
        }
    }
}
