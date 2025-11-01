// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";

/// @title CurrencyTransfer
/// @notice Library for handling transfers of both native ETH and ERC-20 tokens

library CurrencyTransfer {
    error InsufficientETH();
    error ETHTransferFailed();
    error NotNativeETH();

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

    /**
     * @notice Approves an address for a potential ERC20 transfer
     * @param currency the Currency
     * @param user the address to approve
     * @param amount the amount to approve
     */
    function approve(Currency currency, address user, uint256 amount) internal {
        // do nothing if the currency is native ETH
        // @dev potentially we could do the sync step here if we were to ever want to implement a 'sync' and 'settle' mechanism for LCC's
        if (currency.isAddressZero()) return;

        IERC20Minimal(Currency.unwrap(currency)).approve(user, amount);
    }

    /**
     * @notice Refund ETH to the caller
     * @param currency the Currency
     * @param amountSpent the amount spent
     */
    function refundETH(Currency currency, uint256 amountSpent) internal {
        uint256 totalAmountSentToContract = msg.value;
        if (amountSpent == 0 || totalAmountSentToContract == 0) return;
        if (!currency.isAddressZero()) revert NotNativeETH();

        // transfer the left over amount to the caller
        currency.transfer(msg.sender, totalAmountSentToContract - amountSpent);
    }
}
