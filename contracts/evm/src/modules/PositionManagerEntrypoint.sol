// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {TransientSlots} from "../libraries/TransientSlots.sol";
import {PositionManagerBase} from "./PositionManagerBase.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @title PositionManagerEntrypoint
 * @notice Base contract providing entrypoint-specific functionality
 * @dev Contains functions used only by MMPositionManager (entrypoint)
 */
abstract contract PositionManagerEntrypoint is PositionManagerBase {
    address public immutable actionsImpl;

    constructor(address _marketFactory, address _vtsOrchestrator, address _canonicalCustody, address _actionsImpl)
        PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody)
    {
        if (_actionsImpl == address(0) || _actionsImpl.code.length == 0) {
            revert Errors.InvalidAddress(_actionsImpl);
        }
        actionsImpl = _actionsImpl;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Delegation Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Delegates a call to the implementation contract
    function _delegateToImpl(bytes memory data) internal {
        // OZ Address helper verifies target is a contract and bubbles revert reasons.
        Address.functionDelegateCall(actionsImpl, data);
    }

    // ------------------------------------------------------------------------------------------------
    // Batch Hooks
    // ------------------------------------------------------------------------------------------------

    /// @notice Hook called before batch execution
    /// @dev Credits native ETH to the locker delta at most once per **transaction** (see `readMsgValueOnce`).
    ///      `MMPositionManager` inherits `Multicall_v4`, which `delegatecall`s into this contract: every inner call
    ///      shares the outer `msg.value`. If we cleared the read guard at batch end, each inner payable batch would
    ///      re-credit the same `msg.value` and `TAKE(native, …)` could drain ambient ETH on the router.
    function _beforeBatch() internal {
        uint256 amount = TransientSlots.readMsgValueOnce();
        if (amount > 0) {
            _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
        }
    }

    /// @notice Hook called after batch execution
    /// @dev Clears batch-scoped seizure context, then asserts PoolManager / owner / produced-credit deltas net to zero.
    ///      Intentionally does **not** call `TransientSlots.clearMsgValueRead()` so the native-value guard stays
    ///      transaction-scoped (see `_beforeBatch` and multicall / delegatecall semantics).
    function _afterBatch() internal {
        TransientSlots.clearSeizedPositionId();
        // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
        vtsOrchestrator.assertNonZeroDeltas(marketFactory);
    }

    // ------------------------------------------------------------------------------------------------
    // MM Utility Helpers
    // ------------------------------------------------------------------------------------------------

    /// @notice Takes currency from delta and transfers to recipient
    /// @dev Unified flow for both LCC and underlying currencies:
    ///      - Balance held as ERC20 by MMPM
    ///      - Delta on locker (LCC fees synced via _syncBalanceAsCredit after position modification)
    ///      - Flow: debit locker delta -> direct ERC20 transfer
    /// @param currency The currency to take
    /// @param to The recipient address
    /// @param maxAmount The maximum amount to take (0 = take full available credit)
    /// @dev Native `TAKE` to `address(this)` is disallowed: it would debit the locker's delta without moving ETH,
    ///      stranding balance on MMPM with no native `SYNC` path (see `INVARIANTS.md` DELTA-02 / audit finding on
    ///      native self-take). ERC20 self-take remains valid and recoverable via `SYNC`.
    function _take(Currency currency, address to, uint256 maxAmount) internal {
        if (currency == CurrencyLibrary.ADDRESS_ZERO && to == address(this)) {
            revert Errors.InvalidAddress(to);
        }
        address locker = msgSender();
        uint256 bal = currency.balanceOfSelf();
        // maxAmount == 0 means "take full available credit", but still cap to the actual ERC20 balance held by MMPM.
        uint256 trueMaxAmount = (maxAmount == 0) ? bal : Math.min(maxAmount, bal);
        uint256 takeAmount = vtsOrchestrator.take(currency, locker, trueMaxAmount);

        if (to != address(this)) {
            currency.transfer(to, takeAmount);
        }
    }
}

