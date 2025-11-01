// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// Mock implementation of MarketSettlementQueue for testing purposes.
// This contract provides a concrete implementation of the abstract MarketSettlementQueue
// contract, allowing us to test the market-specific settlement queue functionality without requiring
// actual token transfers. It tracks transfers via events and counters instead
// of performing real token movements, making it suitable for unit testing
// the cumulative settlement logic, smallest-first payment order, and market-specific settlement tracking features.

import {MarketLiquidity} from "../../src/modules/MarketLiquidity.sol";

contract MockSettlementQueue is MarketLiquidity {
    // Mock token address for testing
    address public mockAsset;
    // Track total amount transferred for verification
    uint256 public totalTransferred;

    event MockTransfer(address indexed user, uint256 amount);

    constructor(address _mockAsset) {
        mockAsset = _mockAsset;
    }

    /**
     * @notice Implements abstract function from MarketSettlementQueue - tracks transfers without actual token movement
     * @param user user
     * @param amount amount
     */
    function _payOutstandingSettlementToUser(address user, uint256 amount) internal override {
        totalTransferred += amount;
        // burn tokens
        emit MockTransfer(user, amount);
    }

    /**
     * @notice Exposes internal function for testing - adds market settlement request (cumulative)
     * @param marketId The market ID
     * @param user The user to add the settlement for
     * @param amount The amount to add
     */
    function addMarketSettlementRequest(bytes32 marketId, address user, uint256 amount) external {
        _addToSettlementQueue(marketId, user, amount);
    }

    /**
     * @notice Exposes internal function for testing - processes market settlement queue with available liquidity
     * @param marketId The market ID
     * @param availableLiquidity The available liquidity in the market
     * @return The amount processed from the settlement queue
     */
    function processMarketSettlementQueue(bytes32 marketId, uint256 availableLiquidity) external returns (uint256) {
        return _processSettlementQueue(marketId, availableLiquidity, true);
    }

    /**
     * @notice Exposes internal function for testing - tracks market acquisition
     * @param user The user to track the market acquisition for
     * @param marketId The market ID
     * @param amount The amount of LCC acquired
     */
    function trackMarketAcquisition(address user, bytes32 marketId, uint256 amount) external {
        _trackMarketAcquisition(user, marketId, amount);
    }

    /**
     * @notice Returns settlement owed to a specific user in a market
     * @param marketId The market ID
     * @param user The user to get the settlement for
     * @return The amount owed to the user
     */
    function getUserSettlement(bytes32 marketId, address user) external view returns (uint256) {
        return marketUserSettlement[marketId][user];
    }

    /**
     * @notice Returns whether user has pending settlement in a market
     * @param marketId The market ID
     * @param user The user to check the pending settlement for
     * @return Whether the user has pending settlement in the market
     */
    function userHasPendingSettlement(bytes32 marketId, address user) external view returns (bool) {
        return hasPendingSettlement[marketId][user];
    }
}
