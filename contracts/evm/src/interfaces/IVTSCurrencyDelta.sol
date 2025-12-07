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
    function primeUnderlyingDelta(address sender, Currency lcc) external;

    /**
     * @notice Takes a currency from an owner to a recipient
     * @param currency The currency to take
     * @param sender The sender of the take
     * @param to The recipient of the take
     * @param maxAmount The maximum amount to take
     */
    function take(Currency currency, address sender, address to, uint256 maxAmount) external;

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
}

