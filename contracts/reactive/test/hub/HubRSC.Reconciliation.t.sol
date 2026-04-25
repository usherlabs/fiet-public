// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {ReactiveConstants} from "../../src/libs/ReactiveConstants.sol";
import {SettlementFailureLib} from "../../src/libs/SettlementFailureLib.sol";
import {MockLiquidityHub} from "../_mocks/MockLiquidityHub.sol";
import {HubRSCTestBase, MockSettlementReceiver, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

contract HubRSCReconciliationTest is HubRSCTestBase {
    /// @notice Direct receiver outcomes release reservations and reconcile pending state without any recipient-specific spoke.
    function test_directReceiverLifecycleDoesNotNeedRecipientSpoke() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver));

        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_lccCreatedLog(hub, underlying, lcc, bytes32("mkt"), 0x1210, 1));
        hub.react(_protocolSettlementQueuedLog(hub, lcc, recipient, 50, 0x1211, 2));
        hub.react(liquidityAvailableLog(address(liq), lcc, underlying, 50, bytes32("mkt"), 0x1212, 3));

        assertEq(hub.inFlightByKey(key), 50);

        hub.react(_receiverSettlementSucceededLog(hub, lcc, recipient, 50, 1, 0x1213, 4));
        assertEq(hub.inFlightByKey(key), 0);

        (uint256 pendingAmount, bool existsAfterSuccess) = _pendingState(hub, key);
        assertTrue(existsAfterSuccess);
        assertEq(pendingAmount, 50);

        hub.react(_protocolSettlementProcessedLog(hub, lcc, recipient, 50, 50, 0x1214, 5));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertFalse(exists);
        assertEq(remaining, 0);
    }

    function test_reconcilesPendingFromSettlementAnnulled() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 70, 1, 0x9001, 1));
        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 30, 0x9002, 1));

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 40);
    }

    /// @notice A fully settled pre-registration key clears its historical backfill debt when prune removes it.
    function test_pruneClearsHistoricalBackfillDebtForFullySettledPreRegistrationKey() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 70, 1, 0x9003, 1));
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 1);

        hub.react(_settlementProcessedLog(hub, lcc, recipient, 70, 0x9004, 2));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertFalse(exists);
        assertEq(remaining, 0);
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 0);
        assertFalse(hub.inQueue(key));
    }

    function test_unknownFailureBlocksSameKeyUntilFreshProtocolWakeAndMoreLiquidityDoesNotClear() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9101, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9102, 2));
        Vm.Log[] memory firstDispatch = vm.getRecordedLogs();
        (, address[] memory lccs,, uint256[] memory amounts, uint256[] memory attemptIds) =
            _decodeProcessSettlementsPayload(firstDispatch);
        assertEq(lccs.length, 1);
        assertEq(amounts[0], 100);
        assertEq(attemptIds[0], 1);
        assertEq(hub.inFlightByKey(_computeKey(lcc, recipient)), 100);

        vm.recordLogs();
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                recipient,
                100,
                1,
                bytes4(keccak256("UnknownFailure()")),
                SettlementFailureLib.FAILURE_CLASS_UNKNOWN,
                0x9103,
                1
            )
        );
        Vm.Log[] memory retryEntries = vm.getRecordedLogs();
        assertTrue(_pendingExists(hub, lcc, recipient));
        assertFalse(_hasTerminalFailure(hub, key));
        assertEq(hub.inFlightByKey(key), 0);
        assertEq(hub.availableBudgetByDispatchLane(address(0)), 100);
        assertEq(hub.availableBudgetByDispatchLane(lcc), 0);
        (uint256 blockedAtWakeEpoch, bool active) = _retryBlockState(hub, key, lcc);
        assertEq(blockedAtWakeEpoch, 1);
        assertTrue(active);
        assertEq(_findCallbackPayloadBySelector(retryEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lcc, 100, 0x9104, 2));
        Vm.Log[] memory moreLiquidityEntries = vm.getRecordedLogs();
        assertEq(
            _findCallbackPayloadBySelector(moreLiquidityEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length,
            0
        );
        (blockedAtWakeEpoch, active) = _retryBlockState(hub, key, lcc);
        assertEq(blockedAtWakeEpoch, 1);
        assertTrue(active);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9105, 3));
        Vm.Log[] memory wakeEntries = vm.getRecordedLogs();
        (, lccs,, amounts, attemptIds) = _decodeProcessSettlementsPayload(wakeEntries);
        assertEq(lccs.length, 1);
        assertEq(amounts[0], 100);
        assertEq(attemptIds[0], 2);
        assertEq(hub.inFlightByKey(key), 100);
        (, active) = _retryBlockState(hub, key, lcc);
        assertFalse(active);
    }

    function test_unknownFailureAllowsSiblingDispatchButNotFailedKeyInSameWakeChain() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address failedRecipient = makeAddr("failedRecipient");
        address siblingRecipient = makeAddr("siblingRecipient");
        address lcc = makeAddr("lcc");
        bytes32 failedKey = _computeKey(lcc, failedRecipient);
        bytes32 siblingKey = _computeKey(lcc, siblingRecipient);

        hub.react(_settlementLog(hub, failedRecipient, lcc, 100, 1, 0x9110, 1));
        hub.react(_settlementLog(hub, siblingRecipient, lcc, 100, 2, 0x9111, 2));

        uint256 failedAttemptId = _dispatchSingleAttemptId(hub, lcc, 100, bytes32("mkt"), 0x9112, 3);
        assertEq(hub.inFlightByKey(failedKey), 100);
        assertEq(hub.inFlightByKey(siblingKey), 0);

        vm.recordLogs();
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                failedRecipient,
                100,
                failedAttemptId,
                bytes4(keccak256("UnknownFailure()")),
                SettlementFailureLib.FAILURE_CLASS_UNKNOWN,
                0x9113,
                4
            )
        );
        Vm.Log[] memory retryEntries = vm.getRecordedLogs();
        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts, uint256[] memory attemptIds) =
            _decodeProcessSettlementsPayload(retryEntries);

        assertEq(lccs.length, 1);
        assertEq(recipients[0], siblingRecipient);
        assertEq(amounts[0], 100);
        assertGt(attemptIds[0], failedAttemptId);
        assertEq(hub.inFlightByKey(failedKey), 0);
        assertEq(hub.inFlightByKey(siblingKey), 100);
        (, bool active) = _retryBlockState(hub, failedKey, lcc);
        assertTrue(active);
    }

    function test_retryBlockClearsOnAuthoritativeAnnulmentAndAllowsLaterContinuationDispatch() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        uint256 failedAttemptId = _dispatchSingleAttemptIdAfterQueue(hub, lcc, recipient, 100, 0x9114, 1, 0x9115, 2);
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                recipient,
                100,
                failedAttemptId,
                bytes4(keccak256("UnknownFailure()")),
                SettlementFailureLib.FAILURE_CLASS_UNKNOWN,
                0x9116,
                3
            )
        );

        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 10, 0x9117, 4));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 90);
        assertEq(hub.inFlightByKey(key), 0);
        (, bool active) = _retryBlockState(hub, key, lcc);
        assertFalse(active);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lcc, 100, 0x9118, 5));
        Vm.Log[] memory continuationEntries = vm.getRecordedLogs();
        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts, uint256[] memory attemptIds) =
            _decodeProcessSettlementsPayload(continuationEntries);

        assertEq(lccs.length, 1);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 90);
        assertGt(attemptIds[0], failedAttemptId);
        assertEq(hub.inFlightByKey(key), 90);
    }

    function test_duplicateLiquiditySignalScrubsPhantomBudgetUntilFreshWakeup() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");
        address lcc = makeAddr("lcc");
        address firstRecipient;
        uint256 firstAttemptId;
        address secondRecipient;
        uint256 secondAttemptId;

        hub.react(_settlementLog(hub, recipientA, lcc, 100, 1, 0x9201, 1));
        hub.react(_settlementLog(hub, recipientB, lcc, 100, 2, 0x9202, 2));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9203, 3));
        Vm.Log[] memory firstDispatch = vm.getRecordedLogs();
        {
            (
                ,
                address[] memory firstLccs,
                address[] memory firstRecipients,
                uint256[] memory firstAmounts,
                uint256[] memory firstAttemptIds
            ) = _decodeProcessSettlementsPayload(firstDispatch);
            assertEq(firstLccs.length, 1);
            assertEq(firstAmounts[0], 100);
            assertEq(firstRecipients[0], recipientA);
            firstRecipient = firstRecipients[0];
            firstAttemptId = firstAttemptIds[0];
        }

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9204, 4));
        Vm.Log[] memory secondDispatch = vm.getRecordedLogs();
        {
            (
                ,
                address[] memory secondLccs,
                address[] memory secondRecipients,
                uint256[] memory secondAmounts,
                uint256[] memory secondAttemptIds
            ) = _decodeProcessSettlementsPayload(secondDispatch);
            assertEq(secondLccs.length, 1);
            assertEq(secondAmounts[0], 100);
            assertEq(secondRecipients[0], recipientB);
            secondRecipient = secondRecipients[0];
            secondAttemptId = secondAttemptIds[0];
        }

        _applyProcessedAndSucceeded(hub, lcc, firstRecipient, 100, firstAttemptId, 0x9210, 1);

        bytes32 failedKey = _computeKey(lcc, secondRecipient);
        vm.recordLogs();
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                secondRecipient,
                100,
                secondAttemptId,
                SettlementFailureLib.LIQUIDITY_ERROR_SELECTOR,
                SettlementFailureLib.FAILURE_CLASS_REQUIRES_FRESH_LIQUIDITY,
                0x9220,
                2
            )
        );
        Vm.Log[] memory failureEntries = vm.getRecordedLogs();

        assertTrue(_pendingExists(hub, lcc, secondRecipient));
        assertEq(hub.inFlightByKey(failedKey), 0);
        assertEq(hub.availableBudgetByDispatchLane(lcc), 0);
        assertEq(
            _findCallbackPayloadBySelector(failureEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0
        );

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9230, 5));
        Vm.Log[] memory wakeEntries = vm.getRecordedLogs();
        (
            ,
            address[] memory wakeLccs,
            address[] memory wakeRecipients,
            uint256[] memory wakeAmounts,
            uint256[] memory wakeAttemptIds
        ) = _decodeProcessSettlementsPayload(wakeEntries);

        assertEq(wakeLccs.length, 1);
        assertEq(wakeRecipients[0], secondRecipient);
        assertEq(wakeAmounts[0], 100);
        assertGt(wakeAttemptIds[0], secondAttemptId);
    }

    function test_terminalNotApprovedFailureIsQuarantinedAndNotRedispatched() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9111, 1));
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 1);
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9112, 2));
        assertEq(hub.inFlightByKey(key), 100);

        vm.recordLogs();
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                recipient,
                100,
                1,
                SettlementFailureLib.NOT_APPROVED_SELECTOR,
                SettlementFailureLib.FAILURE_CLASS_TERMINAL_POLICY,
                0x9113,
                3
            )
        );
        Vm.Log[] memory quarantineEntries = vm.getRecordedLogs();

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 100);
        assertEq(hub.inFlightByKey(key), 0);
        assertTrue(_hasTerminalFailure(hub, key));
        assertEq(_terminalFailureSelector(hub, key), SettlementFailureLib.NOT_APPROVED_SELECTOR);
        assertEq(_terminalFailureClass(hub, key), SettlementFailureLib.FAILURE_CLASS_TERMINAL_POLICY);
        assertFalse(hub.inQueue(key));
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 0);
        assertEq(
            _findCallbackPayloadBySelector(quarantineEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0
        );

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9114, 4));
        Vm.Log[] memory laterEntries = vm.getRecordedLogs();

        assertEq(_findCallbackPayloadBySelector(laterEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        assertTrue(_hasTerminalFailure(hub, key));
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_terminalFailureOnSameUnderlyingStillAllowsSiblingDispatch() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address triggerLcc = makeAddr("triggerLcc");
        address badLcc = makeAddr("badLcc");
        address goodLcc = makeAddr("goodLcc");
        address badRecipient = makeAddr("badRecipient");
        address goodRecipient = makeAddr("goodRecipient");

        hub.react(_lccCreatedLog(hub, underlying, triggerLcc, bytes32("mktA"), 0x9120, 1));
        hub.react(_lccCreatedLog(hub, underlying, badLcc, bytes32("mktB"), 0x9121, 2));
        hub.react(_lccCreatedLog(hub, underlying, goodLcc, bytes32("mktC"), 0x9122, 3));
        hub.react(_settlementLog(hub, badRecipient, badLcc, 100, 1, 0x9123, 4));
        hub.react(_settlementLog(hub, goodRecipient, goodLcc, 50, 1, 0x9124, 5));

        hub.react(liquidityAvailableLog(hub.liquidityHub(), triggerLcc, underlying, 100, bytes32("mktA"), 0x9125, 6));
        assertEq(hub.inFlightByKey(_computeKey(badLcc, badRecipient)), 100);
        assertEq(hub.inFlightByKey(_computeKey(goodLcc, goodRecipient)), 0);

        vm.recordLogs();
        hub.react(
            _settlementFailedLog(
                hub,
                badLcc,
                badRecipient,
                100,
                1,
                SettlementFailureLib.NOT_APPROVED_SELECTOR,
                SettlementFailureLib.FAILURE_CLASS_TERMINAL_POLICY,
                0x9126,
                7
            )
        );
        Vm.Log[] memory siblingEntries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(siblingEntries);
        assertEq(lccs.length, 1);
        assertEq(lccs[0], goodLcc);
        assertEq(recipients[0], goodRecipient);
        assertEq(amounts[0], 50);
        assertTrue(_hasTerminalFailure(hub, _computeKey(badLcc, badRecipient)));
        assertEq(hub.inFlightByKey(_computeKey(goodLcc, goodRecipient)), 50);
    }

    function test_terminalFailureClearsOnFreshQueueMutation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9131, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9132, 2));
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                recipient,
                100,
                1,
                SettlementFailureLib.NOT_APPROVED_SELECTOR,
                SettlementFailureLib.FAILURE_CLASS_TERMINAL_POLICY,
                0x9133,
                3
            )
        );
        assertTrue(_hasTerminalFailure(hub, key));
        assertFalse(hub.inQueue(key));
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 0);

        hub.react(_settlementLog(hub, recipient, lcc, 25, 2, 0x9134, 4));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 125);
        assertFalse(_hasTerminalFailure(hub, key));
        assertTrue(hub.inQueue(key));
        assertEq(hub.inFlightByKey(key), 100);
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 0);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 125, bytes32("mkt"), 0x9135, 5));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, 1);
        assertEq(lccs[0], lcc);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 25);
    }

    function test_terminalFailureClearsOnAuthoritativeDecrease() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9141, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9142, 2));
        hub.react(
            _settlementFailedLog(
                hub,
                lcc,
                recipient,
                100,
                1,
                SettlementFailureLib.NOT_APPROVED_SELECTOR,
                SettlementFailureLib.FAILURE_CLASS_TERMINAL_POLICY,
                0x9143,
                3
            )
        );
        assertTrue(_hasTerminalFailure(hub, key));
        assertFalse(hub.inQueue(key));
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 0);

        vm.recordLogs();
        hub.react(_settlementProcessedLog(hub, lcc, recipient, 40, 0x9144, 4));
        Vm.Log[] memory processedEntries = vm.getRecordedLogs();
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 60);
        assertFalse(_hasTerminalFailure(hub, key));
        assertTrue(hub.inQueue(key));
        assertEq(hub.underlyingBackfillRemainingByLcc(lcc), 0);

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(processedEntries);
        assertEq(lccs.length, 1);
        assertEq(lccs[0], lcc);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 60);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 60, bytes32("mkt"), 0x9145, 5));
        Vm.Log[] memory laterEntries = vm.getRecordedLogs();
        assertEq(_findCallbackPayloadBySelector(laterEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
    }

    function test_manualSettlementProcessedLogReconcilesWithoutDispatch() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 90, 1, 0x9201, 1));
        hub.react(_settlementProcessedLog(hub, lcc, recipient, 40, 0x9202, 1));

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 50);
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_buffersOutOfOrderProcessedAndAppliesOnQueued() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementProcessedLog(hub, lcc, recipient, 30, 0x9301, 1));
        (uint256 bufferedSettled, uint256 bufferedInFlight) = _bufferedProcessedState(hub, key);
        assertEq(bufferedSettled, 30);
        assertEq(bufferedInFlight, 0);
        assertFalse(_pendingExists(hub, lcc, recipient));

        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9302, 2));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 20);
        (bufferedSettled, bufferedInFlight) = _bufferedProcessedState(hub, key);
        assertEq(bufferedSettled, 0);
        assertEq(bufferedInFlight, 0);
    }

    function test_buffersOutOfOrderAnnulledAndAppliesOnQueued() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 20, 0x9401, 1));
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 20);
        assertFalse(_pendingExists(hub, lcc, recipient));

        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9402, 2));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 30);
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 0);
    }

    /// @dev Annulled can arrive before multiple SettlementQueued deltas; excess must not be discarded at first apply.
    function test_buffersAnnulledLargerThanFirstQueued_carriesRemainderAcrossLaterQueueAdds() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 120, 0x9411, 1));
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 120);
        assertFalse(_pendingExists(hub, lcc, recipient));

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9412, 2));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertFalse(exists);
        assertEq(remaining, 0);
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 20);

        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9413, 3));
        (remaining, exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 30);
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 0);
    }

    /// @dev Processed-before-queue can exceed the first mirrored queue increment; settled remainder must carry forward.
    function test_buffersProcessedLargerThanFirstQueued_carriesSettledRemainder() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 80, 80, 0x9421, 1));
        (uint256 bufSettled, uint256 bufInflight) = _bufferedProcessedState(hub, key);
        assertEq(bufSettled, 80);
        assertEq(bufInflight, 0);
        assertFalse(_pendingExists(hub, lcc, recipient));

        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9422, 2));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertFalse(exists);
        assertEq(remaining, 0);
        (bufSettled, bufInflight) = _bufferedProcessedState(hub, key);
        assertEq(bufSettled, 30);
        assertEq(bufInflight, 0);

        hub.react(_settlementLog(hub, recipient, lcc, 40, 1, 0x9423, 3));
        (remaining, exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 10);
        (bufSettled, bufInflight) = _bufferedProcessedState(hub, key);
        assertEq(bufSettled, 0);
        assertEq(bufInflight, 0);
    }

    /// @dev Permissionless requestedAmount no longer releases reservations or buffers synthetic in-flight reductions.
    function test_processedRequestedAmountNoLongerReleasesReservation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 200, 1, 0x9711, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9712, 2));
        assertEq(hub.inFlightByKey(key), 100);

        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 150, 150, 0x9713, 3));
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 50);
        assertEq(hub.inFlightByKey(key), 100);
        (uint256 bufSettled, uint256 bufInflight) = _bufferedProcessedState(hub, key);
        assertEq(bufSettled, 0);
        assertEq(bufInflight, 0);

        hub.react(_settlementSucceededLog(hub, lcc, recipient, 150, 1, 0x9714, 4));
        assertEq(hub.inFlightByKey(key), 0);

        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0x9715, 5));
        assertEq(hub.inFlightByKey(key), 50);
        (remaining, exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 50);

        hub.react(_settlementLog(hub, recipient, lcc, 10, 1, 0x9716, 6));
        assertEq(hub.inFlightByKey(key), 50);
        (remaining, exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 60);
    }

    function test_deduplicatesAuthoritativeProcessedByLogIdentity() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 80, 1, 0x9501, 1));

        IReactive.LogRecord memory processedLog = _settlementProcessedLog(hub, lcc, recipient, 30, 0x9502, 2);
        bytes32 authoritativeReportId = keccak256(
            abi.encode(processedLog.chain_id, processedLog._contract, processedLog.tx_hash, processedLog.log_index)
        );

        hub.react(processedLog);
        hub.react(processedLog);

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 50);
        assertTrue(hub.processedReport(authoritativeReportId));
    }

    function test_releasesUnusedInFlightReservationOnTrustedSuccess() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9601, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9602, 2));
        assertEq(hub.inFlightByKey(key), 100);

        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 60, 100, 0x9603, 3));
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 100, 1, 0x9604, 4));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 40);
        assertEq(hub.inFlightByKey(key), 0);
        (uint256 awaitingProcessed, uint256 processedCredit) = _reconciliationState(hub, key);
        assertEq(awaitingProcessed, 0);
        assertEq(processedCredit, 0);
    }

    function test_exaggeratedSuccessAmountReleasesOnlyAttemptReservation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        uint256 attemptId = _dispatchSingleAttemptIdAfterQueue(hub, lcc, recipient, 100, 0x9605, 1, 0x9606, 2);
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 1_000_000, attemptId, 0x9607, 3));

        assertEq(hub.inFlightByKey(key), 0);
        assertEq(_attemptReservationAmount(hub, attemptId), 0);
        (uint256 awaitingProcessed, uint256 processedCredit) = _reconciliationState(hub, key);
        assertEq(awaitingProcessed, 100);
        assertEq(processedCredit, 0);
    }

    function test_exaggeratedSuccessAmountDoesNotRedispatchBeforeProcessedReconciliation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        uint256 attemptId = _dispatchSingleAttemptIdAfterQueue(hub, lcc, recipient, 100, 0x9608, 1, 0x9609, 2);
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 1_000_000, attemptId, 0x960A, 3));

        _assertNoProcessSettlementsDispatched(hub, lcc, 100, bytes32("mkt"), 0x960B, 4);
    }

    function test_partialFillOrderingWithExaggeratedSuccessLeavesOnlyRemainderDispatchable() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        uint256 attemptId = _dispatchSingleAttemptIdAfterQueue(hub, lcc, recipient, 100, 0x960C, 1, 0x960D, 2);
        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 60, 100, 0x960E, 3));
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 1_000_000, attemptId, 0x960F, 4));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 40);
        assertEq(hub.inFlightByKey(key), 0);
        (uint256 awaitingProcessed, uint256 processedCredit) = _reconciliationState(hub, key);
        assertEq(awaitingProcessed, 0);
        assertEq(processedCredit, 0);
    }

    function test_successBeforeProcessedDoesNotRedispatchSameKeyUntilProcessedReconciles() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9610, 1));

        uint256 attemptA = _dispatchSingleAttemptId(hub, lcc, 100, bytes32("mkt"), 0x9611, 2);
        assertEq(hub.inFlightByKey(key), 100);

        hub.react(_settlementSucceededLog(hub, lcc, recipient, 100, attemptA, 0x9612, 3));
        assertEq(hub.inFlightByKey(key), 0);
        (uint256 awaitingProcessed, uint256 processedCredit) = _reconciliationState(hub, key);
        assertEq(awaitingProcessed, 100);
        assertEq(processedCredit, 0);

        _assertNoProcessSettlementsDispatched(hub, lcc, 100, bytes32("mkt"), 0x9613, 4);
        (awaitingProcessed, processedCredit) = _reconciliationState(hub, key);
        assertEq(awaitingProcessed, 100);
        assertEq(processedCredit, 0);

        vm.recordLogs();
        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 60, 100, 0x9614, 5));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 40);
        (awaitingProcessed, processedCredit) = _reconciliationState(hub, key);
        assertEq(awaitingProcessed, 0);
        assertEq(processedCredit, 0);
        assertEq(hub.inFlightByKey(key), 40);

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts, uint256[] memory attemptIds) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, 1);
        assertEq(lccs[0], lcc);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 40);
        assertGt(attemptIds[0], attemptA);
    }

    function test_trustedSuccessReleasesOnlyMatchingAttemptWhenLaterReservationIsLive() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9620, 1));

        uint256 attemptA = _dispatchSingleAttemptId(hub, lcc, 100, bytes32("mkt"), 0x9621, 2);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 2, 0x9622, 3));

        uint256 attemptB = _dispatchSingleAttemptId(hub, lcc, 100, bytes32("mkt"), 0x9623, 4);

        assertEq(hub.inFlightByKey(key), 200);
        uint256 attemptAAmount = _attemptReservationAmount(hub, attemptA);
        uint256 attemptBAmount = _attemptReservationAmount(hub, attemptB);
        assertEq(attemptAAmount, 100);
        assertEq(attemptBAmount, 100);

        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 100, 100, 0x9624, 5));
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 100, attemptA, 0x9625, 6));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 100);
        assertEq(hub.inFlightByKey(key), 100);

        attemptAAmount = _attemptReservationAmount(hub, attemptA);
        attemptBAmount = _attemptReservationAmount(hub, attemptB);
        assertEq(attemptAAmount, 0);
        assertEq(attemptBAmount, 100);

        _assertNoProcessSettlementsDispatched(hub, lcc, 100, bytes32("mkt"), 0x9626, 7);
    }

    function test_releasesInFlightWhenTrustedSuccessSettlesZero() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = _computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9611, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9612, 2));
        assertEq(hub.inFlightByKey(key), 100);

        hub.react(_settlementSucceededLog(hub, lcc, recipient, 100, 1, 0x9613, 3));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 100);
        assertEq(hub.inFlightByKey(key), 0);
    }
}
