// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ImmutableVTSState} from "./ImmutableVTSState.sol";
import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @title PositionManagerBase
 * @notice Base contract providing shared functionality for position management
 * @dev Contains abstract functions and shared currency detection utilities
 * @dev Note: ImmutableState is provided by inheriting contracts (BaseActionsRouter for entrypoint, direct for impl)
 */
abstract contract PositionManagerBase is ImmutableVTSState {
    using CurrencyLibrary for Currency;

    ILiquidityHub internal immutable liquidityHub;
    IMarketFactory internal immutable marketFactory;
    /// @notice Factory-scoped canonical custody used at batch finality and for settlement transfers.
    address internal immutable canonicalCustody;

    constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody)
        ImmutableVTSState(_vtsOrchestrator)
    {
        if (_canonicalCustody == address(0)) revert Errors.InvalidAddress(_canonicalCustody);
        marketFactory = IMarketFactory(_marketFactory);
        liquidityHub = marketFactory.liquidityHub();
        canonicalCustody = _canonicalCustody;
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
        vtsOrchestrator.sync(marketFactory, currency, address(this), msgSender());
    }

    /// @notice Credits an exact known amount to the locker's delta
    /// @param currency The currency to credit
    /// @param amount The exact amount to credit
    function _creditExact(Currency currency, uint256 amount) internal {
        vtsOrchestrator.creditExact(marketFactory, currency, msgSender(), amount);
    }

    /// @notice Takes currency from delta and transfers to recipient (locker = `msgSender()`).
    /// @dev Native `TAKE` to `address(this)` is disallowed: it would debit the locker's delta without moving ETH,
    ///      stranding balance on MMPM with no native `SYNC` path (see `INVARIANTS.md` DELTA-02). ERC20 self-take
    ///      remains valid and recoverable via `SYNC`.
    function _take(Currency currency, address to, uint256 maxAmount) internal {
        if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
            revert Errors.InvalidAddress(to);
        }
        address locker = msgSender();
        uint256 bal = currency.balanceOfSelf();
        uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
        uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);

        if (to != address(this)) {
            currency.transfer(to, takeAmount);
        }
    }
}
