// SPDX-License-Identifier: MIT
// This contract is inherited by the Liquidity Commitment Certificate contract to handle the pending settlements that occur when an unwrap fails and liquidity has to be queued
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract MarketLiquidity {
    // When a settlement request is added to the queue
    event SettlementRequestQueued(
        bytes32 indexed marketId, address indexed recipient, uint256 amount, uint256 timestamp
    );

    // When a settlement request is settled/cleared
    event SettlementRequestCleared(
        bytes32 indexed marketId,
        address indexed recipient,
        uint256 amount,
        uint256 queueIndex,
        uint256 timestamp,
        bool tokensBurned
    );

    // Events for market tracking
    event MarketRegistered(bytes32 indexed marketId);
    event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
    event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);

    // Market tracking state variables
    bytes32[] public knownMarkets; // List of known markets
    mapping(bytes32 => bool) public isMarketKnown; // Quick lookup for market existence
    mapping(bytes32 => uint256) public marketLiquidityReserves; // Market-specific underlying liquidity

    // Market-specific settlement queues
    mapping(bytes32 => mapping(address => uint256)) public marketUserSettlement; // marketId => recipient => amount we owe them
    mapping(bytes32 => uint256) public marketTotalSettlement; // Total amount we owe per market
    mapping(bytes32 => address[]) public marketSettlementRecipients; // List of addresses with pending settlements to per market
    mapping(bytes32 => mapping(address => bool)) public hasPendingSettlement; // Quick lookup for who has a pending settlement with the market

    // Market specific balances for each user
    mapping(address => mapping(bytes32 => uint256)) public userMarketBalances; // User balance per market

    /**
     * @dev Gets the total pending settlement for a specific market
     * @param marketId The market ID
     * @return The total pending settlement for this market
     *
     */
    function getMarketTotalSettlement(bytes32 marketId) external view returns (uint256) {
        return marketTotalSettlement[marketId];
    }

    /**
     * @dev Gets market liquidity reserves
     * @param marketId The market ID
     * @return The amount of liquidity reserves for this market
     *
     */
    function getMarketLiquidityReserves(bytes32 marketId) external view returns (uint256) {
        return marketLiquidityReserves[marketId];
    }

    /**
     * @dev Gets a user's balance from a specific market
     * @param user The user address
     * @param marketId The market ID
     * @return The user's balance from this market
     *
     */
    function getUserMarketBalance(address user, bytes32 marketId) external view returns (uint256) {
        return userMarketBalances[user][marketId];
    }

    /**
     * @dev Gets the number of pending settlement holders for a specific market
     * @param marketId The market ID
     * @return The number of pending settlement holders in this market
     */
    function getNumPendingSettlementOwners(bytes32 marketId) external view returns (uint256) {
        return marketSettlementRecipients[marketId].length;
    }

    /**
     * @dev Gets the sum of all user balances across all markets
     * @return The total balance across all markets for all users
     */
    function _getTotalMarketBalances() internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < knownMarkets.length; i++) {
            bytes32 marketId = knownMarkets[i];
            total += marketLiquidityReserves[marketId];
        }
        return total;
    }

    /**
     * @dev Records liquidity added to a market (called by ProxyHook)
     *      Tracks how much of the UA is accounted for by this market,
     *      i.e how much of the UA is available for tokens gotten from this market that want to be unwrapped
     * @param marketId The market that received liquidity
     * @param amount The amount of liquidity added
     */
    function _trackMarketLiquidity(bytes32 marketId, uint256 amount) internal {
        // Auto-register Market if new
        _registerMarket(marketId);
        marketLiquidityReserves[marketId] += amount;
        emit MarketLiquidityAdded(marketId, amount);
    }

    /**
     * @dev Deducts liquidity from a market's underlying liquidity reserves,
     * @dev If not enough then use all liquidity present for the market
     * @param marketId The market to use liquidity from
     * @param amount The amount of liquidity to use
     * @return actualAmount The actual amount used (may be less if insufficient liquidity is present)
     */
    function _useMarketLiquidity(bytes32 marketId, uint256 amount) internal returns (uint256 actualAmount) {
        uint256 available = marketLiquidityReserves[marketId];
        actualAmount = Math.min(amount, available);

        if (actualAmount > 0) {
            marketLiquidityReserves[marketId] -= actualAmount;
            emit MarketLiquidityUsed(marketId, actualAmount);
        }
    }

    /**
     * @dev Registers a new market for tracking
     * @param marketId The market ID to register
     */
    function _registerMarket(bytes32 marketId) internal {
        if (!isMarketKnown[marketId] && marketId != bytes32(0)) {
            knownMarkets.push(marketId);
            isMarketKnown[marketId] = true;
            emit MarketRegistered(marketId);
        }
    }

    /**
     * @dev Adds a settlement request to the queue
     * @param marketId The market ID with pending settlements
     * @param recipient The address with pending settlements
     * @param amount The amount to eventually settle
     */
    function _addToSettlementQueue(bytes32 marketId, address recipient, uint256 amount) internal {
        // Add to amount we owe this recipient for this market
        if (marketUserSettlement[marketId][recipient] == 0) {
            // First settlement to this recipient in this market
            marketSettlementRecipients[marketId].push(recipient);
            hasPendingSettlement[marketId][recipient] = true;
        }

        marketUserSettlement[marketId][recipient] += amount;
        marketTotalSettlement[marketId] += amount;

        emit SettlementRequestQueued(marketId, recipient, amount, block.timestamp);
    }

    /**
     * @dev Removes a settlement request from record
     */
    function _removeSettlementRequest(bytes32 marketId, address user) internal {
        address[] storage settlementRecipients = marketSettlementRecipients[marketId];
        for (uint256 i = 0; i < settlementRecipients.length; i++) {
            if (settlementRecipients[i] == user) {
                settlementRecipients[i] = settlementRecipients[settlementRecipients.length - 1];
                settlementRecipients.pop();
                break;
            }
        }
    }

    /**
     * @dev Gets the sum of a user's balances across all markets
     * @param user The user address
     * @return The total balance across all markets
     */
    function _getUserTotalMarketBalance(address user) internal view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < knownMarkets.length; i++) {
            total += userMarketBalances[user][knownMarkets[i]];
        }
        return total;
    }

    /**
     * @dev Gets the total pending settlements for a specific recipient across all markets
     * @param recipient The address to check
     * @return totalUserSettlement The total pending settlements across all markets
     */
    function _getUserPendingSettlement(address recipient) internal view returns (uint256 totalUserSettlement) {
        totalUserSettlement = 0;

        for (uint256 i = 0; i < knownMarkets.length; i++) {
            bytes32 marketId = knownMarkets[i];
            totalUserSettlement += marketUserSettlement[marketId][recipient];
        }
    }

    /**
     * @dev Tracks when a user acquires LCC from a specific market
     * @param user The user acquiring LCC
     * @param marketId The market ID they acquired from
     * @param amount The amount of LCC acquired
     */
    function _trackMarketAcquisition(address user, bytes32 marketId, uint256 amount) internal {
        // Register the market if it is not already registered
        _registerMarket(marketId);

        userMarketBalances[user][marketId] += amount;
    }

    /**
     * @dev Gets all markets a user has LCC from
     * @param user The user address
     * @return Array of market IDs the user has balances in
     */
    function _getUserMarkets(address user) public view returns (bytes32[] memory) {
        bytes32[] memory userMarkets = new bytes32[](knownMarkets.length);
        uint256 count = 0;

        for (uint256 i = 0; i < knownMarkets.length; i++) {
            bytes32 marketId = knownMarkets[i];
            if (userMarketBalances[user][marketId] > 0) {
                userMarkets[count] = marketId;
                count++;
            }
        }
        return userMarkets;
    }

    /**
     * @dev Partially or Completely Process the market settlement queue
     * @param marketId The market to process the settlement queue for
     * @param availableLiquidity The available liquidity in the market
     * @param burnTokens Whether to burn the equivalent LCC tokens for the settlement settled
     * @return processedAmount The amount processed from the settlement queue
     */
    function _processSettlementQueue(bytes32 marketId, uint256 availableLiquidity, bool burnTokens)
        internal
        returns (uint256 processedAmount)
    {
        uint256 remainingLiquidity = Math.min(availableLiquidity, marketTotalSettlement[marketId]);

        address[] memory settlementRecipients = marketSettlementRecipients[marketId];

        for (uint256 i = 0; i < settlementRecipients.length && remainingLiquidity > 0; i++) {
            address recipient = settlementRecipients[i];
            uint256 amount = marketUserSettlement[marketId][recipient];

            if (amount == 0) continue; // Skip fully paid settlements

            uint256 amountToSettle = Math.min(remainingLiquidity, amount);

            // Update amount we owe
            marketUserSettlement[marketId][recipient] -= amountToSettle;
            marketTotalSettlement[marketId] -= amountToSettle;

            // Update the remaining liquidity and processed amount for this iteration
            remainingLiquidity -= amountToSettle;
            processedAmount += amountToSettle;

            // If amount fully paid, remove from pending settlement holders list
            if (marketUserSettlement[marketId][recipient] == 0) {
                hasPendingSettlement[marketId][recipient] = false;
                _removeSettlementRequest(marketId, recipient);
            }

            // burn the equivalent LCC Tokens for this user's amount that was just paid off
            // and transfer the underlying assets to the recipient of the settlement
            // if burn is false, it means we are clearing a settlement we did not pay off
            if (burnTokens) {
                _payOutstandingSettlementToUser(recipient, amountToSettle);
            }

            emit SettlementRequestCleared(marketId, recipient, amountToSettle, 0, block.timestamp, burnTokens);
        }
    }

    /**
     * @dev Pays an outstanding settlement to a user and burn their underlying tokens
     * @param user The user to settle an outstanding amount to
     * @param amount The amount to settle
     */
    function _payOutstandingSettlementToUser(address user, uint256 amount) internal virtual;
}
