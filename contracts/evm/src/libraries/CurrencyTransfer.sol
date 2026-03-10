// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solady/utils/SafeTransferLib.sol";
import {Errors} from "./Errors.sol";

/// @title CurrencyTransfer
/// @notice Library for handling transfers of both native ETH and ERC-20 tokens
/// @dev Uses Solady's SafeTransferLib with Permit2 fallback for ERC-20 transfers

library CurrencyTransfer {
    using SafeTransferLib for address;

    /**
     * @notice Transfer currency from one address to another
     * @dev Native transferFrom is only supported when `from == address(this)` (self-funded forwarding).
     *     For native ETH and non-self `from`, this function reverts because ETH has no pull-based transferFrom semantics.
     *     For ERC-20 tokens, uses Solady's safeTransferFrom2 which falls back to Permit2 if standard transferFrom fails.
     *     Optimised to use transfer instead of transferFrom when `from == address(this)` to avoid self-approval requirement.
     *
     * @param currency The currency to transfer (can be native ETH or ERC-20)
     * @param from The address to transfer from
     * @param to The address to transfer to
     * @param amount The amount to transfer
     */
    function transferFrom(Currency currency, address from, address to, uint256 amount) internal {
        if (currency.isAddressZero()) {
            // Native ETH cannot be pulled from arbitrary wallets.
            if (from != address(this)) {
                revert Errors.NativeTransferFromUnsupported(from);
            }
            currency.transfer(to, amount);
        } else if (from == address(this)) {
            // When transferring ERC-20 from self, use direct transfer to avoid self-approval requirement.
            currency.transfer(to, amount);
        } else {
            // For ERC-20 tokens, use Solady's safeTransferFrom2 with Permit2 fallback
            // This tries standard transferFrom first, falls back to Permit2 if it fails
            Currency.unwrap(currency).safeTransferFrom2(from, to, amount);
        }
    }

    /**
     * @notice Approves an address for a potential ERC20 transfer
     * @dev Uses Solady's safeApproveWithRetry which handles USDT-like tokens that require
     *      resetting allowance to zero before setting a new non-zero value
     * @param currency the Currency
     * @param user the address to approve
     * @param amount the amount to approve
     */
    function approve(Currency currency, address user, uint256 amount) internal {
        // do nothing if the currency is native ETH
        // @dev potentially we could do the sync step here if we were to ever want to implement a 'sync' and 'settle' mechanism for LCC's
        if (currency.isAddressZero()) return;

        Currency.unwrap(currency).safeApproveWithRetry(user, amount);
    }
}
