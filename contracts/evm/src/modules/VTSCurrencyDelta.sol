// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyDelta} from "v4-periphery/lib/v4-core/src/libraries/CurrencyDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VTSStorage} from "../types/VTS.sol";
import {DynamicCurrencyDelta} from "../libraries/DynamicCurrencyDelta.sol";
import {IVTSCurrencyDelta} from "../interfaces/IVTSCurrencyDelta.sol";

/**
 * @title VTSCurrencyDelta
 * @notice Abstract contract providing currency delta management functionality for VTS contracts
 * @dev Inheriting contracts must implement _vtsStorage() to provide storage access.
 *      All currency delta operations delegate to DynamicCurrencyDelta library.
 */
abstract contract VTSCurrencyDelta is IVTSCurrencyDelta {
    using CurrencyDelta for Currency;

    // ═══════════════════════════════════════════════════════════════════════════
    // ABSTRACT STORAGE ACCESS
    // ═══════════════════════════════════════════════════════════════════════════

    /**
     * @dev Returns the VTSStorage reference. Must be implemented by inheriting contracts.
     */
    function _vtsStorage() internal view virtual returns (VTSStorage storage);

    // ═══════════════════════════════════════════════════════════════════════════
    // IVTSCurrencyDelta IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVTSCurrencyDelta
    function getFullCredit(Currency currency, address owner) public view returns (uint256) {
        return DynamicCurrencyDelta.getFullCredit(currency, owner);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getFullDebt(Currency currency, address owner) public view returns (uint256) {
        return DynamicCurrencyDelta.getFullDebt(currency, owner);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getFullCreditPair(Currency currency0, Currency currency1, address owner)
        public
        view
        returns (uint256, uint256)
    {
        return (
            DynamicCurrencyDelta.getFullCredit(currency0, owner), DynamicCurrencyDelta.getFullCredit(currency1, owner)
        );
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getFullDebtPair(Currency currency0, Currency currency1, address owner)
        public
        view
        returns (uint256, uint256)
    {
        return (DynamicCurrencyDelta.getFullDebt(currency0, owner), DynamicCurrencyDelta.getFullDebt(currency1, owner));
    }

    /// @inheritdoc IVTSCurrencyDelta
    function take(Currency currency, address target, uint256 maxAmount) public returns (uint256) {
        return DynamicCurrencyDelta.take(currency, target, maxAmount);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getUnderlyingDeltaPair(address user, Currency currency0, Currency currency1)
        external
        view
        returns (BalanceDelta)
    {
        return DynamicCurrencyDelta.getUnderlyingDeltaPair(user, currency0, currency1);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function assertNonZeroDeltas() external view {
        DynamicCurrencyDelta.assertNonZeroDeltas();
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BALANCE-TO-DELTA SYNC
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVTSCurrencyDelta
    function sync(Currency currency, address owner, address target) external {
        // Sync owner's balance as credit to target's delta
        // Use case: MMPM receives msg.value (owner=MMPM), credit goes to locker (target=msgSender)
        DynamicCurrencyDelta.syncBalanceAsCredit(currency, owner, target);
    }

    /// @notice Syncs balance accumulation as credit for multiple currencies
    /// @dev Only handles balance increases (accumulation), not decreases (consumption).
    ///      Convenience function to sync both currencies of a pool pair in one call.
    ///      Useful after operations that increase multiple currency balances.
    /// @param currency0 The first currency to sync
    /// @param currency1 The second currency to sync
    /// @param owner The address whose balance to check (balance holder)
    /// @param target The address whose delta to credit
    /// @return deltaChange0 The amount by which currency0 delta was adjusted
    /// @return deltaChange1 The amount by which currency1 delta was adjusted
    function syncPair(Currency currency0, Currency currency1, address owner, address target)
        external
        returns (int128 deltaChange0, int128 deltaChange1)
    {
        deltaChange0 = DynamicCurrencyDelta.syncBalanceAsCredit(currency0, owner, target);
        deltaChange1 = DynamicCurrencyDelta.syncBalanceAsCredit(currency1, owner, target);
    }
}

