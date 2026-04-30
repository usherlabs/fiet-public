// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {MockLiquidityHub} from "../_mocks/MockLiquidityHub.sol";
import {HubRSCTestBase, MockSettlementReceiver, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

contract HubRSCDispatchBasicTest is HubRSCTestBase {
    /// @notice Dispatches a bounded batch when liquidity is available.
    function test_dispatchesBoundedBatchOnLiquidityAvailable() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient1, lcc, 10, 1, 1, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient2, lcc, 10, 2, 2, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient3, lcc, 10, 3, 3, 3));

        IReactive.LogRecord memory liqLog = IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(address(0), uint256(1000), bytes32("mkt")),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x9999,
            log_index: 11
        });

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liqLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (
            address dispatcher,
            address[] memory lccs,
            address[] memory recipients,
            uint256[] memory amounts,
            uint256[] memory attemptIds
        ) = _decodeProcessSettlementsPayload(entries);

        assertEq(dispatcher, address(0));
        assertTrue(lccs.length <= hub.maxDispatchItems());
        assertEq(lccs.length, recipients.length);
        assertEq(lccs.length, amounts.length);
        assertEq(lccs.length, attemptIds.length);

        assertEq(hub.inFlightByKey(_computeKey(lcc, recipient1)), 10);
        assertEq(hub.inFlightByKey(_computeKey(lcc, recipient2)), 10);
        assertEq(hub.inFlightByKey(_computeKey(lcc, recipient3)), 10);
    }

    /// @notice Multiple recipients on the same LCC are dispatched in FIFO queue order.
    function test_dispatchesRecipientsInFifoOrderForSameLcc() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient1, lcc, 11, 1, 0x7001, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient2, lcc, 22, 2, 0x7002, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient3, lcc, 33, 3, 0x7003, 3));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lcc, 10_000, bytes32("mkt"), 0x7004, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(entries);

        assertEq(lccs.length, 3);
        assertEq(recipients.length, 3);
        assertEq(amounts.length, 3);
        assertEq(recipients[0], recipient1);
        assertEq(recipients[1], recipient2);
        assertEq(recipients[2], recipient3);
        assertEq(lccs[0], lcc);
        assertEq(lccs[1], lcc);
        assertEq(lccs[2], lcc);
        assertEq(amounts[0], 11);
        assertEq(amounts[1], 22);
        assertEq(amounts[2], 33);
    }

    function test_noopWhenLiquidityAvailableHasZeroAmount() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        IReactive.LogRecord memory liqLog = IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(makeAddr("lcc"))),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(address(0), uint256(0), bytes32("mkt")),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x901,
            log_index: 1
        });

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liqLog);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_partialSettlementRequeuesRemainder() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lcc, 100, 1, 0xabc4, 1));

        IReactive.LogRecord memory liqLog = IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(address(0), uint256(40), bytes32("mkt")),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0x902,
            log_index: 1
        });

        _deliverReactiveVmLog(hub,liqLog);

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 100);
        assertEq(hub.inFlightByKey(key), 40);

        _deliverReactiveVmLog(hub,_settlementProcessedLog(hub, lcc, recipient, 40, 0x902, 2));
        (remaining, exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 60);
        assertEq(hub.inFlightByKey(key), 40);

        _deliverReactiveVmLog(hub,_settlementSucceededLog(hub, lcc, recipient, 40, 1, 0x902, 3));
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_emitsAndProcessesMoreLiquidityAfterMaxDispatchItems() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address lcc = makeAddr("lcc");
        uint256 extra = 5;
        uint256 totalEntries = hub.maxDispatchItems() + extra;

        for (uint256 i = 0; i < totalEntries; i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lcc, 1, i + 1, 0xA000 + i, i + 1));
        }
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lcc, totalEntries, bytes32("mkt"), 0xA100, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        _assertDispatchedLength(firstEntries, hub.maxDispatchItems());

        (address emittedLcc, uint256 emittedRemaining) = _decodeMoreLiquidityAvailablePayload(firstEntries);
        assertEq(emittedLcc, lcc);
        assertEq(emittedRemaining, extra);
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lcc, emittedRemaining, 0xA101, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        _assertDispatchedLength(secondEntries, extra);

        _applyProcessedLogsFromBatch(hub, firstEntries, 0xA200, 1);
        _applyProcessedLogsFromBatch(hub, secondEntries, 0xA300, 1);
        assertEq(hub.queueSize(), 0);
    }

    /// @notice End-to-end unit flow for HubRSC: settlement report -> liquidity available -> dispatch payload consumed by receiver.
    function test_endToEndSettlementToDisbursalViaMockReceiver() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));

        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address lcc = makeAddr("lcc");
        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");
        uint256 amountA1 = 25;
        uint256 amountA2 = 35;
        uint256 amountB = 40;
        uint256 totalA = amountA1 + amountA2;

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientA, lcc, amountA1, 1, 0x8001, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientA, lcc, amountA2, 2, 0x8002, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientB, lcc, amountB, 1, 0x8003, 3));
        assertTrue(_pendingExists(hub, lcc, recipientA));
        assertTrue(_pendingExists(hub, lcc, recipientB));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lcc, 1_000, bytes32("mkt"), 0x8004, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        _decodeAndProcess(hub, entries, receiver, 0x8005, 1);

        assertEq(receiver.calls(), 1);
        assertEq(liq.getTotalAmountSettled(lcc, recipientA), totalA);
        assertEq(liq.getTotalAmountSettled(lcc, recipientB), amountB);
    }

    /// @notice Single recipient/single LCC: settlement is queued first and processed once liquidity arrives later.
    function test_singleRecipientSingleLccQueuedThenProcessedWhenLiquidityArrives() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        uint256 amount = 75;

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lcc, amount, 1, 0x8101, 1));
        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(liq.getTotalAmountSettled(lcc, recipient), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lcc, 1_000, bytes32("mkt"), 0x8102, 2));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8103, 1);

        assertFalse(_pendingExists(hub, lcc, recipient));
        assertEq(liq.getTotalAmountSettled(lcc, recipient), amount);
    }

    function test_liquidityBudgetPersistsUntilLateQueueArrival() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lcc, underlying, 75, bytes32("mkt"), 0x8110, 1));
        assertEq(hub.availableBudgetByDispatchLane(underlying), 75);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lcc, 60, 1, 0x8111, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (
            address dispatcher,
            address[] memory lccs,
            address[] memory recipients,
            uint256[] memory amounts,
            uint256[] memory attemptIds
        ) = _decodeProcessSettlementsPayload(entries);
        assertEq(dispatcher, address(0));
        assertEq(lccs.length, 1);
        assertEq(lccs[0], lcc);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 60);
        assertEq(attemptIds[0], 1);
        assertEq(hub.availableBudgetByDispatchLane(underlying), 15);
    }

    /// @notice Multiple LCCs: liquidity event for one LCC dispatches only that LCC; others remain pending.
    function test_multiLccDispatchesOnlyTargetLccAndKeepsOthersPending() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientA1 = makeAddr("recipientA1");
        address recipientA2 = makeAddr("recipientA2");
        address recipientB = makeAddr("recipientB");

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientA1, lccA, 30, 1, 0x8201, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientA2, lccA, 20, 2, 0x8202, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientB, lccB, 40, 1, 0x8203, 3));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccA, 1_000, bytes32("mkt"), 0x8204, 4));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8206, 1);

        assertEq(liq.getTotalAmountSettled(lccA, recipientA1), 30);
        assertEq(liq.getTotalAmountSettled(lccA, recipientA2), 20);
        assertEq(liq.getTotalAmountSettled(lccB, recipientB), 0);
        assertTrue(_pendingExists(hub, lccB, recipientB));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccB, 1_000, bytes32("mkt"), 0x8205, 5));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8207, 1);

        assertEq(liq.getTotalAmountSettled(lccB, recipientB), 40);
        assertFalse(_pendingExists(hub, lccB, recipientB));
    }
}
