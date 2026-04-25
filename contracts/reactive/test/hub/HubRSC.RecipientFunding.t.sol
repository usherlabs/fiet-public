// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {HubRSCTestBase, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

contract HubRSCRecipientFundingTest is HubRSCTestBase {
    function test_registrationRequiredBeforeRecipientIntake() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB001, 1));

        assertFalse(hub.recipientRegistered(recipient));
        assertFalse(hub.recipientActive(recipient));
        assertFalse(_pendingExists(hub, lcc, recipient));
    }

    function test_registrationWithoutFundingDoesNotActivateOrIntake() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient(recipient, 0);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB011, 1));

        assertTrue(hub.recipientRegistered(recipient));
        assertFalse(hub.recipientActive(recipient));
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(_pendingExists(hub, lcc, recipient));
    }

    function test_matchingSubscribedEventDebitsRecipientFunding() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient(recipient, 3);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB021, 1));

        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(hub.recipientFundingUnits(recipient), 2);
        assertTrue(hub.recipientActive(recipient));
    }

    function test_computeKeyExposesPendingKeyDerivation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        assertEq(hub.computeKey(lcc, recipient), _computeKey(lcc, recipient));
    }

    function test_duplicateMatchingEventDoesNotDebitTwice() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        IReactive.LogRecord memory log = _rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB025, 1);

        hub.registerRecipient(recipient, 3);
        hub.react(log);
        hub.react(log);

        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(hub.recipientFundingUnits(recipient), 2);
        assertTrue(hub.recipientActive(recipient));
    }

    function test_recipientSpecificDispatchProcessingDebitsFunding() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient(recipient, 3);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB031, 1));
        assertEq(hub.recipientFundingUnits(recipient), 2);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0xB032, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 1);
        assertEq(hub.inFlightByKey(_computeKey(lcc, recipient)), 50);
        assertEq(hub.recipientFundingUnits(recipient), 1);
        assertTrue(hub.recipientActive(recipient));
    }

    function test_depletionPausesServiceUntilTopUpReactivates() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient(recipient, 1);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB041, 1));

        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(hub.recipientActive(recipient));

        _assertNoProcessSettlementsDispatched(hub, lcc, 50, bytes32("mkt"), 0xB042, 2);
        assertEq(hub.inFlightByKey(_computeKey(lcc, recipient)), 0);

        hub.fundRecipient(recipient, 1);
        assertTrue(hub.recipientActive(recipient));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0xB043, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 1);
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(hub.recipientActive(recipient));
    }

    function test_depletionOnDispatchStillAcceptsSuccessAndProcessedReconciliation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        bytes32 key = _computeKey(lcc, recipient);

        hub.registerRecipient(recipient, 2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB061, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0xB062, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (,,,, uint256[] memory attemptIds) = _decodeProcessSettlementsPayload(entries);
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(hub.recipientActive(recipient));
        assertEq(hub.inFlightByKey(key), 50);

        hub.react(_rawSettlementSucceededLog(hub, lcc, recipient, 50, attemptIds[0], 0xB063, 3));

        assertEq(hub.inFlightByKey(key), 0);
        (uint256 awaitingProcessed,) = hub.reconciliationStateByKey(key);
        assertEq(awaitingProcessed, 50);

        hub.react(_rawSettlementProcessedLogWithRequested(hub, lcc, recipient, 50, 50, 0xB064, 4));

        (, bool exists) = hub.pendingStateByKey(key);
        assertFalse(exists);
        assertEq(hub.inFlightByKey(key), 0);

        hub.fundRecipient(recipient, 2);
        assertTrue(hub.recipientActive(recipient));

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 25, 0xB065, 5));
        assertEq(hub.recipientFundingUnits(recipient), 1);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 25, bytes32("mkt"), 0xB066, 6));
        entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 1);
        assertEq(hub.inFlightByKey(key), 25);
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(hub.recipientActive(recipient));
    }

    function test_depletionOnDispatchStillAcceptsFailureAndTopUpRedispatches() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        bytes32 key = _computeKey(lcc, recipient);

        hub.registerRecipient(recipient, 2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB071, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0xB072, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (,,,, uint256[] memory attemptIds) = _decodeProcessSettlementsPayload(entries);
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(hub.recipientActive(recipient));
        assertEq(hub.inFlightByKey(key), 50);

        hub.react(_rawSettlementFailedLog(hub, lcc, recipient, 50, attemptIds[0], bytes4(0), 0xB073, 3));

        assertEq(hub.inFlightByKey(key), 0);
        (, bool retryActive) = hub.retryBlockStateByKey(key, lcc);
        assertTrue(retryActive);

        hub.fundRecipient(recipient, 1);
        assertTrue(hub.recipientActive(recipient));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0xB074, 4));
        entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 1);
        assertEq(hub.inFlightByKey(key), 50);
        assertEq(hub.recipientFundingUnits(recipient), 0);
        assertFalse(hub.recipientActive(recipient));
    }

    function test_selfContinuationIgnoresLegacyExternalContinuationOrigin() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(1, originChainId, destinationChainId, liquidityHub, destinationReceiverContract);

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address legacyContinuationOrigin = makeAddr("legacyContinuationOrigin");

        hub.registerRecipient(recipient1, 10);
        hub.registerRecipient(recipient2, 10);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 10, 0xB051, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 10, 0xB052, 2));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 20, bytes32("mkt"), 0xB053, 3));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        _assertDispatchedLength(firstEntries, 1);
        assertEq(_callbackCount(firstEntries), 1);
        (address emittedLcc, uint256 remaining) = _decodeMoreLiquidityAvailablePayload(firstEntries);
        assertEq(emittedLcc, lcc);
        assertEq(remaining, 10);

        IReactive.LogRecord memory legacyContinuation = _moreLiquidityAvailableLog(hub, lcc, remaining, 0xB054, 4);
        legacyContinuation._contract = legacyContinuationOrigin;

        vm.recordLogs();
        hub.react(legacyContinuation);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lcc, remaining, 0xB055, 5));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        _assertDispatchedLength(secondEntries, 1);
    }

    function _rawSettlementProcessedLogWithRequested(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 requestedAmount,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: hub.SETTLEMENT_PROCESSED_TOPIC(),
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(settledAmount, requestedAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _rawSettlementSucceededLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.destinationReceiverContract(),
            topic_0: hub.SETTLEMENT_SUCCEEDED_TOPIC(),
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _rawSettlementFailedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 attemptId,
        bytes4 failureSelector,
        uint256 txHash,
        uint256 logIndex
    ) private view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.destinationReceiverContract(),
            topic_0: hub.SETTLEMENT_FAILED_TOPIC(),
            topic_1: uint256(uint160(lcc)),
            topic_2: uint256(uint160(recipient)),
            topic_3: 0,
            data: abi.encode(maxAmount, attemptId, abi.encodePacked(failureSelector)),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }
}
