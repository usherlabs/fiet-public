// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencyDelta} from "@uniswap/v4-core/src/libraries/CurrencyDelta.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {VTSStorage} from "../types/VTS.sol";
import {OwnerCurrencyDelta} from "../libraries/OwnerCurrencyDelta.sol";
import {MarketCurrencyDelta} from "../libraries/MarketCurrencyDelta.sol";
import {IVTSCurrencyDelta} from "../interfaces/IVTSCurrencyDelta.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";

/**
 * @title VTSCurrencyDelta
 * @notice Abstract contract providing currency delta management functionality for VTS contracts
 * @dev Inheriting contracts must implement _vtsStorage() to provide storage access.
 *      Owner-scoped currency delta operations delegate to OwnerCurrencyDelta.
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
    function _assertBoundFactoryCaller(IMarketFactory factory) internal view virtual;

    // ═══════════════════════════════════════════════════════════════════════════
    // IVTSCurrencyDelta IMPLEMENTATION
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVTSCurrencyDelta
    function getFullCredit(Currency currency, address owner) public view returns (uint256) {
        return OwnerCurrencyDelta.getFullCredit(currency, owner);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getFullDebt(Currency currency, address owner) public view returns (uint256) {
        return OwnerCurrencyDelta.getFullDebt(currency, owner);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getFullCreditPair(Currency currency0, Currency currency1, address owner)
        public
        view
        returns (uint256, uint256)
    {
        return (OwnerCurrencyDelta.getFullCredit(currency0, owner), OwnerCurrencyDelta.getFullCredit(currency1, owner));
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getFullDebtPair(Currency currency0, Currency currency1, address owner)
        public
        view
        returns (uint256, uint256)
    {
        return (OwnerCurrencyDelta.getFullDebt(currency0, owner), OwnerCurrencyDelta.getFullDebt(currency1, owner));
    }

    /// @inheritdoc IVTSCurrencyDelta
    function take(Currency currency, address target, uint256 maxAmount) public returns (uint256) {
        return OwnerCurrencyDelta.take(currency, target, maxAmount);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function getUnderlyingDeltaPair(address user, Currency currency0, Currency currency1)
        external
        view
        returns (BalanceDelta)
    {
        return OwnerCurrencyDelta.getUnderlyingDeltaPair(user, currency0, currency1);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function assertNonZeroDeltas() external view {
        OwnerCurrencyDelta.assertNonZeroDeltas();
        MarketCurrencyDelta.assertResolved(address(factory));
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // BALANCE-TO-DELTA SYNC
    // ═══════════════════════════════════════════════════════════════════════════

    /// @inheritdoc IVTSCurrencyDelta
    function sync(IMarketFactory factory, Currency currency, address owner, address target) external {
        _assertBoundFactoryCaller(factory);
        // Sync owner's balance as credit to target's delta
        // Use case: MMPM receives msg.value (owner=MMPM), credit goes to locker (target=msgSender)
        OwnerCurrencyDelta.syncBalanceAsCredit(currency, owner, target);
    }

    /// @notice Syncs balance accumulation as credit for multiple currencies
    /// @dev Only handles balance increases (accumulation), not decreases (consumption).
    ///      Convenience function to sync both currencies of a pool pair in one call.
    ///      Useful after operations that increase multiple currency balances.
    /// @param factory The market factory namespace used to validate the caller is protocol-bound
    /// @param currency0 The first currency to sync
    /// @param currency1 The second currency to sync
    /// @param owner The address whose balance to check (balance holder)
    /// @param target The address whose delta to credit
    /// @return deltaChange0 The amount by which currency0 delta was adjusted
    /// @return deltaChange1 The amount by which currency1 delta was adjusted
    function syncPair(IMarketFactory factory, Currency currency0, Currency currency1, address owner, address target)
        external
        returns (int128 deltaChange0, int128 deltaChange1)
    {
        _assertBoundFactoryCaller(factory);
        deltaChange0 = OwnerCurrencyDelta.syncBalanceAsCredit(currency0, owner, target);
        deltaChange1 = OwnerCurrencyDelta.syncBalanceAsCredit(currency1, owner, target);
    }

    function _creditExact(Currency currency, address target, uint256 amount) internal returns (int128 deltaChange) {
        deltaChange = OwnerCurrencyDelta.creditExact(currency, target, amount);
    }

    /// @notice Credits an exact known amount to target's delta
    /// @dev Restricted to protocol-bound callers in the provided factory namespace.
    function creditExact(IMarketFactory factory, Currency currency, address target, uint256 amount)
        external
        returns (int128 deltaChange)
    {
        _assertBoundFactoryCaller(factory);
        deltaChange = _creditExact(currency, target, amount);
    }
}

