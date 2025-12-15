// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {ILCC} from "../interfaces/ILCC.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";

/// @title LccSafeTransfer
/// @notice Library for safely transferring LCC tokens using Solady's SafeTransferLib
/// @dev This library wraps SafeTransferLib to provide safe transfer methods for ILCC tokens.
///      The underlying transfer/transferFrom methods in LCC include custom _onTransfer validation.
library LccSafeTransfer {
    using SafeTransferLib for address;

    /**
     * @notice Safely transfer LCC tokens from the caller to a recipient
     * @dev Uses SafeTransferLib to safely call the standard ERC20 transfer method,
     *      which in LCC includes custom _onTransfer validation
     * @param lcc The LCC token contract
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransfer(ILCC lcc, address to, uint256 amount) internal {
        address(lcc).safeTransfer(to, amount);
    }

    /**
     * @notice Safely transfer LCC tokens from one address to another
     * @dev Uses SafeTransferLib to safely call the standard ERC20 transferFrom method,
     *      which in LCC includes custom _onTransfer validation
     * @param lcc The LCC token contract
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransferFrom(ILCC lcc, address from, address to, uint256 amount) internal {
        address(lcc).safeTransferFrom(from, to, amount);
    }
}

