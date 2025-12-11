// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Errors} from "../libraries/Errors.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";

/// @notice Abstract handler for market operations. Receives the MarketFactory in the constructor for read and write access.
abstract contract MarketHandler {
    IMarketFactory public immutable marketFactory;

    constructor(address _marketFactory) {
        marketFactory = IMarketFactory(_marketFactory);
    }

    modifier onlyFactory() {
        if (msg.sender != address(marketFactory)) revert Errors.InvalidSender();
        _;
    }

    modifier onlyBounds() {
        if (!marketFactory.bounds(msg.sender)) {
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

    function _corePoolToCurrencyPair(PoolId poolId) internal view returns (address[2] memory) {
        return marketFactory.corePoolToCurrencyPair(poolId);
    }

    function _vaultToCurrencyPair(address vault) internal view virtual returns (address[2] memory) {
        return marketFactory.proxyHookToCurrencyPair(vault);
    }

    function _getVault(PoolId poolId) internal view returns (IMarketVault) {
        return IMarketVault(marketFactory.corePoolToProxyHook(poolId));
    }

    function _validateToken(address token, address[2] memory currencies) internal view virtual returns (uint8) {
        if (token == currencies[0]) {
            return 0;
        } else if (token == currencies[1]) {
            return 1;
        } else {
            revert Errors.InvalidSender();
        }
    }

    function _getTokenIndex(PoolId poolId, address token) internal view returns (uint8) {
        address[2] memory currencies = _corePoolToCurrencyPair(poolId);
        return _validateToken(token, currencies);
    }
}
