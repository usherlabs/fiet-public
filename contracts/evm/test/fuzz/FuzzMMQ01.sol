// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";
import {FuzzHelper} from "./FuzzHelper.sol";
import {PositionManagerImplQueueCustodyHarness} from "./harnesses/PositionManagerImplQueueCustodyHarness.sol";
import {FuzzMMQueueCustodian, FuzzTakeOrchestratorMock} from "./mocks/FuzzQueueCustodyMocks.sol";

/// @notice Medusa module for the MM queue custody guard from MMQ-01.
/// @dev This module deploys its harness and mocks with ordinary `new` calls so the
///      supported Medusa path no longer depends on linked-library CREATE2 preparation.
///      Valid-route accounting follows the current `develop` semantics in `LiquidityUtils`.
abstract contract FuzzMMQ01 is FuzzHelper {
    uint256 internal constant DOMAIN_CAP = 1e24;

    struct ValidInputs {
        uint256 tokenId;
        uint256 qCommitted;
        uint256 nonFee;
        uint256 addedCredit;
        uint256 feeClassified;
    }

    PositionManagerImplQueueCustodyHarness internal harness;
    FuzzTakeOrchestratorMock internal orchestrator;
    FuzzMMQueueCustodian internal custodian;
    MockLCC internal lcc;
    Currency internal lccCurrency;

    address internal constant LOCKER = address(0xA11CE);

    uint256 internal validAttempts;
    bool internal validAllOk = true;

    uint256 internal invalidAttempts;
    bool internal invalidAllOk = true;

    uint256 internal matchAttempts;
    bool internal matchAllOk = true;

    constructor() {
        address underlying = address(0x2000000000000000000000000000000000000001);
        lcc = new MockLCC("MMQFuzzLCC", "MMQF", 18, underlying);
        lccCurrency = Currency.wrap(address(lcc));

        orchestrator = new FuzzTakeOrchestratorMock();
        custodian = new FuzzMMQueueCustodian(address(this));
        harness = new PositionManagerImplQueueCustodyHarness(orchestrator, custodian);
        custodian.setPositionManager(address(harness));

        lcc.mint(address(harness), type(uint128).max);
    }

    /// @notice Valid region: `nonFee >= qCommitted` when `tokenId > 0` and `qCommitted > 0`.
    function action_mmq01_valid_commit_custody_guard_holds(
        uint256 tokenIdRaw,
        uint256,
        uint256 principalRaw,
        uint256 shortfallRaw,
        uint256 extraNonFeeRaw,
        int128 feesAccruedRaw,
        int256 hookDeltaRaw,
        uint256 addedCreditRaw,
        uint256 feeClassifiedRaw
    ) external {
        unchecked {
            validAttempts++;
        }

        ValidInputs memory inputs = _buildValidInputs(
            tokenIdRaw,
            principalRaw,
            shortfallRaw,
            extraNonFeeRaw,
            feesAccruedRaw,
            hookDeltaRaw,
            addedCreditRaw,
            feeClassifiedRaw
        );

        if (inputs.qCommitted > 0 && inputs.nonFee < inputs.qCommitted) {
            return;
        }

        if (!_tryRouteValid(inputs)) {
            validAllOk = false;
            return;
        }

        if (inputs.qCommitted > 0) {
            if (harness.lastCustodyForwarded() != inputs.qCommitted) {
                validAllOk = false;
            }
        } else if (harness.lastCustodyForwarded() != 0) {
            validAllOk = false;
        }
    }

    /// @notice Invalid region: `nonFee < qCommitted` with `tokenId > 0` must revert `InsufficientBalance`.
    function action_mmq01_invalid_underfunded_non_fee_reverts(
        uint256 tokenIdRaw,
        uint256 qCommittedRaw,
        uint256 nonFeeRaw
    ) external {
        unchecked {
            invalidAttempts++;
        }

        uint256 tokenId = (tokenIdRaw % 1000) + 1;
        uint256 qCommitted = (qCommittedRaw % (DOMAIN_CAP - 1)) + 1;
        uint256 nonFee = nonFeeRaw % qCommitted;

        bool reverted;
        bytes memory reason;
        try harness.routeLccCustodyTakeAndForward(lccCurrency, LOCKER, tokenId, nonFee, qCommitted, 0, 0) {
            reverted = false;
        } catch (bytes memory lowLevelData) {
            reverted = true;
            reason = lowLevelData;
        }

        bool ok = reverted && bytes4(reason) == Errors.InsufficientBalance.selector;
        if (!ok) {
            invalidAllOk = false;
        }
    }

    /// @notice Custodian slice increases by `qCommitted` on successful commit-leg forwards.
    function action_mmq01_custody_record_matches_q_committed(
        uint256 tokenIdRaw,
        uint256 qCommittedRaw,
        uint256 extraNonFeeRaw
    ) external {
        unchecked {
            matchAttempts++;
        }

        uint256 tokenId = (tokenIdRaw % 1000) + 1;
        uint256 qCommitted = (qCommittedRaw % DOMAIN_CAP) + 1;
        uint256 extra = extraNonFeeRaw % DOMAIN_CAP;
        uint256 nonFee = qCommitted + extra;

        uint256 beforeQ = custodian.queued(tokenId, address(lcc), LOCKER);

        try harness.routeLccCustodyTakeAndForward(lccCurrency, LOCKER, tokenId, nonFee, qCommitted, 0, 0) {
            uint256 afterQ = custodian.queued(tokenId, address(lcc), LOCKER);
            if (afterQ != beforeQ + qCommitted) {
                matchAllOk = false;
            }
        } catch {
            matchAllOk = false;
        }
    }

    function _retainedPrincipal(uint256 principal, uint256 shortfallU) internal pure returns (uint256) {
        return shortfallU > principal ? principal : shortfallU;
    }

    function _buildValidInputs(
        uint256 tokenIdRaw,
        uint256 principalRaw,
        uint256 shortfallRaw,
        uint256 extraNonFeeRaw,
        int128 feesAccruedRaw,
        int256 hookDeltaRaw,
        uint256 addedCreditRaw,
        uint256 feeClassifiedRaw
    ) internal pure returns (ValidInputs memory inputs) {
        inputs.tokenId = (tokenIdRaw % 1000) + 1;
        inputs.qCommitted = _retainedPrincipal(principalRaw % DOMAIN_CAP, shortfallRaw % DOMAIN_CAP);

        uint256 extra = extraNonFeeRaw % DOMAIN_CAP;
        uint256 inc = inputs.qCommitted + extra;
        inputs.nonFee = LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccruedRaw, hookDeltaRaw);
        inputs.addedCredit = addedCreditRaw % DOMAIN_CAP;
        inputs.feeClassified = feeClassifiedRaw % DOMAIN_CAP;
    }

    function _tryRouteValid(ValidInputs memory inputs) internal returns (bool ok) {
        try harness.routeLccCustodyTakeAndForward(
            lccCurrency,
            LOCKER,
            inputs.tokenId,
            inputs.nonFee,
            inputs.qCommitted,
            inputs.addedCredit,
            inputs.feeClassified
        ) {
            return true;
        } catch {
            return false;
        }
    }

    function _fuzzMMQ01ValidRoutesSucceedWhenNonFeeCoversQueue() internal view returns (bool) {
        return validAttempts == 0 || validAllOk;
    }

    function _fuzzMMQ01UnderfundedAlwaysReverts() internal view returns (bool) {
        return invalidAttempts == 0 || invalidAllOk;
    }

    function _fuzzMMQ01CustodyRecordEqualsQCommitted() internal view returns (bool) {
        return matchAttempts == 0 || matchAllOk;
    }

    function _fuzzMMQ01Smoke() internal pure returns (bool) {
        return true;
    }
}
