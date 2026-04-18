// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IERC20Minimal} from "@uniswap/v4-core/src/interfaces/external/IERC20Minimal.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {IMMQueueCustodian} from "../../../src/interfaces/IMMQueueCustodian.sol";
import {IFuzzTakeOrchestrator} from "./IFuzzTakeOrchestrator.sol";

/// @notice Thin harness for `PositionManagerImpl._routeLccCustodyTakeAndForward`.
/// @dev This mirrors the custody guard and MM forward path without any linked-library deployment assumptions.
contract PositionManagerImplQueueCustodyHarness {
    IFuzzTakeOrchestrator public immutable vtsOrchestrator;
    IMMQueueCustodian public immutable queueCustodian;

    /// @notice Last amount forwarded to `queueCustodian` in the most recent route call.
    uint256 public lastCustodyForwarded;

    constructor(IFuzzTakeOrchestrator vtsOrchestrator_, IMMQueueCustodian queueCustodian_) {
        vtsOrchestrator = vtsOrchestrator_;
        queueCustodian = queueCustodian_;
    }

    /// @notice Mirror the queue-custody routing branch used by MM queue settlement.
    function routeLccCustodyTakeAndForward(
        Currency currency,
        address locker,
        uint256 tokenId,
        uint256 nonFee,
        uint256 qCommitted,
        uint256 addedCredit,
        uint256 fee
    ) external {
        lastCustodyForwarded = 0;

        uint256 custodyForward;
        if (tokenId > 0) {
            custodyForward = qCommitted;
            if (custodyForward > 0 && nonFee < custodyForward) {
                revert Errors.InsufficientBalance(nonFee, custodyForward);
            }
        } else {
            custodyForward = nonFee;
        }

        uint256 creditTake = addedCredit > fee ? addedCredit - fee : 0;
        if (creditTake > 0) {
            vtsOrchestrator.take(currency, locker, creditTake);
        }

        if (tokenId > 0) {
            if (custodyForward > 0) {
                _forwardQueuedLccToCustodian(currency, tokenId, locker, custodyForward);
            }
        } else if (nonFee > 0) {
            _forwardQueuedLccToCustodian(currency, tokenId, locker, nonFee);
        }
    }

    function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
        internal
    {
        lastCustodyForwarded = amount;

        address custodianAddr = address(queueCustodian);
        if (custodianAddr != address(0) && custodianAddr != address(this)) {
            IERC20Minimal(Currency.unwrap(currency)).transfer(custodianAddr, amount);
            if (tokenId > 0) {
                queueCustodian.record(tokenId, Currency.unwrap(currency), beneficiary, amount);
            }
        }
    }
}
