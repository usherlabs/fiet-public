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

    constructor(address _liquidityHub, address _vtsOrchestrator, address _actionsImpl)
        PositionManagerBase(_liquidityHub, _vtsOrchestrator)
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
    /// @dev Handles native value sent with the transaction and syncs as credit
    function _beforeBatch() internal {
        // Handle native value
        uint256 amount = TransientSlots.readMsgValueOnce();
        if (amount > 0) {
            _syncBalanceAsCredit(CurrencyLibrary.ADDRESS_ZERO);
        }
    }

    /// @notice Hook called after batch execution
    /// @dev Asserts that deltas are non-zero after batch execution
    function _afterBatch() internal {
        // Clear any per-batch transient context to avoid same-tx leakage into subsequent batches.
        TransientSlots.clearSeizedPositionId();
        // Assert that deltas are non-zero after batch execution
        vtsOrchestrator.assertNonZeroDeltas();
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
    function _take(Currency currency, address to, uint256 maxAmount) internal {
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

