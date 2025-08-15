// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

abstract contract MarketLiquidityDebt {
    struct Request {
        address recipient; // the address that will receive the underlying assets
        uint256 amount; // the amount of tokens to unwrap
        uint256 unfilledAmount; // How much has not been settled
        uint256 timestamp; // the timestamp of the request
        bool isProcessed; // whether the request has been processed
    }

    // When a debt request is added to the queue
    event DebtRequestQueued(
        bytes32 indexed marketId, address indexed recipient, uint256 amount, uint256 queueIndex, uint256 timestamp
    );

    // When a debt request is settled/cleared
    event DebtRequestSettled(
        bytes32 indexed marketId,
        address indexed recipient,
        uint256 amount,
        uint256 queueIndex,
        uint256 timestamp,
        bool tokensBurned
    );

    // When a debt request is annulled
    event DebtRequestAnnulled(bytes32 indexed marketId, address indexed recipient, uint256 amount, uint256 timestamp);

    // Events for market tracking
    event MarketRegistered(bytes32 indexed marketId);
    event MarketLiquidityAdded(bytes32 indexed marketId, uint256 amount);
    event MarketLiquidityUsed(bytes32 indexed marketId, uint256 amount);

    // Market tracking state variables
    bytes32[] public knownMarkets; // List of known markets
    mapping(bytes32 => bool) public isMarketKnown; // Quick lookup for market existence
    mapping(bytes32 => uint256) public marketLiquidityReserves; // Market-specific underlying liquidity
    uint256 public constant MAX_MARKETS_PER_USER = 50; // Reasonable limit for gas optimization

    // Market-specific debt queues
    mapping(bytes32 => mapping(address => uint256)) public marketUserDebt; // marketId => recipient => debt we owe them
    mapping(bytes32 => uint256) public marketTotalDebt; // Total debt we owe per market
    mapping(bytes32 => address[]) public marketDebtHolders; // List of people we owe debt to per market
    mapping(bytes32 => mapping(address => bool)) public hasDebt; // Quick lookup

    // Market specific balances for each user
    mapping(address => mapping(bytes32 => uint256)) public userMarketBalances; // User balance per market

    /*
     * @dev Gets the total debt for a specific market
     * @param marketId The market ID
     * @return The total debt for this market
     */
    function getMarketTotalDebt(bytes32 marketId) external view returns (uint256) {
        return marketTotalDebt[marketId];
    }

    /**
     * @dev Gets market liquidity reserves
     * @param marketId The market ID
     * @return The amount of liquidity reserves for this market
     */
    function getMarketLiquidityReserves(bytes32 marketId) external view returns (uint256) {
        return marketLiquidityReserves[marketId];
    }

    /*
     * @dev Gets a user's balance from a specific market
     * @param user The user address
     * @param marketId The market ID
     * @return The user's balance from this market
     */
    function getUserMarketBalance(address user, bytes32 marketId) external view returns (uint256) {
        return userMarketBalances[user][marketId];
    }

    /**
     * @dev Gets all known markets
     * @return Array of all registered market IDs
     */
    function getKnownMarkets() external view returns (bytes32[] memory) {
        return knownMarkets;
    }

    /*
     * @dev Gets the number of debt holders for a specific market
     * @param marketId The market ID
     * @return The number of debt holders in this market
     */
    function getMarketQueueLength(bytes32 marketId) external view returns (uint256) {
        return marketDebtHolders[marketId].length;
    }

    /*
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

    /*
     * @dev Adds debt owed to a recipient in a specific market (cumulative)
     * @param marketId The market ID for this debt
     * @param recipient The address we owe debt to
     * @param amount The amount of debt to add
     */
    function _addMarketDebtRequest(bytes32 marketId, address recipient, uint256 amount) internal {
        // Add to debt we owe this recipient for this market
        if (marketUserDebt[marketId][recipient] == 0) {
            // First debt to this recipient in this market
            marketDebtHolders[marketId].push(recipient);
            hasDebt[marketId][recipient] = true;
        }

        marketUserDebt[marketId][recipient] += amount;
        marketTotalDebt[marketId] += amount;

        emit DebtRequestQueued(
            marketId,
            recipient,
            amount,
            0, // No queue index anymore
            block.timestamp
        );
    }

    /*
     * @dev Removes a debt holder from the list (debt fully paid)
     */
    function _removeDebtHolder(bytes32 marketId, address debtHolder) internal {
        address[] storage debtHolders = marketDebtHolders[marketId];
        for (uint256 i = 0; i < debtHolders.length; i++) {
            if (debtHolders[i] == debtHolder) {
                debtHolders[i] = debtHolders[debtHolders.length - 1];
                debtHolders.pop();
                break;
            }
        }
    }

    /*
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

    /*
     * @dev Gets debt holders sorted by debt amount (smallest first)
     */
    function _getSortedDebtHolders(bytes32 marketId) internal view returns (address[] memory) {
        address[] memory debtHolders = marketDebtHolders[marketId];

        // Simple bubble sort
        for (uint256 i = 0; i < debtHolders.length; i++) {
            for (uint256 j = i + 1; j < debtHolders.length; j++) {
                if (marketUserDebt[marketId][debtHolders[i]] > marketUserDebt[marketId][debtHolders[j]]) {
                    // Swap
                    address temp = debtHolders[i];
                    debtHolders[i] = debtHolders[j];
                    debtHolders[j] = temp;
                }
            }
        }

        return debtHolders;
    }

    /**
     * @dev Gets the total debt owed to a specific recipient across all markets
     * @param recipient The address to check
     * @return totalDebt The total debt owed across all markets
     */
    function _getUserTotalDebt(address recipient) internal view returns (uint256 totalDebt) {
        totalDebt = 0;

        for (uint256 i = 0; i < knownMarkets.length; i++) {
            bytes32 marketId = knownMarkets[i];
            totalDebt += marketUserDebt[marketId][recipient];
        }
    }

    /*
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
     * @dev Partially or Completely Process the market debt queue
     * @param marketId The market to process the debt queue for
     * @param availableLiquidity The available liquidity in the market
     * @param burnTokens Whether to burn the equivalent LCC tokens for the debt settled
     * @return processedAmount The amount processed from the debt queue
     */
    function _processMarketDebtQueue(bytes32 marketId, uint256 availableLiquidity, bool burnTokens)
        internal
        returns (uint256 processedAmount)
    {
        uint256 remainingLiquidity = Math.min(availableLiquidity, marketTotalDebt[marketId]);

        // Sort debt holders by debt amount (smallest first)
        address[] memory sortedDebtHolders = _getSortedDebtHolders(marketId);

        for (uint256 i = 0; i < sortedDebtHolders.length && remainingLiquidity > 0; i++) {
            address debtHolder = sortedDebtHolders[i];
            uint256 debtAmount = marketUserDebt[marketId][debtHolder];

            if (debtAmount == 0) continue; // Skip paid debts - very cheap

            uint256 amountToSettleFromDebt = Math.min(remainingLiquidity, debtAmount);

            // Update debt we owe
            marketUserDebt[marketId][debtHolder] -= amountToSettleFromDebt;
            marketTotalDebt[marketId] -= amountToSettleFromDebt;

            // Update the remaining liquidity and processed amount for this iteration
            remainingLiquidity -= amountToSettleFromDebt;
            processedAmount += amountToSettleFromDebt;

            // If debt fully paid, remove from debt holders list
            if (marketUserDebt[marketId][debtHolder] == 0) {
                hasDebt[marketId][debtHolder] = false;
                _removeDebtHolder(marketId, debtHolder);
            }

            // burn the equivalent LCC Tokens for this user's debt that was just paid off
            // and transfer the underlying assets to the debt holder
            // if burn is false, it means we are clearinig a debt we did not pay off
            if (burnTokens) {
                _payMarketDebt(debtHolder, amountToSettleFromDebt);
            }

            emit DebtRequestSettled(marketId, debtHolder, amountToSettleFromDebt, 0, block.timestamp, burnTokens);
        }
    }

    /**
     * @dev Pays a debt to a user and burn their underlying tokens
     * @param user The user to pay the debt to
     * @param amount The amount of debt to pay
     */
    function _payMarketDebt(address user, uint256 amount) internal virtual;
}
