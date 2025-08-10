// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Mock implementation of MarketDebtQueue for testing purposes.
// This contract provides a concrete implementation of the abstract MarketDebtQueue
// contract, allowing us to test the market-specific debt queue functionality without requiring
// actual token transfers. It tracks transfers via events and counters instead
// of performing real token movements, making it suitable for unit testing
// the cumulative debt logic, smallest-first payment order, and market-specific debt tracking features.

import {MarketDebt} from "../../src/modules/MarketDebt.sol";

contract MockDebtQueue is MarketDebt {
    address public mockAsset; // Mock token address for testing
    uint256 public totalTransferred; // Track total amount transferred for verification

    event MockTransfer(address indexed user, uint256 amount);

    constructor(address _mockAsset) {
        mockAsset = _mockAsset;
    }

    /// @notice Implements abstract function from MarketDebtQueue - tracks transfers without actual token movement
    function _transferUnderlyingAssets(address user, uint256 amount) internal override {
        totalTransferred += amount;
        emit MockTransfer(user, amount);
    }

    /// @notice Exposes internal function for testing - adds market debt request (cumulative)
    function addMarketDebtRequest(bytes32 marketId, address user, uint256 amount) external {
        _addMarketDebtRequest(marketId, user, amount);
    }

    /// @notice Exposes internal function for testing - processes market debt queue with available liquidity
    function processMarketDebtQueue(bytes32 marketId, uint256 availableLiquidity) external returns (uint256) {
        return _processMarketDebtQueue(marketId, availableLiquidity);
    }

    /// @notice Exposes internal function for testing - tracks market acquisition
    function trackMarketAcquisition(address user, bytes32 marketId, uint256 amount) external {
        _trackMarketAcquisition(user, marketId, amount);
    }

    /// @notice Returns debt owed to a specific user in a market
    function getUserDebt(bytes32 marketId, address user) external view returns (uint256) {
        return marketUserDebt[marketId][user];
    }

    /// @notice Returns whether user has debt in a market
    function userHasDebt(bytes32 marketId, address user) external view returns (bool) {
        return hasDebt[marketId][user];
    }
}
