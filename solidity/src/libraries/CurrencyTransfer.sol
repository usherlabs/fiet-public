// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";

/// @title CurrencyTransfer
/// @notice Library for handling transfers of both native ETH and ERC-20 tokens

library CurrencyTransfer {
    error InsufficientETH();
    error ETHTransferFailed();

    /**
     * @notice Transfer currency from one address to another
     * @param currency The currency to transfer (can be native ETH or ERC-20)
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     */
    function transferFrom(Currency currency, address from, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // For native ETH, verify msg.value and forward it
            if (msg.value < amount) revert InsufficientETH();
            // Transfer ETH to the destination
            (bool success,) = to.call{value: amount}("");
            if (!success) revert ETHTransferFailed();
        } else {
            // For ERC-20 tokens, use standard transferFrom
            IERC20Minimal(Currency.unwrap(currency)).transferFrom(from, to, amount);
        }
    }
}

