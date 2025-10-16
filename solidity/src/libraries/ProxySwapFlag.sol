// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TransientSlots} from "./TransientSlots.sol";
import {TransientSlot} from "openzeppelin-contracts/contracts/utils/TransientSlot.sol";

/**
 * @title SwapTracking
 * @notice Library for managing transient storage to track swap state during transaction lifecycle
 * @dev Uses transient storage to minimize gas costs for inter-contract state management
 */
library ProxySwapFlag {
    using TransientSlot for *;
    // Transient storage slot for proxy swap flag

    /**
     * @notice Set the proxy swap flag to indicate a swap initiated by the proxy hook is in progress
     */
    function setProxySwapFlag() internal {
        TransientSlot.asBoolean(TransientSlots.PROXY_SWAP_FLAG_SLOT).tstore(true);
    }

    /**
     * @notice Clears the state of the proxy swap flag
     */
    function clearProxySwapFlag() internal {
        TransientSlot.asBoolean(TransientSlots.PROXY_SWAP_FLAG_SLOT).tstore(false);
    }

    /**
     * @notice Checks if a proxy swap is in progress
     * @return flag True if a proxy swap is in progress, false otherwise
     */
    function isProxySwapInProgress() internal view returns (bool flag) {
        flag = TransientSlot.asBoolean(TransientSlots.PROXY_SWAP_FLAG_SLOT).tload();
    }

    /**
     * @notice Checks if a swap is direct (not initiated by the proxy hook)
     * @return True if the swap is direct, false otherwise
     */
    function isDirectSwap() internal view returns (bool) {
        return !isProxySwapInProgress();
    }
}
