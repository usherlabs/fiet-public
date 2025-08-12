// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Mock implementation of MarketDebtQueue for testing purposes.
// This contract provides a concrete implementation of the abstract MarketDebtQueue
// contract, allowing us to test the market-specific debt queue functionality without requiring
// actual token transfers. It tracks transfers via events and counters instead
// of performing real token movements, making it suitable for unit testing
// the cumulative debt logic, smallest-first payment order, and market-specific debt tracking features.

import {MarketLiquidityDebt} from "../../src/modules/MarketLiquidityDebt.sol";

contract MockDebtQueue is MarketLiquidityDebt {
    // Mock token address for testing
    address public mockAsset;
    // Track total amount transferred for verification
    uint256 public totalTransferred;

    event MockTransfer(address indexed user, uint256 amount);

    constructor(address _mockAsset) {
        mockAsset = _mockAsset;
    }

    /**
     * @notice Implements abstract function from MarketDebtQueue - tracks transfers without actual token movement
     * @param user The user to pay the debt to
     * @param amount The amount of debt to pay
     */
    function _payMarketDebt(address user, uint256 amount) internal override {
        totalTransferred += amount;
        // burn tokens
        emit MockTransfer(user, amount);
    }

    /**
     * @notice Exposes internal function for testing - adds market debt request (cumulative)
     * @param marketId The market ID
     * @param user The user to add the debt request for
     * @param amount The amount of debt to add
     */
    function addMarketDebtRequest(bytes32 marketId, address user, uint256 amount) external {
        _addMarketDebtRequest(marketId, user, amount);
    }

    /**
     * @notice Exposes internal function for testing - processes market debt queue with available liquidity
     * @param marketId The market ID
     * @param availableLiquidity The available liquidity in the market
     * @return The amount processed from the debt queue
     */
    function processMarketDebtQueue(bytes32 marketId, uint256 availableLiquidity) external returns (uint256) {
        return _processMarketDebtQueue(marketId, availableLiquidity, true);
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
     * @notice Returns debt owed to a specific user in a market
     * @param marketId The market ID
     * @param user The user to get the debt for
     * @return The amount of debt owed to the user
     */
    function getUserDebt(bytes32 marketId, address user) external view returns (uint256) {
        return marketUserDebt[marketId][user];
    }

    /**
     * @notice Returns whether user has debt in a market
     * @param marketId The market ID
     * @param user The user to check the debt for
     * @return Whether the user has debt in the market
     */
    function userHasDebt(bytes32 marketId, address user) external view returns (bool) {
        return hasDebt[marketId][user];
    }
}
