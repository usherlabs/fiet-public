// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {TransientSlots} from "./TransientSlots.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";

/**
 * @title CoreActionFlag
 * @notice Transient guard used to distinguish direct core actions from proxy-routed actions.
 */
library CoreActionFlag {
    using TransientSlot for *;

    /// @notice Marks the current execution context as proxy-routed, so direct core-action handlers must not run.
    function setNoCoreAction() internal {
        TransientSlot.asBoolean(TransientSlots.CORE_ACTION_FLAG_SLOT).tstore(true);
    }

    /// @notice Clears the proxy-routed execution marker.
    function clearNoCoreAction() internal {
        TransientSlot.asBoolean(TransientSlots.CORE_ACTION_FLAG_SLOT).tstore(false);
    }

    /// @notice Returns true when current context is proxy-routed and direct core actions should be skipped.
    function isNoCoreAction() internal view returns (bool flag) {
        flag = TransientSlot.asBoolean(TransientSlots.CORE_ACTION_FLAG_SLOT).tload();
    }

    /// @notice Returns true when source context is proxy-routed and direct core actions should be skipped.
    function isNoCoreAction(address sourceAddress) internal view returns (bool) {
        // Unsupported addresses (zero, EOAs, or non-implementing contracts) should not hard-revert this guard.
        if (sourceAddress.code.length == 0) {
            return false;
        }

        bytes4 exttloadSelector = bytes4(keccak256("exttload(bytes32)"));
        (bool success, bytes memory data) =
            sourceAddress.staticcall(abi.encodeWithSelector(exttloadSelector, TransientSlots.CORE_ACTION_FLAG_SLOT));
        if (!success || data.length < 32) {
            return false;
        }

        return abi.decode(data, (bytes32)) != bytes32(0);
    }

    /// @notice Returns true when current context is a direct core action.
    function isDirectCoreAction() internal view returns (bool) {
        return !isNoCoreAction();
    }

    /// @notice Returns true when source context is a direct core action.
    function isDirectCoreAction(address sourceAddress) internal view returns (bool) {
        return !isNoCoreAction(sourceAddress);
    }
}

