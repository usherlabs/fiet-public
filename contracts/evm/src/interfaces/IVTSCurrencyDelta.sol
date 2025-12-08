// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/**
 * @title IVTSCurrencyDelta
 * @notice Interface for currency delta management in VTS contracts
 * @dev Provides functions for querying and managing currency deltas
 */
interface IVTSCurrencyDelta {
    /**
     * @notice Gets the full credit (positive delta) for a currency and an owner
     * @param currency The currency
     * @param owner The owner of the credit
     * @return The full credit for the currency
     */
    function getFullCredit(Currency currency, address owner) external view returns (uint256);

    /**
     * @notice Gets the full debt (negative delta) for a currency and an owner
     * @param currency The currency
     * @param owner The owner of the debt
     * @return The full debt for the currency
     */
    function getFullDebt(Currency currency, address owner) external view returns (uint256);

    /**
     * @notice Gets the full credit for a pair of currencies and an owner
     * @param currency0 The first currency
     * @param currency1 The second currency
     * @param owner The owner of the credit
     * @return The full credit for the pair of currencies
     */
    function getFullCreditPair(Currency currency0, Currency currency1, address owner)
        external
        view
        returns (uint256, uint256);

    /**
     * @notice Gets the full debt for a pair of currencies and an owner
     * @param currency0 The first currency
     * @param currency1 The second currency
     * @param owner The owner of the debt
     * @return The full debt for the pair of currencies
     */
    function getFullDebtPair(Currency currency0, Currency currency1, address owner)
        external
        view
        returns (uint256, uint256);

    /**
     * @notice Primes the underlying delta for a currency and an owner
     * @dev Moves persistent credits into transient deltas
     * @param sender The sender of the prime
     * @param lcc The LCC currency to prime the underlying delta for
     */
    function primeUnderlyingCredits(address sender, Currency lcc) external;

    /**
     * @notice Persists unavailable underlying credits to persistent storage for a new owner
     * @dev Only persists the difference between the target's delta and balance (unavailable portion).
     *      Clears the target's transient delta and persists unavailable credits to newOwner.
     * @param target The address whose delta/balance to read (e.g., MMPM)
     * @param newOwner The address to persist unavailable credits against (e.g., locker)
     * @param lccCurrency0 The currency of the first LCC
     * @param lccCurrency1 The currency of the second LCC
     */
    function persistUnavailableUnderlyingCredits(
        address target,
        address newOwner,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) external;

    /**
     * @notice Takes up to maxAmount from target's positive delta, capping to available credit
     * @param currency The currency to take
     * @param target The address whose delta to take from
     * @param maxAmount The maximum amount to take (use 0 for full available)
     * @return The amount taken
     */
    function take(Currency currency, address target, uint256 maxAmount) external returns (uint256);

    /**
     * @notice Gets the underlying delta pair for a user
     * @param user The user to get the underlying delta pair for
     * @param currency0 The first currency (address)
     * @param currency1 The second currency (address)
     * @return The underlying delta pair for the user
     */
    function getUnderlyingDeltaPair(address user, Currency currency0, Currency currency1)
        external
        view
        returns (BalanceDelta);

    /**
     * @notice Asserts that all deltas are zero (for end-of-transaction validation)
     */
    function assertNonZeroDeltas() external view;

    /**
     * @notice Syncs the delta for a given currency based on caller's balance
     * @dev Adjusts delta to reflect actual balance held by msg.sender.
     *      If balance exceeds current positive delta, increases delta to match balance,
     *      establishing credit for the locker to take.
     * @param currency The currency to sync
     */
    function sync(Currency currency) external;

    /**
     * @notice Syncs the delta for a given currency and owner based on their balance
     * @dev Adjusts delta to reflect actual balance held. Useful after wrap/unwrap
     *      operations where balance changes occur outside normal delta accounting.
     * @param currency The currency to sync
     * @param owner The address whose balance/delta to sync
     */
    function syncFor(Currency currency, address owner) external;

    /**
     * @notice Syncs multiple currencies' deltas for the caller based on their balances
     * @dev Convenience function to sync both currencies of a pool pair in one call.
     *      Syncs balances for msg.sender.
     * @param currency0 The first currency to sync
     * @param currency1 The second currency to sync
     */
    function syncPair(Currency currency0, Currency currency1) external;

    /**
     * @notice Syncs multiple currencies' deltas for an owner based on their balances
     * @dev Convenience function to sync both currencies of a pool pair in one call.
     * @param currency0 The first currency to sync
     * @param currency1 The second currency to sync
     * @param owner The address whose balance/delta to sync
     * @return deltaChange0 The amount by which currency0 delta was adjusted
     * @return deltaChange1 The amount by which currency1 delta was adjusted
     */
    function syncPairFor(Currency currency0, Currency currency1, address owner)
        external
        returns (int128 deltaChange0, int128 deltaChange1);
}

