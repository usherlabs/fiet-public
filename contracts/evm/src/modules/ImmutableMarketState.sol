// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title Immutable Market State
/// @notice A collection of immutable state variables for market operations, commonly used across multiple contracts
abstract contract ImmutableMarketState {
    /// @notice The MarketFactory contract
    IMarketFactory public immutable marketFactory;

    /// @notice Thrown when the caller is not MarketFactory
    error NotMarketFactory();

    /// @notice Only allow calls from the MarketFactory contract
    modifier onlyFactory() {
        _assertFactory(msg.sender);
        _;
    }

    modifier onlyFactoryWithSender(address sender) {
        _assertFactory(sender);
        _;
    }

    constructor(address _marketFactory) {
        if (_marketFactory == address(0)) revert Errors.InvalidSender();
        marketFactory = IMarketFactory(_marketFactory);
    }

    function _assertFactory(address sender) internal view {
        if (sender != address(marketFactory)) revert Errors.InvalidSender();
    }
}

