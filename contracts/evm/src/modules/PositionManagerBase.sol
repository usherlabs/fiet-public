// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ImmutableVTSState} from "./ImmutableVTSState.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";

/**
 * @title PositionManagerBase
 * @notice Base contract providing shared functionality for position management
 * @dev Contains abstract functions and shared currency detection utilities
 * @dev Note: ImmutableState is provided by inheriting contracts (BaseActionsRouter for entrypoint, direct for impl)
 */
abstract contract PositionManagerBase is ImmutableVTSState {
    ILiquidityHub internal immutable liquidityHub;

    constructor(address _liquidityHub, address _vtsOrchestrator) ImmutableVTSState(_vtsOrchestrator) {
        liquidityHub = ILiquidityHub(_liquidityHub);
    }

    // ------------------------------------------------------------------------------------------------
    // ABSTRACT FUNCTIONS (must be implemented by inheriting contracts)
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns the locker address (original caller of the batch)
    /// @dev Must be implemented by inheriting contracts (e.g., via BaseActionsRouter._getLocker())
    function msgSender() public view virtual returns (address);

    // ------------------------------------------------------------------------------------------------
    // SHARED UTILITIES
    // ------------------------------------------------------------------------------------------------

    /// @notice Converts LCC currency to underlying currency
    /// @param lcc The LCC currency
    /// @return The underlying currency
    function _lccToUnderlyingCurrency(Currency lcc) internal view returns (Currency) {
        return Currency.wrap(ILCC(Currency.unwrap(lcc)).underlying());
    }

    /// @notice Checks if a currency is an LCC token
    /// @param currency The currency to check
    /// @return True if the currency is a valid LCC token
    function _isLCC(Currency currency) internal view returns (bool) {
        address token = Currency.unwrap(currency);
        if (token == address(0)) return false;
        return liquidityHub.isLCC(token);
    }

    /// @notice Syncs balance accumulation as credit for a single currency
    /// @dev Only handles balance increases (accumulation), not decreases (consumption).
    ///      Checks MMPM's balance (address(this)) and credits locker's delta (msgSender).
    ///      This ensures balance increases from wrap/unwrap operations create takeable credits on the locker.
    /// @param currency The currency to sync balance for
    function _syncBalanceAsCredit(Currency currency) internal {
        // owner = address(this) = MMPM (balance holder)
        // target = msgSender() = locker (delta recipient)
        vtsOrchestrator.sync(currency, address(this), msgSender());
    }
}
