// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
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
    function primeUnderlyingDelta(address sender, Currency lcc) external {
        VTSStorage storage s = _vtsStorage();
        DynamicCurrencyDelta.primeUnderlyingDelta(s, sender, lcc, address(this));
    }

    function persistUnderlyingCredits(
        address sender,
        BalanceDelta settlementDelta,
        Currency lccCurrency0,
        Currency lccCurrency1
    ) external {
        VTSStorage storage s = _vtsStorage();
        DynamicCurrencyDelta.persistUnderlyingCredits(s, sender, settlementDelta, lccCurrency0, lccCurrency1);
    }

    /// @inheritdoc IVTSCurrencyDelta
    function take(Currency currency, address sender, address to, uint256 maxAmount) public returns (uint256) {
        return DynamicCurrencyDelta.take(currency, sender, to, maxAmount);
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
}

