// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {FuzzHelper} from "./FuzzHelper.sol";
import {PositionManagerImplQueueCustodyHarness} from "./harnesses/PositionManagerImplQueueCustodyHarness.sol";
import {FuzzTakeOrchestratorMock, FuzzMMQueueCustodian} from "./mocks/FuzzQueueCustodyMocks.sol";
import {MockLCC} from "../_mocks/MockLCC.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidityUtils} from "../../src/libraries/LiquidityUtils.sol";
import {Errors} from "../../src/libraries/Errors.sol";

/// @notice Medusa / FuzzEntry module: MM queue custody guard (same semantics as `invariants/MMQ01.sol`).
/// @dev Runtime `new` for orchestrator, custodian, harness, and LCC — no Echidna linked-library map.
///      Mirrors `PositionManagerImpl._routeLccCustodyTakeAndForward` via `PositionManagerImplQueueCustodyHarness`.
///      Production routing debits locker delta only by `custodyForward` for commit buckets; surplus `nonFee - qCommitted`
///      stays as locker credit (see `LiquidityUtils.lockerLccTakeAmountBeforeCustodyForward`).
abstract contract FuzzMMQ01 is FuzzHelper {
    uint256 internal constant DOMAIN_CAP = 1e24;

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
    // forge-lint: disable-next-line(mixed-case-function)
    function action_valid_commit_custody_guard_holds(
        uint256 tokenIdRaw,
        uint256,
        /* qCommittedRaw */
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

        uint256 tokenId = (tokenIdRaw % 1000) + 1;
        uint256 qCommitted = _retainedPrincipal(principalRaw % DOMAIN_CAP, shortfallRaw % DOMAIN_CAP);

        uint256 extra = extraNonFeeRaw % DOMAIN_CAP;
        uint256 inc = qCommitted + extra;
        int128 feesAccrued = feesAccruedRaw;
        int256 hookDelta = hookDeltaRaw;
        uint256 nonFee = LiquidityUtils.forwardedNonFeeLccAmount(inc, feesAccrued, hookDelta);

        if (qCommitted > 0 && nonFee < qCommitted) {
            return;
        }

        uint256 addedCredit = addedCreditRaw % DOMAIN_CAP;
        uint256 feeClassified = feeClassifiedRaw % DOMAIN_CAP;

        bool ok;
        try harness.routeLccCustodyTakeAndForward(
            lccCurrency, LOCKER, tokenId, nonFee, qCommitted, addedCredit, feeClassified
        ) {
            ok = true;
        } catch {
            ok = false;
        }

        if (!ok) {
            validAllOk = false;
            return;
        }

        if (qCommitted > 0) {
            if (harness.lastCustodyForwarded() != qCommitted) {
                validAllOk = false;
            }
        } else if (harness.lastCustodyForwarded() != 0) {
            validAllOk = false;
        }
    }

    /// @notice Invalid region: `nonFee < qCommitted` with `tokenId > 0` — must revert `InsufficientBalance`.
    // forge-lint: disable-next-line(mixed-case-function)
    function action_invalid_underfunded_non_fee_reverts(uint256 tokenIdRaw, uint256 qCommittedRaw, uint256 nonFeeRaw)
        external
    {
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
    // forge-lint: disable-next-line(mixed-case-function)
    function action_custody_record_matches_q_committed(
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

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mmq01_valid_routes_succeed_when_non_fee_covers_queue() external view returns (bool) {
        return validAttempts == 0 || validAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mmq01_underfunded_always_reverts() external view returns (bool) {
        return invalidAttempts == 0 || invalidAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mmq01_custody_record_equals_q_committed() external view returns (bool) {
        return matchAttempts == 0 || matchAllOk;
    }

    // forge-lint: disable-next-line(mixed-case-function)
    function echidna_mmq01_smoke() external pure returns (bool) {
        return true;
    }
}
