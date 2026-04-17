// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {LiquidityUtils} from "../../../src/libraries/LiquidityUtils.sol";
import {Errors} from "../../../src/libraries/Errors.sol";
import {IMMQueueCustodian} from "../../../src/interfaces/IMMQueueCustodian.sol";

/// @notice Minimal orchestrator surface used by `PositionManagerImpl._routeLccCustodyTakeAndForward`.
interface IFuzzTakeOrchestrator {
    function take(Currency currency, address target, uint256 maxAmount) external returns (uint256);
}

/// @notice Thin test harness mirroring `PositionManagerImpl._routeLccCustodyTakeAndForward` and the MM forward path
///         (`MMPositionActionsImpl._forwardQueuedLccToCustodian`).
/// @dev Logic MUST stay aligned with `PositionManagerImpl._routeLccCustodyTakeAndForward` (custody guard + take + forward)
///      and `MMPositionActionsImpl._forwardQueuedLccToCustodian` (ERC20 transfer + conditional `record`).
///      Related audit note: `agents/audit-resolutions/mm-queue-custody-nonfee-vs-custodyforward-guard-resolution.md`.
contract PositionManagerImplQueueCustodyHarness {
    IFuzzTakeOrchestrator public immutable vtsOrchestrator;
    IMMQueueCustodian public immutable queueCustodian;

    /// @notice Last amount forwarded toward `queueCustodian` in the most recent `route` call (observable by properties).
    uint256 public lastCustodyForwarded;

    constructor(IFuzzTakeOrchestrator vtsOrchestrator_, IMMQueueCustodian queueCustodian_) {
        vtsOrchestrator = vtsOrchestrator_;
        queueCustodian = queueCustodian_;
    }

    /// @dev Copy of `PositionManagerImpl._routeLccCustodyTakeAndForward` routing + MM-style forward.
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

        uint256 creditTake = LiquidityUtils.mmLockerCreditTakeForQueuedCustody(addedCredit, fee);

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

    /// @dev Mirrors `MMPositionActionsImpl._forwardQueuedLccToCustodian` when custodian is external.
    function _forwardQueuedLccToCustodian(Currency currency, uint256 tokenId, address beneficiary, uint256 amount)
        internal
    {
        lastCustodyForwarded = amount;
        address custodianAddr = address(queueCustodian);
        if (custodianAddr != address(0) && custodianAddr != address(this)) {
            currency.transfer(custodianAddr, amount);
            if (tokenId > 0) {
                queueCustodian.record(tokenId, Currency.unwrap(currency), beneficiary, amount);
            }
        }
    }
}
