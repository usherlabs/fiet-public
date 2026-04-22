// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
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
    address public immutable utilityActionsImpl;

    constructor(
        address _marketFactory,
        address _vtsOrchestrator,
        address _canonicalCustody,
        address _actionsImpl,
        address _utilityActionsImpl
    ) PositionManagerBase(_marketFactory, _vtsOrchestrator, _canonicalCustody) {
        if (_actionsImpl == address(0) || _actionsImpl.code.length == 0) {
            revert Errors.InvalidAddress(_actionsImpl);
        }
        if (_utilityActionsImpl == address(0) || _utilityActionsImpl.code.length == 0) {
            revert Errors.InvalidAddress(_utilityActionsImpl);
        }
        actionsImpl = _actionsImpl;
        utilityActionsImpl = _utilityActionsImpl;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // Delegation Helpers
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Delegates a call to the position-actions implementation contract
    function _delegateToImpl(bytes memory data) internal {
        // OZ Address helper verifies target is a contract and bubbles revert reasons.
        Address.functionDelegateCall(actionsImpl, data);
    }

    /// @dev Delegates a call to the utility-actions implementation contract
    function _delegateToUtilityImpl(bytes memory data) internal {
        Address.functionDelegateCall(utilityActionsImpl, data);
    }

    // ------------------------------------------------------------------------------------------------
    // Batch Hooks
    // ------------------------------------------------------------------------------------------------

    /// @notice Hook called before batch execution
    /// @dev Credits native ETH to the locker delta using **balance-delta** accounting for the batch:
    ///      - First batch in the tx: baseline `lastSeen = balance - msg.value` so only this call's `msg.value` is
    ///        treated as new inflow (ambient ETH already on the router is not credited).
    ///      - Later batches: `fresh = balance - lastSeen`; credit `min(msg.value, fresh)` so:
    ///        - `Multicall_v4` inner `delegatecall`s share one outer `msg.value` and do not increase balance between
    ///          batches → second inner batch gets `fresh == 0` (fixes duplicate credit if we cleared a boolean per batch).
    ///        - Distinct payable top-level calls each add ETH → `fresh` matches the new wei and each call is credited once.
    ///      `_afterBatch` snapshots `address(this).balance` into transient storage for the rest of the transaction.
    function _beforeBatch() internal {
        uint256 amount = TransientSlots.nativeEthCreditAmountForBatch(address(this).balance, msg.value);
        if (amount > 0) {
            _creditExact(CurrencyLibrary.ADDRESS_ZERO, amount);
        }
    }

    /// @notice Hook called after batch execution
    /// @dev Clears batch-scoped seizure context, asserts deltas net to zero, then records native balance for the next
    ///      `_beforeBatch` in the same transaction (multicall-safe, multi-entrypoint-safe).
    function _afterBatch() internal {
        TransientSlots.clearSeizedPositionId();
        TransientSlots.clearSeizurePrimarySettleAllowed();
        // Owner-scoped and market-scoped transient namespaces both resolve through the orchestrator boundary.
        vtsOrchestrator.assertNonZeroDeltas(marketFactory);
        TransientSlots.setNativeLastSeenBalance(address(this).balance);
    }
}

