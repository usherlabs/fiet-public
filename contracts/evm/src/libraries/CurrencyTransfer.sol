// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {Currency, CurrencyLibrary} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @title CurrencyTransfer
/// @notice Library for handling transfers of both native ETH and ERC-20 tokens

library CurrencyTransfer {
    using SafeERC20 for IERC20;

    /**
     * @notice Transfer currency from one address to another
     * @dev If addressZero, then the transaction must include a transfer of ETH to address(this), allowing for forwarding to destination.
     *     This emulates transferFrom. Native transferFrom does NOT include an initial inherited transfer for forwarding.
     *
     * @param currency The currency to transfer (can be native ETH or ERC-20)
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     */
    function transferFrom(Currency currency, address from, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // For native ETH, verify msg.value and forward it
            if (msg.value < amount) revert CurrencyLibrary.NativeTransferFailed();
            // Transfer ETH to the destination
            currency.transfer(to, amount);
        } else {
            // For ERC-20 tokens, use standard transferFrom
            IERC20(Currency.unwrap(currency)).safeTransferFrom(from, to, amount);
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

        IERC20(Currency.unwrap(currency)).forceApprove(user, amount);
    }
}
