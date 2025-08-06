// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title SwapTracking
 * @notice Library for managing transient storage to track swap state during transaction lifecycle
 * @dev Uses transient storage to minimize gas costs for inter-contract state management
 */
library ProxySwapFlag {
    // Transient storage slot for proxy swap flag
    //  bytes32(uint256(keccak256("ProxySwapFlag.proxySwapFlag")) - 1)
    bytes32 private constant PROXY_SWAP_FLAG_SLOT = 0xb2cdeda168ef16aaceb40605a2d55b1591e47cb286357600199476109313a907;

    /**
     * @notice Set the proxy swap flag to indicate a swap initiated by the proxy hook is in progress
     */
    function setProxySwapFlag() internal {
        assembly {
            tstore(PROXY_SWAP_FLAG_SLOT, true)
        }
    }

    /**
     * @notice Clears the state of the proxy swap flag
     */
    function clearProxySwapFlag() internal {
        assembly {
            tstore(PROXY_SWAP_FLAG_SLOT, false)
        }
    }

    /**
     * @notice Checks if a proxy swap is in progress
     * @return flag True if a proxy swap is in progress, false otherwise
     */
    function isProxySwapInProgress() internal view returns (bool flag) {
        assembly {
            flag := tload(PROXY_SWAP_FLAG_SLOT)
        }
    }

    /**
     * @notice Checks if a swap is direct (not initiated by the proxy hook)
     * @return True if the swap is direct, false otherwise
     */
    function isDirectSwap() internal view returns (bool) {
        return !isProxySwapInProgress();
    }
}
