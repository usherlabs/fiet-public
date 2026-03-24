// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMarketFactory} from "./IMarketFactory.sol";

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
     * @notice Syncs owner's balance as credit to target's delta
     * @dev Only handles balance increases (accumulation), not decreases (consumption).
     *      Checks owner's balance and credits target's delta.
     *      Use case: MMPM receives msg.value (owner=MMPM), credit goes to locker (target=msgSender).
     *      Restricted to protocol-bound callers in the provided factory namespace (same as `creditExact`).
     * @param factory The market factory namespace used to validate the caller is protocol-bound
     * @param currency The currency to sync
     * @param owner The address whose balance to check (balance holder)
     * @param target The address whose delta to credit
     */
    function sync(IMarketFactory factory, Currency currency, address owner, address target) external;

    /**
     * @notice Syncs owner's balance as credit to target's delta for multiple currencies
     * @dev Only handles balance increases (accumulation), not decreases (consumption).
     *      Convenience function to sync both currencies of a pool pair in one call.
     *      Restricted to protocol-bound callers in the provided factory namespace (same as `creditExact`).
     * @param factory The market factory namespace used to validate the caller is protocol-bound
     * @param currency0 The first currency to sync
     * @param currency1 The second currency to sync
     * @param owner The address whose balance to check (balance holder)
     * @param target The address whose delta to credit
     * @return deltaChange0 The amount by which currency0 delta was adjusted
     * @return deltaChange1 The amount by which currency1 delta was adjusted
     */
    function syncPair(IMarketFactory factory, Currency currency0, Currency currency1, address owner, address target)
        external
        returns (int128 deltaChange0, int128 deltaChange1);

    /// @notice Credits an exact known amount to target's delta
    /// @dev Restricted to protocol-bound callers in the provided factory namespace.
    function creditExact(IMarketFactory factory, Currency currency, address target, uint256 amount)
        external
        returns (int128 deltaChange);
}

