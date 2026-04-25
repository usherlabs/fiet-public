// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {HubRSCTestBase, MockSystemContract, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

contract HubRSCRecipientFundingTest is HubRSCTestBase {
    event RecipientFunded(address indexed recipient, uint256 depositAmount, int256 balance);
    event RecipientActivated(address indexed recipient, int256 balance);
    event RecipientDeactivated(address indexed recipient, int256 balance);
    event RecipientDebtAllocated(address indexed recipient, uint256 debtAmount, int256 balance);
    event UnallocatedDebtObserved(uint256 debtAmount, uint256 observedDebt);

    function test_registrationRequiredBeforeRecipientIntake() public {
        HubRSC hub = _deployHub();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB001, 1));

        assertFalse(hub.recipientRegistered(recipient));
        assertFalse(hub.recipientActive(recipient));
        assertFalse(_pendingExists(hub, lcc, recipient));
    }

    function test_registrationWithoutValueInactivePayableRegistrationActive() public {
        HubRSC hub = _deployHub();
        address recipientWithoutValue = makeAddr("recipientWithoutValue");
        address payable fundedRecipient = payable(makeAddr("fundedRecipient"));

        hub.registerRecipient(recipientWithoutValue);
        hub.registerRecipient{value: 3 ether}(fundedRecipient);

        assertTrue(hub.recipientRegistered(recipientWithoutValue));
        assertFalse(hub.recipientActive(recipientWithoutValue));
        assertEq(hub.recipientBalance(recipientWithoutValue), 0);

        assertTrue(hub.recipientRegistered(fundedRecipient));
        assertTrue(hub.recipientActive(fundedRecipient));
        assertEq(hub.recipientBalance(fundedRecipient), int256(3 ether));
    }

    function test_topUpFromNegativeOnlyReactivatesWhenPositive() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient{value: 1 ether}(recipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB011, 1));
        _setDebtAndSync(hub, system, 2 ether);

        assertEq(hub.recipientBalance(recipient), -1 ether);
        assertFalse(hub.recipientActive(recipient));

        hub.fundRecipient{value: 0.5 ether}(recipient);
        assertEq(hub.recipientBalance(recipient), -0.5 ether);
        assertFalse(hub.recipientActive(recipient));

        hub.fundRecipient{value: 1 ether}(recipient);
        assertEq(hub.recipientBalance(recipient), 0.5 ether);
        assertTrue(hub.recipientActive(recipient));
    }

    function test_recipientPaymentLifecycleEvents() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient(recipient);

        vm.expectEmit(true, false, false, true, address(hub));
        emit RecipientFunded(recipient, 1 ether, 1 ether);
        vm.expectEmit(true, false, false, true, address(hub));
        emit RecipientActivated(recipient, 1 ether);
        hub.fundRecipient{value: 1 ether}(recipient);

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB019, 1));
        system.setDebt(address(hub), 2 ether);

        vm.expectEmit(true, false, false, true, address(hub));
        emit RecipientDebtAllocated(recipient, 2 ether, -1 ether);
        vm.expectEmit(true, false, false, true, address(hub));
        emit RecipientDeactivated(recipient, -1 ether);
        hub.syncSystemDebt();

        vm.expectEmit(true, false, false, true, address(hub));
        emit RecipientFunded(recipient, 2 ether, 1 ether);
        vm.expectEmit(true, false, false, true, address(hub));
        emit RecipientActivated(recipient, 1 ether);
        hub.fundRecipient{value: 2 ether}(recipient);
    }

    function test_lifecycleDebtAllocationUsesObservedSystemDebt() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient{value: 100 ether}(recipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB021, 1));
        _setDebtAndSync(hub, system, 7 ether);

        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(hub.recipientBalance(recipient), 93 ether);
        assertTrue(hub.recipientActive(recipient));
        assertEq(system.debt(address(hub)), 0);
    }

    function test_unallocatedDebtIsPaidWithoutChangingRecipientBalances() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        (bool success,) = payable(address(hub)).call{value: 10 ether}("");
        assertTrue(success);

        hub.react(
            IReactive.LogRecord({
                chain_id: hub.protocolChainId(),
                _contract: hub.liquidityHub(),
                topic_0: 0xDEAD,
                topic_1: 0,
                topic_2: 0,
                topic_3: 0,
                data: "",
                block_number: 0,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0xB029,
                log_index: 1
            })
        );
        system.setDebt(address(hub), 3 ether);

        vm.expectEmit(false, false, false, true, address(hub));
        emit UnallocatedDebtObserved(3 ether, 3 ether);
        hub.syncSystemDebt();

        assertEq(system.debt(address(hub)), 0);
        assertEq(system.received(address(hub)), 3 ether);
    }

    function test_duplicateLogsDoNotDoubleAllocateDebt() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        IReactive.LogRecord memory log = _rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB031, 1);

        hub.registerRecipient{value: 100 ether}(recipient);
        hub.react(log);
        system.setDebt(address(hub), 10 ether);
        hub.react(log);

        assertEq(hub.recipientBalance(recipient), 90 ether);
        assertTrue(_pendingExists(hub, lcc, recipient));

        system.setDebt(address(hub), 3 ether);
        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(recipient), 87 ether);
        system.setDebt(address(hub), 2 ether);
        vm.expectEmit(false, false, false, true, address(hub));
        emit UnallocatedDebtObserved(2 ether, 2 ether);
        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(recipient), 87 ether);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_dispatchDebtSplitsAcrossRecipients() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");

        hub.registerRecipient{value: 100 ether}(recipient1);
        hub.registerRecipient{value: 100 ether}(recipient2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 50, 0xB041, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 50, 0xB042, 2));
        _consumeDebtContexts(hub, system, 4);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0xB043, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 2);
        _setDebtAndSync(hub, system, 10 ether);

        assertEq(hub.recipientBalance(recipient1), 95 ether - 2);
        assertEq(hub.recipientBalance(recipient2), 95 ether - 2);
        assertTrue(hub.recipientActive(recipient1));
        assertTrue(hub.recipientActive(recipient2));
    }

    function test_dispatchDebtRemainderIsChargedToFinalRecipient() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.registerRecipient{value: 100}(recipient3);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB044, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB045, 2));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient3, 1, 0xB046, 3));
        _consumeDebtContexts(hub, system, 6);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 3, bytes32("mkt"), 0xB047, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 3);
        _setDebtAndSync(hub, system, 10);

        assertEq(hub.recipientBalance(recipient1), 95);
        assertEq(hub.recipientBalance(recipient2), 95);
        assertEq(hub.recipientBalance(recipient3), 94);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_partialVendorDebtPaymentDoesNotDoubleChargeRecipientOnTopUp() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient{value: 1 ether}(recipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB048, 1));
        system.setDebt(address(hub), 5 ether);
        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(recipient), -4 ether);
        assertFalse(hub.recipientActive(recipient));
        assertEq(system.debt(address(hub)), 4 ether);
        assertEq(system.received(address(hub)), 1 ether);

        hub.fundRecipient{value: 4 ether}(recipient);

        assertEq(hub.recipientBalance(recipient), 0);
        assertFalse(hub.recipientActive(recipient));
        assertEq(system.debt(address(hub)), 0);
        assertEq(system.received(address(hub)), 5 ether);

        hub.fundRecipient{value: 1}(recipient);

        assertEq(hub.recipientBalance(recipient), 1);
        assertTrue(hub.recipientActive(recipient));
        assertEq(system.debt(address(hub)), 0);
        assertEq(system.received(address(hub)), 5 ether);
    }

    function test_lifecycleContextAfterDispatchDoesNotOverwriteUnsyncedDispatchDebt() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address dispatchRecipient1 = makeAddr("dispatchRecipient1");
        address dispatchRecipient2 = makeAddr("dispatchRecipient2");
        address lifecycleRecipient = makeAddr("lifecycleRecipient");

        hub.registerRecipient{value: 100}(dispatchRecipient1);
        hub.registerRecipient{value: 100}(dispatchRecipient2);
        hub.registerRecipient{value: 100}(lifecycleRecipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, dispatchRecipient1, 1, 0xB049, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, dispatchRecipient2, 1, 0xB04A, 2));
        _consumeDebtContexts(hub, system, 5);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 2, bytes32("mkt"), 0xB04B, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 2);

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, lifecycleRecipient, 1, 0xB04C, 4));
        system.setDebt(address(hub), 9);
        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(dispatchRecipient1), 94);
        assertEq(hub.recipientBalance(dispatchRecipient2), 93);
        assertEq(hub.recipientBalance(lifecycleRecipient), 99);

        system.setDebt(address(hub), 2);
        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(dispatchRecipient1), 94);
        assertEq(hub.recipientBalance(dispatchRecipient2), 93);
        assertEq(hub.recipientBalance(lifecycleRecipient), 97);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_ignoredLogDoesNotClearUnsyncedDispatchDebtContext() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB04D, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB04E, 2));
        _consumeDebtContexts(hub, system, 4);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 2, bytes32("mkt"), 0xB04F, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 2);

        hub.react(
            IReactive.LogRecord({
                chain_id: hub.protocolChainId(),
                _contract: hub.liquidityHub(),
                topic_0: 0xDEAD,
                topic_1: 0,
                topic_2: 0,
                topic_3: 0,
                data: "",
                block_number: 0,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0xB050,
                log_index: 4
            })
        );
        _setDebtAndSync(hub, system, 7);

        assertEq(hub.recipientBalance(recipient1), 95);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_duplicateLogDoesNotClearUnsyncedDispatchDebtContext() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        IReactive.LogRecord memory firstQueued = _rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB059, 1);

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.react(firstQueued);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB05A, 2));
        _consumeDebtContexts(hub, system, 4);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 2, bytes32("mkt"), 0xB05B, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 2);

        hub.react(firstQueued);
        _setDebtAndSync(hub, system, 5);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 95);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_dispatchContextsQueueInOrderBeforeDebtIsObserved() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB05C, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB05D, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB05E, 3));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB05F, 4));
        entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 100);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_queuedDeferredDebtContextsSurviveIgnoredAndDuplicateLogsBeforePromotion() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        IReactive.LogRecord memory firstQueued = _rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB060, 1);
        IReactive.LogRecord memory secondQueued = _rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB061, 3);

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.react(firstQueued);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB062, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.react(secondQueued);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB063, 4));
        entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.react(
            IReactive.LogRecord({
                chain_id: hub.protocolChainId(),
                _contract: hub.liquidityHub(),
                topic_0: 0xDEAD,
                topic_1: 0,
                topic_2: 0,
                topic_3: 0,
                data: "",
                block_number: 0,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0xB064,
                log_index: 5
            })
        );
        hub.react(secondQueued);

        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 100);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_zeroDeltaSyncSystemDebtDoesNotAdvanceOrClearDeferredDebtContexts() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB06A, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB06B, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB06C, 3));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB06D, 4));
        entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.syncSystemDebt();
        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(recipient1), 100);
        assertEq(hub.recipientBalance(recipient2), 100);
        assertEq(system.debt(address(hub)), 0);

        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 100);

        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 100);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_lifecycleContextsQueueInOrderBeforeDebtIsObserved() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address recipient1 = makeAddr("lifecycleRecipient1");
        address recipient2 = makeAddr("lifecycleRecipient2");

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);

        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 100);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_lifecycleContextPrecedesDispatchBeforeDebtIsObserved() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address lifecycleRecipient = makeAddr("lifecycleRecipient");
        address dispatchRecipient = makeAddr("dispatchRecipient");

        hub.registerRecipient{value: 100}(dispatchRecipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, dispatchRecipient, 1, 0xB06E, 1));
        _consumeDebtContexts(hub, system, 2);

        hub.registerRecipient{value: 100}(lifecycleRecipient);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB06F, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(lifecycleRecipient), 96);
        assertEq(hub.recipientBalance(dispatchRecipient), 98);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(lifecycleRecipient), 96);
        assertEq(hub.recipientBalance(dispatchRecipient), 92);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_lifecycleContextSurvivesIgnoredAndDuplicateLogsBeforeDebtIsObserved() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("lifecycleRecipient1");
        address recipient2 = makeAddr("lifecycleRecipient2");
        IReactive.LogRecord memory firstQueued = _rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB070, 1);
        IReactive.LogRecord memory duplicateQueued = _rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB071, 2);

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        _consumeDebtContexts(hub, system, 2);
        hub.react(firstQueued);
        hub.react(duplicateQueued);

        hub.react(
            IReactive.LogRecord({
                chain_id: hub.protocolChainId(),
                _contract: hub.liquidityHub(),
                topic_0: 0xDEAD,
                topic_1: 0,
                topic_2: 0,
                topic_3: 0,
                data: "",
                block_number: 0,
                op_code: 0,
                block_hash: 0,
                tx_hash: 0xB072,
                log_index: 3
            })
        );
        hub.react(duplicateQueued);

        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(recipient1), 95);
        assertEq(hub.recipientBalance(recipient2), 99);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(recipient1), 95);
        assertEq(hub.recipientBalance(recipient2), 93);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_multipleDeferredDebtContextsAreChargedInFifoOrder() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        hub.registerRecipient{value: 100}(recipient1);
        hub.registerRecipient{value: 100}(recipient2);
        hub.registerRecipient{value: 100}(recipient3);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 1, 0xB064, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB065, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 1, 0xB066, 3));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 1, bytes32("mkt"), 0xB067, 4));
        entries = vm.getRecordedLogs();
        _assertDispatchedLength(entries, 1);

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient3, 1, 0xB068, 5));
        _setDebtAndSync(hub, system, 4);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 100);
        assertEq(hub.recipientBalance(recipient3), 100);

        _setDebtAndSync(hub, system, 6);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(hub.recipientBalance(recipient3), 100);

        _setDebtAndSync(hub, system, 3);

        assertEq(hub.recipientBalance(recipient1), 96);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(hub.recipientBalance(recipient3), 97);

        _setDebtAndSync(hub, system, 2);

        assertEq(hub.recipientBalance(recipient1), 94);
        assertEq(hub.recipientBalance(recipient2), 94);
        assertEq(hub.recipientBalance(recipient3), 97);
        assertEq(system.debt(address(hub)), 0);
    }

    function test_trackedInactiveRecipientReconciliationAllocatesDebt() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        bytes32 key = _computeKey(lcc, recipient);

        hub.registerRecipient{value: 10 ether}(recipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB060, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0xB062, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,,,, uint256[] memory attemptIds) = _decodeProcessSettlementsPayload(entries);

        _setDebtAndSync(hub, system, 15 ether);

        assertEq(hub.recipientBalance(recipient), -5 ether);
        assertFalse(hub.recipientActive(recipient));
        assertEq(hub.inFlightByKey(key), 50);

        hub.react(_rawSettlementSucceededLog(hub, lcc, recipient, 50, attemptIds[0], 0xB063, 3));
        _setDebtAndSync(hub, system, 7 ether);

        assertEq(hub.recipientBalance(recipient), -7 ether);
        assertFalse(hub.recipientActive(recipient));
        assertEq(system.debt(address(hub)), 7 ether);
    }

    function test_negativeBalanceBlocksNewIntakeAndDispatchButAllowsTrackedReconciliation() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc1 = makeAddr("lcc1");
        address lcc2 = makeAddr("lcc2");
        address lcc3 = makeAddr("lcc3");
        address recipient = makeAddr("recipient");
        bytes32 dispatchedKey = _computeKey(lcc1, recipient);
        bytes32 pausedKey = _computeKey(lcc2, recipient);

        hub.registerRecipient{value: 10 ether}(recipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc1, recipient, 50, 0xB051, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc2, recipient, 20, 0xB052, 2));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc1, 50, bytes32("mkt"), 0xB053, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();
        (,,,, uint256[] memory attemptIds) = _decodeProcessSettlementsPayload(entries);

        _setDebtAndSync(hub, system, 15 ether);
        assertEq(hub.recipientBalance(recipient), -5 ether);
        assertFalse(hub.recipientActive(recipient));

        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc3, recipient, 30, 0xB054, 4));
        assertFalse(_pendingExists(hub, lcc3, recipient));

        _assertNoProcessSettlementsDispatched(hub, lcc2, 20, bytes32("mkt"), 0xB055, 5);
        assertEq(hub.inFlightByKey(pausedKey), 0);

        hub.react(_rawSettlementSucceededLog(hub, lcc1, recipient, 50, attemptIds[0], 0xB056, 6));
        assertEq(hub.inFlightByKey(dispatchedKey), 0);
        hub.react(_rawSettlementProcessedLogWithRequested(hub, lcc1, recipient, 50, 50, 0xB057, 7));
        (, bool dispatchedExists) = hub.pendingStateByKey(dispatchedKey);
        assertFalse(dispatchedExists);

        hub.fundRecipient{value: 20 ether}(recipient);
        assertEq(hub.recipientBalance(recipient), 15 ether);
        assertTrue(hub.recipientActive(recipient));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc2, 20, bytes32("mkt"), 0xB058, 8));
        entries = vm.getRecordedLogs();

        _assertDispatchedLength(entries, 1);
        assertEq(hub.inFlightByKey(pausedKey), 20);
    }

    function test_contractDustCanPayVendorDebtWhileRecipientBalanceGoesNegative() public {
        (HubRSC hub, MockSystemContract system) = _deployHubWithDebtMock();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.registerRecipient{value: 1 ether}(recipient);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient, 50, 0xB061, 1));
        system.setDebt(address(hub), 5 ether);

        (bool success,) = payable(address(hub)).call{value: 4 ether}("");
        assertTrue(success);

        hub.syncSystemDebt();

        assertEq(hub.recipientBalance(recipient), -4 ether);
        assertFalse(hub.recipientActive(recipient));
        assertEq(system.debt(address(hub)), 0);
        assertEq(system.received(address(hub)), 5 ether);
    }

    function test_computeKeyExposesPendingKeyDerivation() public {
        HubRSC hub = _deployHub();
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        assertEq(hub.computeKey(lcc, recipient), _computeKey(lcc, recipient));
    }

    function test_selfContinuationIgnoresLegacyExternalContinuationOrigin() public {
        HubRSC hub = new HubRSC(1, originChainId, destinationChainId, liquidityHub, destinationReceiverContract);

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address legacyContinuationOrigin = makeAddr("legacyContinuationOrigin");

        hub.registerRecipient{value: 10 ether}(recipient1);
        hub.registerRecipient{value: 10 ether}(recipient2);
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient1, 10, 0xB071, 1));
        hub.react(_rawProtocolSettlementQueuedLog(hub, lcc, recipient2, 10, 0xB072, 2));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 20, bytes32("mkt"), 0xB073, 3));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        _assertDispatchedLength(firstEntries, 1);
        assertEq(_callbackCount(firstEntries), 1);
        (address emittedLcc, uint256 remaining) = _decodeMoreLiquidityAvailablePayload(firstEntries);
        assertEq(emittedLcc, lcc);
        assertEq(remaining, 10);

        IReactive.LogRecord memory legacyContinuation = _moreLiquidityAvailableLog(hub, lcc, remaining, 0xB074, 4);
        legacyContinuation._contract = legacyContinuationOrigin;

        vm.recordLogs();
        hub.react(legacyContinuation);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lcc, remaining, 0xB075, 5));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        _assertDispatchedLength(secondEntries, 1);
    }

    function _deployHub() private returns (HubRSC hub) {
        _clearSystemContract();
        hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract
        );
    }

    function _deployHubWithDebtMock() private returns (HubRSC hub, MockSystemContract system) {
        hub = _deployHub();
        _etchSystemContract();
        system = MockSystemContract(payable(SYSTEM_CONTRACT));
    }

    function _setDebtAndSync(HubRSC hub, MockSystemContract system, uint256 debt) private {
        system.setDebt(address(hub), debt);
        hub.syncSystemDebt();
    }

    function _consumeDebtContexts(HubRSC hub, MockSystemContract system, uint256 count) private {
        for (uint256 i = 0; i < count; i++) {
            _setDebtAndSync(hub, system, 1);
        }
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
}
