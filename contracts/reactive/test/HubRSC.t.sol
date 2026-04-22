// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {HubRSC} from "../src/HubRSC.sol";
import {MockLiquidityHub} from "./_mocks/MockLiquidityHub.sol";
import {ReactiveConstants} from "../src/libs/ReactiveConstants.sol";

uint256 constant DEFAULT_MAX_DISPATCH_ITEMS = 20;
uint256 constant RECEIVER_BATCH_SIZE_CAP = 30;

contract MockSystemContract {
    function subscribe(uint256, address, uint256, uint256, uint256, uint256) external {}
    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external {}
}

contract MockSettlementReceiver {
    MockLiquidityHub public immutable liquidityHub;
    uint256 public calls;

    constructor(address _liquidityHub) {
        liquidityHub = MockLiquidityHub(_liquidityHub);
    }

    function processSettlements(address, address[] memory lcc, address[] memory recipient, uint256[] memory maxAmount)
        external
    {
        calls += 1;
        for (uint256 i = 0; i < lcc.length; i++) {
            liquidityHub.processSettlementFor(lcc[i], recipient[i], maxAmount[i]);
        }
    }
}

contract HubRSCTest is Test {
    using stdStorage for StdStorage;

    address private constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 private constant SETTLEMENT_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_QUEUED_REPORTED_TOPIC;
    uint256 private constant LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.LIQUIDITY_AVAILABLE_TOPIC;
    uint256 private constant MORE_LIQUIDITY_AVAILABLE_TOPIC = ReactiveConstants.MORE_LIQUIDITY_AVAILABLE_TOPIC;
    uint256 private constant SETTLEMENT_ANNULLED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_ANNULLED_REPORTED_TOPIC;
    uint256 private constant SETTLEMENT_PROCESSED_REPORTED_TOPIC =
        ReactiveConstants.SETTLEMENT_PROCESSED_REPORTED_TOPIC;
    uint256 private constant SETTLEMENT_FAILED_REPORTED_TOPIC = ReactiveConstants.SETTLEMENT_FAILED_REPORTED_TOPIC;
    uint256 private constant LCC_CREATED_TOPIC = ReactiveConstants.LCC_CREATED_TOPIC;

    uint256 private originChainId;
    uint256 private destinationChainId;
    address private liquidityHub;
    address private hubCallback;
    address private destinationReceiverContract;

    function setUp() public {
        originChainId = 1;
        destinationChainId = 2;
        liquidityHub = makeAddr("liquidityHub");
        hubCallback = makeAddr("hubCallback");
        destinationReceiverContract = makeAddr("destinationReceiverContract");
    }

    function test_constructorRevertsOnInvalidConfig() public {
        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, 0, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract
        );

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, 0, liquidityHub, hubCallback, destinationReceiverContract);

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            address(0),
            hubCallback,
            destinationReceiverContract
        );

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            address(0),
            destinationReceiverContract
        );

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, hubCallback, address(0));

        vm.expectRevert(abi.encodeWithSelector(HubRSC.InvalidConfig.selector));
        new HubRSC(
            RECEIVER_BATCH_SIZE_CAP + 1,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );
    }

    function _etchSystemContract() internal {
        MockSystemContract mock = new MockSystemContract();
        vm.etch(SYSTEM_CONTRACT, address(mock).code);
    }

    function _clearSystemContract() internal {
        vm.etch(SYSTEM_CONTRACT, hex"");
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory) {
        require(data.length >= start);
        bytes memory result = new bytes(data.length - start);
        for (uint256 i = 0; i < result.length; i++) {
            result[i] = data[i + start];
        }
        return result;
    }

    /// @notice Aggregates pending settlements from a SettlementReported log.
    function test_aggregatesPendingFromSettlementReported() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        hub.react(_settlementLog(hub, recipient, lcc, amount, 1, 0x1234, 7));

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 storedAmount, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    /// @notice Ignores duplicate SettlementReported logs with the same tx/log identity.
    function test_ignoresDuplicateSettlementReportedLog() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        IReactive.LogRecord memory log = _settlementLog(hub, recipient, lcc, amount, 1, 0x4567, 9);

        hub.react(log);
        hub.react(log);

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 storedAmount, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    function test_ignoresZeroAmountSettlementReported() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        IReactive.LogRecord memory log = _settlementLog(hub, recipient, lcc, 0, 1, 0xabc1, 1);

        hub.react(log);

        // assertTrue(hub.processedReport(reportId));
        assertFalse(_pendingExists(hub, lcc, recipient));
    }

    function test_acceptsLowerNonceWhenLogIdentityIsNew() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 10, 2, 0xabc2, 1));
        hub.react(_settlementLog(hub, recipient, lcc, 10, 1, 0xabc3, 2));

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 amountAfter, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(amountAfter, 20);
    }

    /// @notice Dispatches a bounded batch when liquidity is available.
    function test_dispatchesBoundedBatchOnLiquidityAvailable() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        hub.react(_settlementLog(hub, recipient1, lcc, 10, 1, 1, 1));
        hub.react(_settlementLog(hub, recipient2, lcc, 10, 2, 2, 2));
        hub.react(_settlementLog(hub, recipient3, lcc, 10, 3, 3, 3));

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
        hub.react(liqLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);

        assertEq(dispatcher, address(0));
        assertTrue(lccs.length <= hub.maxDispatchItems());
        assertEq(lccs.length, recipients.length);
        assertEq(lccs.length, amounts.length);

        assertEq(hub.inFlightByKey(hub.computeKey(lcc, recipient1)), 10);
        assertEq(hub.inFlightByKey(hub.computeKey(lcc, recipient2)), 10);
        assertEq(hub.inFlightByKey(hub.computeKey(lcc, recipient3)), 10);
    }

    /// @notice Multiple recipients on the same LCC are dispatched in FIFO queue order.
    function test_dispatchesRecipientsInFifoOrderForSameLcc() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        hub.react(_settlementLog(hub, recipient1, lcc, 11, 1, 0x7001, 1));
        hub.react(_settlementLog(hub, recipient2, lcc, 22, 2, 0x7002, 2));
        hub.react(_settlementLog(hub, recipient3, lcc, 33, 3, 0x7003, 3));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 10_000, bytes32("mkt"), 0x7004, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);

        assertEq(lccs.length, 3);
        assertEq(recipients.length, 3);
        assertEq(amounts.length, 3);

        // FIFO expectation from queue insertion order.
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
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
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
        hub.react(liqLog);
        assertEq(_callbackCount(vm.getRecordedLogs()), 0);
    }

    function test_partialSettlementRequeuesRemainder() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0xabc4, 1));

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

        hub.react(liqLog);

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 100);
        assertEq(hub.inFlightByKey(key), 40);

        hub.react(_settlementProcessedLog(hub, lcc, recipient, 40, 0x902, 2));
        (,, remaining, exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 60);
        assertEq(hub.inFlightByKey(key), 40);

        hub.react(_settlementSucceededLog(hub, lcc, recipient, 40, 0x902, 3));
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_emitsAndProcessesMoreLiquidityAfterMaxDispatchItems() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address lcc = makeAddr("lcc");
        uint256 extra = 5;
        uint256 totalEntries = hub.maxDispatchItems() + extra;

        for (uint256 i = 0; i < totalEntries; i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementLog(hub, recipient, lcc, 1, i + 1, 0xA000 + i, i + 1));
        }
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, totalEntries, bytes32("mkt"), 0xA100, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        (, address[] memory firstLccs,,) = _decodeProcessSettlementsPayload(firstEntries);
        assertEq(firstLccs.length, hub.maxDispatchItems());

        bytes memory moreLiquidityPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR);
        assertTrue(moreLiquidityPayload.length > 0);

        (, address emittedLcc, uint256 emittedRemaining) =
            abi.decode(_slice(moreLiquidityPayload, 4), (address, address, uint256));
        assertEq(emittedLcc, lcc);
        assertEq(emittedRemaining, extra);
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lcc, emittedRemaining, 0xA101, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        (, address[] memory secondLccs,,) = _decodeProcessSettlementsPayload(secondEntries);
        assertEq(secondLccs.length, extra);

        _applyProcessedLogsFromBatch(hub, firstEntries, 0xA200, 1);
        _applyProcessedLogsFromBatch(hub, secondEntries, 0xA300, 1);
        assertEq(hub.queueSize(), 0);
    }

    /// @notice End-to-end unit flow for HubRSC: settlement report -> liquidity available -> dispatch payload consumed by receiver.
    function test_endToEndSettlementToDisbursalViaMockReceiver() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));

        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address lcc = makeAddr("lcc");
        address recipientA = makeAddr("recipientA");
        address recipientB = makeAddr("recipientB");
        uint256 amountA1 = 25;
        uint256 amountA2 = 35;
        uint256 amountB = 40;
        uint256 totalA = amountA1 + amountA2;

        // 1) Three settlement reports are recorded (two for same user, one for another).
        hub.react(_settlementLog(hub, recipientA, lcc, amountA1, 1, 0x8001, 1));
        hub.react(_settlementLog(hub, recipientA, lcc, amountA2, 2, 0x8002, 2));
        hub.react(_settlementLog(hub, recipientB, lcc, amountB, 1, 0x8003, 3));
        // validate on the reactive network, note that this method can only be called on the reactive network
        assertTrue(_pendingExists(hub, lcc, recipientA));
        assertTrue(_pendingExists(hub, lcc, recipientB));

        // 2) Liquidity available event with enough liquidity triggers callback dispatch.
        IReactive.LogRecord memory liqLog = liquidityAvailableLog(address(liq), lcc, 1_000, bytes32("mkt"), 0x8004, 4);

        vm.recordLogs();
        hub.react(liqLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        // 3) Decode callback payload and invoke mock receiver as destination-chain execution.
        _decodeAndProcess(hub, entries, receiver, 0x8005, 1);

        // 4) Assert both recipients were fully disbursed.
        assertEq(receiver.calls(), 1);
        assertEq(liq.getTotalAmountSettled(lcc, recipientA), totalA);
        assertEq(liq.getTotalAmountSettled(lcc, recipientB), amountB);
    }

    /// @notice Single recipient/single LCC: settlement is queued first and processed once liquidity arrives later.
    function test_singleRecipientSingleLccQueuedThenProcessedWhenLiquidityArrives() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");
        uint256 amount = 75;

        // Queue settlement first.
        hub.react(_settlementLog(hub, recipient, lcc, amount, 1, 0x8101, 1));
        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(liq.getTotalAmountSettled(lcc, recipient), 0);

        // Liquidity arrives later and triggers dispatch.
        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lcc, 1_000, bytes32("mkt"), 0x8102, 2));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8103, 1);

        assertFalse(_pendingExists(hub, lcc, recipient));
        assertEq(liq.getTotalAmountSettled(lcc, recipient), amount);
    }

    function test_liquidityBudgetPersistsUntilLateQueueArrival() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.react(liquidityAvailableLog(address(liq), lcc, underlying, 75, bytes32("mkt"), 0x8110, 1));
        assertEq(hub.availableBudgetByDispatchLane(underlying), 75);

        vm.recordLogs();
        hub.react(_settlementLog(hub, recipient, lcc, 60, 1, 0x8111, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(dispatcher, address(0));
        assertEq(lccs.length, 1);
        assertEq(lccs[0], lcc);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 60);
        assertEq(hub.availableBudgetByDispatchLane(underlying), 15);
    }

    /// @notice Multiple LCCs: liquidity event for one LCC dispatches only that LCC; others remain pending.
    function test_multiLccDispatchesOnlyTargetLccAndKeepsOthersPending() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientA1 = makeAddr("recipientA1");
        address recipientA2 = makeAddr("recipientA2");
        address recipientB = makeAddr("recipientB");

        hub.react(_settlementLog(hub, recipientA1, lccA, 30, 1, 0x8201, 1));
        hub.react(_settlementLog(hub, recipientA2, lccA, 20, 2, 0x8202, 2));
        hub.react(_settlementLog(hub, recipientB, lccB, 40, 1, 0x8203, 3));

        // Dispatch for lccA only.
        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lccA, 1_000, bytes32("mkt"), 0x8204, 4));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8206, 1);

        assertEq(liq.getTotalAmountSettled(lccA, recipientA1), 30);
        assertEq(liq.getTotalAmountSettled(lccA, recipientA2), 20);
        assertEq(liq.getTotalAmountSettled(lccB, recipientB), 0);
        assertTrue(_pendingExists(hub, lccB, recipientB));

        // Dispatch remaining pending lccB.
        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lccB, 1_000, bytes32("mkt"), 0x8205, 5));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8207, 1);

        assertEq(liq.getTotalAmountSettled(lccB, recipientB), 40);
        assertFalse(_pendingExists(hub, lccB, recipientB));
    }

    /// @notice Shared underlying: liquidity signalled for `lccA` can dispatch pending work for sibling `lccB`.
    function test_sharedUnderlyingLiquidityEventDispatchesSiblingLccQueues() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8300, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8301, 2));
        hub.react(_settlementLog(hub, recipientB, lccB, 40, 1, 0x8302, 3));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lccA, underlying, 1_000, bytes32("mktA"), 0x8303, 4));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8304, 1);

        assertEq(liq.getTotalAmountSettled(lccA, recipientB), 0);
        assertEq(liq.getTotalAmountSettled(lccB, recipientB), 40);
        assertFalse(_pendingExists(hub, lccB, recipientB));
    }

    function test_sharedUnderlyingBudgetWakesSiblingQueueAfterLiquidityArrivesFirst() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8310, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8311, 2));
        hub.react(liquidityAvailableLog(address(liq), lccA, underlying, 55, bytes32("mktA"), 0x8312, 3));
        assertEq(hub.availableBudgetByDispatchLane(underlying), 55);

        vm.recordLogs();
        hub.react(_settlementLog(hub, recipientB, lccB, 40, 1, 0x8313, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], recipientB);
        assertEq(amounts[0], 40);
        assertEq(hub.availableBudgetByDispatchLane(underlying), 15);
    }

    /// @notice Exact duplicate `LiquidityAvailable` delivery is ignored so it cannot reserve a second sibling key.
    function test_deduplicatesDuplicateSharedUnderlyingLiquidityAvailableLog() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        bytes32 key1 = hub.computeKey(lccB, recipient1);
        bytes32 key2 = hub.computeKey(lccB, recipient2);

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8310, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8311, 2));
        hub.react(_settlementLog(hub, recipient1, lccB, 10, 1, 0x8312, 3));
        hub.react(_settlementLog(hub, recipient2, lccB, 10, 2, 0x8313, 4));

        IReactive.LogRecord memory liquidityLog =
            liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 10, bytes32("mktA"), 0x8314, 5);
        bytes32 reportId = keccak256(
            abi.encode(liquidityLog.chain_id, liquidityLog._contract, liquidityLog.tx_hash, liquidityLog.log_index)
        );

        vm.recordLogs();
        hub.react(liquidityLog);
        hub.react(liquidityLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertTrue(hub.processedReport(reportId));
        assertEq(_callbackCount(entries), 1);
        assertEq(hub.inFlightByKey(key1), 10);
        assertEq(hub.inFlightByKey(key2), 0);
    }

    /// @notice `MoreLiquidityAvailable` stays on the shared-underlying lane when the initial `LiquidityAvailable` used it.
    function test_moreLiquidityAvailableContinuesSharedUnderlyingRoutingAfterBatchLimit() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        uint256 extra = 5;
        uint256 totalEntries = hub.maxDispatchItems() + extra;

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8400, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8401, 2));

        for (uint256 i = 0; i < totalEntries; i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementLog(hub, recipient, lccB, 1, i + 1, 0xA400 + i, i + 1));
        }
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, totalEntries, bytes32("mktA"), 0xA500, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        (, address[] memory firstLccs,,) = _decodeProcessSettlementsPayload(firstEntries);
        assertEq(firstLccs.length, hub.maxDispatchItems());
        for (uint256 i = 0; i < firstLccs.length; i++) {
            assertEq(firstLccs[i], lccB);
        }

        bytes memory moreLiquidityPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR);
        assertTrue(moreLiquidityPayload.length > 0);

        (, address emittedLcc, uint256 emittedRemaining) =
            abi.decode(_slice(moreLiquidityPayload, 4), (address, address, uint256));
        assertEq(emittedLcc, lccA);
        assertEq(emittedRemaining, extra);
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, emittedRemaining, 0xA501, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        (, address[] memory secondLccs,,) = _decodeProcessSettlementsPayload(secondEntries);
        assertEq(secondLccs.length, extra);
        for (uint256 i = 0; i < secondLccs.length; i++) {
            assertEq(secondLccs[i], lccB);
        }

        _applyProcessedLogsFromBatch(hub, firstEntries, 0xA600, 1);
        _applyProcessedLogsFromBatch(hub, secondEntries, 0xA700, 1);
        assertEq(hub.queueSize(), 0);
    }

    /// @notice Exact duplicate `MoreLiquidityAvailable` delivery is ignored so it cannot reserve another sibling key.
    function test_deduplicatesDuplicateMoreLiquidityAvailableLog() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            1,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        bytes32 key1 = hub.computeKey(lccB, recipient1);
        bytes32 key2 = hub.computeKey(lccB, recipient2);

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0xA510, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0xA511, 2));
        hub.react(_settlementLog(hub, recipient1, lccB, 10, 1, 0xA512, 3));
        hub.react(_settlementLog(hub, recipient2, lccB, 10, 2, 0xA513, 4));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 20, bytes32("mktA"), 0xA5131, 5));
        assertEq(hub.inFlightByKey(key1), 10);
        assertEq(hub.inFlightByKey(key2), 0);

        IReactive.LogRecord memory moreLiquidityLog = _moreLiquidityAvailableLog(hub, lccA, 10, 0xA514, 6);
        bytes32 reportId = keccak256(
            abi.encode(
                moreLiquidityLog.chain_id,
                moreLiquidityLog._contract,
                moreLiquidityLog.tx_hash,
                moreLiquidityLog.log_index
            )
        );

        vm.recordLogs();
        hub.react(moreLiquidityLog);
        hub.react(moreLiquidityLog);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertTrue(hub.processedReport(reportId));
        assertEq(_callbackCount(entries), 1);
        assertEq(hub.inFlightByKey(key1), 10);
        assertEq(hub.inFlightByKey(key2), 10);
    }

    /// @notice Without `LCCCreated` (or prior liquidity) for the indebted LCC, sibling liquidity does not pull its queue.
    function test_perLccFallbackWhenSiblingLccNeverRegistered() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        hub.react(_settlementLog(hub, recipientB, lccB, 40, 1, 0x8501, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lccA, underlying, 1_000, bytes32("mktA"), 0x8502, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory processPayload =
            _findCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        assertEq(processPayload.length, 0);
        assertTrue(_pendingExists(hub, lccB, recipientB));
    }

    /// @notice A trigger LCC registered with `underlying = address(0)` must not match an unregistered sibling by default-zero mapping.
    function test_zeroUnderlyingTriggerDoesNotMatchUnregisteredSiblingLcc() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address lccEth = makeAddr("lccEth");
        address lccUnregistered = makeAddr("lccUnregistered");
        address recipient = makeAddr("recipient");

        // Queue work for an LCC that has never been registered through `LCCCreated`.
        hub.react(_settlementLog(hub, recipient, lccUnregistered, 40, 1, 0x8511, 1));

        vm.recordLogs();
        // Emit liquidity for a different LCC whose underlying is the zero address (ETH-style lane).
        // This registers `lccEth -> address(0)`, but must not make the unregistered queue entry
        // look like a sibling just because uninitialized mappings also read back as `address(0)`.
        hub.react(liquidityAvailableLog(address(liq), lccEth, address(0), 1_000, bytes32("mktEth"), 0x8512, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory processPayload =
            _findCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        // No batch should be built: the queued entry LCC is still unregistered and should not match.
        assertEq(processPayload.length, 0);
        assertTrue(hub.hasUnderlyingForLcc(lccEth));
        assertEq(hub.underlyingByLcc(lccEth), address(0));
        assertFalse(hub.hasUnderlyingForLcc(lccUnregistered));
        // The original pending work must remain untouched.
        assertTrue(_pendingExists(hub, lccUnregistered, recipient));
    }

    /// @notice Reserved-only head windows still retry later unseen siblings, but a single remaining window consumes
    /// the only retry credit immediately.
    function test_zeroBatchSharedUnderlyingScanEmitsRetryThenDispatchesNextWindow() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8520, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8521, 2));

        // Fill the first shared-underlying scan window with fully reserved entries.
        for (uint256 i = 0; i < hub.maxDispatchItems(); i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementLog(hub, recipient, lccB, 1, i + 1, 0x8522 + i, i + 1));

            bytes32 key = hub.computeKey(lccB, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }

        // Leave one later sibling entry dispatchable so only the retry can reach it.
        address laterRecipient = address(uint160(hub.maxDispatchItems() + 1));
        hub.react(
            _settlementLog(hub, laterRecipient, lccB, 1, hub.maxDispatchItems() + 1, 0x8600, hub.maxDispatchItems() + 1)
        );

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8601, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        bytes memory firstProcessPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        assertEq(firstProcessPayload.length, 0);

        bytes memory firstMoreLiquidityPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR);
        assertTrue(firstMoreLiquidityPayload.length > 0);
        // The implementation now seeds credits only for windows that remain *after* the current scan.
        // Here there is exactly one unseen window, so emitting this retry also spends the only credit.
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 100, 0x8602, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(secondEntries);
        assertEq(dispatcher, address(0));
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], laterRecipient);
        assertEq(amounts[0], 1);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice Historical per-LCC backlog queued before `LCCCreated` is backfilled into the shared underlying lane.
    function test_backfillsPreRegistrationBacklogIntoSharedUnderlyingQueue() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        // Queue work for `lccB` before any underlying registration exists.
        hub.react(_settlementLog(hub, recipientB, lccB, 40, 1, 0x8525, 1));
        assertTrue(_pendingExists(hub, lccB, recipientB));

        // Register both sibling LCCs afterwards; `lccB` registration must backfill the historical key.
        // Without that backfill, sibling liquidity on `lccA` would switch to the shared lane and strand this
        // older per-LCC entry where the dispatcher can no longer see it.
        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8526, 2));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8527, 3));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lccA, underlying, 40, bytes32("mktA"), 0x8528, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(dispatcher, address(0));
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], recipientB);
        assertEq(amounts[0], 40);
    }

    /// @notice Large historical backlogs are mirrored into the shared underlying lane across bounded follow-up callbacks.
    function test_chunkedPreRegistrationBackfillContinuesAcrossLiquidityCallbacks() public {
        _clearSystemContract();

        uint256 boundedDispatchItems = 2;
        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            boundedDispatchItems, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address[5] memory recipients =
            [address(uint160(1)), address(uint160(2)), address(uint160(3)), address(uint160(4)), address(uint160(5))];

        hub.react(_settlementLog(hub, recipients[0], lccB, 1, 1, 0x8610, 1));
        hub.react(_settlementLog(hub, recipients[1], lccB, 1, 2, 0x8611, 2));
        hub.react(_settlementLog(hub, recipients[2], lccB, 1, 3, 0x8612, 3));
        hub.react(_settlementLog(hub, recipients[3], lccB, 1, 4, 0x8613, 4));
        hub.react(_settlementLog(hub, recipients[4], lccB, 1, 5, 0x8614, 5));

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8615, 6));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8616, 7));

        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 3);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lccA, underlying, 5, bytes32("mktA"), 0x8617, 8));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        bytes memory firstProcessPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        assertEq(firstProcessPayload.length, 0);
        assertTrue(
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR)
            .length > 0
        );
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 1);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 5, 0x8618, 9));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        {
            (
                address dispatcher,
                address[] memory secondLccs,
                address[] memory secondRecipients,
                uint256[] memory secondAmounts
            ) = _decodeProcessSettlementsPayload(secondEntries);
            assertEq(dispatcher, address(0));
            assertEq(secondLccs.length, 2);
            assertEq(secondRecipients.length, 2);
            assertEq(secondAmounts.length, 2);
            assertEq(secondLccs[0], lccB);
            assertEq(secondLccs[1], lccB);
            assertEq(secondRecipients[0], recipients[0]);
            assertEq(secondRecipients[1], recipients[1]);
            assertEq(secondAmounts[0], 1);
            assertEq(secondAmounts[1], 1);
        }
        assertTrue(
            _findCallbackPayloadBySelector(secondEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR)
            .length > 0
        );
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 3, 0x8619, 10));
        Vm.Log[] memory thirdEntries = vm.getRecordedLogs();

        {
            (, address[] memory thirdLccs, address[] memory thirdRecipients, uint256[] memory thirdAmounts) =
                _decodeProcessSettlementsPayload(thirdEntries);
            assertEq(thirdLccs.length, 2);
            assertEq(thirdRecipients.length, 2);
            assertEq(thirdAmounts.length, 2);
            assertEq(thirdLccs[0], lccB);
            assertEq(thirdLccs[1], lccB);
            assertEq(thirdRecipients[0], recipients[2]);
            assertEq(thirdRecipients[1], recipients[3]);
            assertEq(thirdAmounts[0], 1);
            assertEq(thirdAmounts[1], 1);
        }
        assertTrue(
            _findCallbackPayloadBySelector(thirdEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR)
            .length > 0
        );

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 1, 0x8620, 11));
        Vm.Log[] memory fourthEntries = vm.getRecordedLogs();

        {
            (, address[] memory fourthLccs, address[] memory fourthRecipients, uint256[] memory fourthAmounts) =
                _decodeProcessSettlementsPayload(fourthEntries);
            assertEq(fourthLccs.length, 1);
            assertEq(fourthRecipients.length, 1);
            assertEq(fourthAmounts.length, 1);
            assertEq(fourthLccs[0], lccB);
            assertEq(fourthRecipients[0], recipients[4]);
            assertEq(fourthAmounts[0], 1);
        }

        _applyProcessedLogsFromBatch(hub, secondEntries, 0x8718, 9);
        _applyProcessedLogsFromBatch(hub, thirdEntries, 0x8819, 10);
        _applyProcessedLogsFromBatch(hub, fourthEntries, 0x8920, 11);
        assertEq(hub.queueSize(), 0);
    }

    /// @notice A reserved prefix longer than one scan window still reaches a trailing dispatchable entry after multiple retries.
    function test_zeroBatchSharedUnderlyingLongReservedPrefixDispatchesAfterMultipleRetries() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x9500, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x9501, 2));

        uint256 m = hub.maxDispatchItems();
        // Reserve 2*m + 1 keys in front of the dispatchable tail.
        for (uint256 i = 0; i < 2 * m + 1; i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementLog(hub, recipient, lccB, 1, i + 1, 0x9510 + i, i + 1));

            bytes32 key = hub.computeKey(lccB, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }

        address laterRecipient = address(uint160(2 * m + 2));
        hub.react(_settlementLog(hub, laterRecipient, lccB, 1, 2 * m + 2, 0x9600, 2 * m + 2));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8601, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();
        assertEq(_findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        assertTrue(
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR)
            .length > 0
        );

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 100, 0x8602, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();
        assertEq(
            _findCallbackPayloadBySelector(secondEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0
        );
        assertTrue(
            _findCallbackPayloadBySelector(secondEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR)
            .length > 0
        );

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 100, 0x8603, 3));
        Vm.Log[] memory thirdEntries = vm.getRecordedLogs();

        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(thirdEntries);
        assertEq(dispatcher, address(0));
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], laterRecipient);
        assertEq(amounts[0], 1);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice A fully scanned reserved window emits no retry, and a manual follow-up still cannot re-seed credits.
    function test_zeroBatchRetryCreditsDoNotReseedOnFollowupWhenAllReserved() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x9700, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x9701, 2));

        // Exactly one scan window of fully reserved entries => one retry credit chain only.
        _queueReservedEntries(hub, lccB, 0, 0x9710, 1);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x9720, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();
        assertEq(_findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        // A single full reserved window leaves no unseen windows behind the current scan, so the initial
        // LiquidityAvailable path must not manufacture a speculative retry callback.
        assertEq(
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR)
            .length,
            0
        );
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 100, 0x9721, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();
        // Follow-up callbacks run with `bootstrapZeroBatchRetry == false`, so once credits are exhausted a
        // later replay cannot re-seed them and restart the retry chain.
        assertEq(_callbackCount(secondEntries), 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice A stale shared-underlying retry credit is cleared if the follow-up callback later falls back to per-LCC routing.
    function test_clearsStaleSharedRetryFlagWhenFollowupFallsBackToPerLcc() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8610, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8611, 2));

        uint256 m = hub.maxDispatchItems();
        // First pass: a long shared-underlying reserved prefix leaves one stale credit on the underlying lane.
        for (uint256 i = 0; i < 2 * m + 1; i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementLog(hub, recipient, lccB, 1, i + 1, 0x8612 + i, i + 1));

            bytes32 key = hub.computeKey(lccB, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8620, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        bytes memory firstMoreLiquidityPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR);
        assertTrue(firstMoreLiquidityPayload.length > 0);
        // `2 * maxDispatchItems + 1` reserved entries leave one additional unseen reserved window after the
        // first scan, so the shared-underlying lane should retain one stale credit until routing changes.
        assertGt(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        // Drain the shared queue before the follow-up callback arrives, forcing the replay to route per-LCC.
        for (uint256 i = 0; i < 2 * m + 1; i++) {
            address recipient = address(uint160(i + 1));
            hub.react(_settlementProcessedLogWithRequested(hub, lccB, recipient, 1, 1, 0x8630 + i, i + 1));
        }
        assertEq(hub.queueSize(), 0);
        assertGt(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        hub.react(_moreLiquidityAvailableLog(hub, lccA, 100, 0x8640, 1));
        Vm.Log[] memory fallbackEntries = vm.getRecordedLogs();
        // The shared queue is now empty, so routing falls back to the per-LCC lane; that transition must clear
        // the stale shared-lane credit or a future shared retry could be incorrectly suppressed.
        assertEq(_callbackCount(fallbackEntries), 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        // A later shared-underlying zero-batch should still be able to emit a fresh retry.
        _queueReservedEntries(hub, lccB, 100, 0x8650, 101);
        address laterRecipient = address(uint160(m + 101));
        hub.react(_settlementLog(hub, laterRecipient, lccB, 1, m + 101, 0x8661, m + 101));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8660, 1));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        bytes memory secondMoreLiquidityPayload =
            _findCallbackPayloadBySelector(secondEntries, ReactiveConstants.TRIGGER_MORE_LIQUIDITY_AVAILABLE_SELECTOR);
        // After the fallback cleared the stale shared credit, a brand new shared-lane zero-batch should be free
        // to emit its own retry again.
        assertTrue(secondMoreLiquidityPayload.length > 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice Partial processed release on shared-underlying dispatch prunes in-flight the same as the per-LCC lane.
    function test_sharedUnderlyingPartialInFlightReleaseMatchesPerLccSemantics() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipient = makeAddr("recipient");
        bytes32 key = hub.computeKey(lccB, recipient);

        hub.react(_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8600, 1));
        hub.react(_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8601, 2));
        hub.react(_settlementLog(hub, recipient, lccB, 100, 1, 0x8602, 3));

        hub.react(liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8603, 4));
        assertEq(hub.inFlightByKey(key), 100);

        hub.react(_settlementProcessedLogWithRequested(hub, lccB, recipient, 60, 100, 0x8604, 5));
        hub.react(_settlementSucceededLog(hub, lccB, recipient, 100, 0x8605, 6));

        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 40);
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_reconcilesPendingFromSettlementAnnulled() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 70, 1, 0x9001, 1));
        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 30, 0x9002, 1));

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 40);
    }

    function test_releasesInFlightOnSettlementFailedAndKeepsPendingRetryable() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9101, 1));

        vm.recordLogs();
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9102, 2));
        Vm.Log[] memory firstDispatch = vm.getRecordedLogs();
        (, address[] memory lccs,, uint256[] memory amounts) = _decodeProcessSettlementsPayload(firstDispatch);
        assertEq(lccs.length, 1);
        assertEq(amounts[0], 100);
        assertEq(hub.inFlightByKey(hub.computeKey(lcc, recipient)), 100);

        vm.recordLogs();
        hub.react(_settlementFailedLog(hub, lcc, recipient, 100, hex"deadc0de", 0x9103, 1));
        Vm.Log[] memory retryEntries = vm.getRecordedLogs();
        assertTrue(_pendingExists(hub, lcc, recipient));
        assertEq(hub.inFlightByKey(hub.computeKey(lcc, recipient)), 100);

        (, lccs,, amounts) = _decodeProcessSettlementsPayload(retryEntries);
        assertEq(lccs.length, 1);
        assertEq(amounts[0], 100);
    }

    function test_manualSettlementProcessedLogReconcilesWithoutDispatch() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        hub.react(_settlementLog(hub, recipient, lcc, 90, 1, 0x9201, 1));
        hub.react(_settlementProcessedLog(hub, lcc, recipient, 40, 0x9202, 1));

        bytes32 key = hub.computeKey(lcc, recipient);
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 50);
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_buffersOutOfOrderProcessedAndAppliesOnQueued() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        // Processed arrives first (out-of-order): should buffer, not drop.
        hub.react(_settlementProcessedLog(hub, lcc, recipient, 30, 0x9301, 1));
        (uint256 bufferedSettled, uint256 bufferedInFlight) = hub.bufferedProcessedDecreaseByKey(key);
        assertEq(bufferedSettled, 30);
        assertEq(bufferedInFlight, 0);
        assertFalse(_pendingExists(hub, lcc, recipient));

        // Settlement queue report arrives later: buffered decrease should be applied immediately.
        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9302, 2));
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 20);
        (bufferedSettled, bufferedInFlight) = hub.bufferedProcessedDecreaseByKey(key);
        assertEq(bufferedSettled, 0);
        assertEq(bufferedInFlight, 0);
    }

    function test_buffersOutOfOrderAnnulledAndAppliesOnQueued() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        // Annulled arrives first (out-of-order): should buffer, not drop.
        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 20, 0x9401, 1));
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 20);
        assertFalse(_pendingExists(hub, lcc, recipient));

        // Settlement queue report arrives later: buffered decrease should be applied immediately.
        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9402, 2));
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 30);
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 0);
    }

    /// @dev Annulled can arrive before multiple SettlementQueued deltas; excess must not be discarded at first apply.
    function test_buffersAnnulledLargerThanFirstQueued_carriesRemainderAcrossLaterQueueAdds() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        hub.react(_settlementAnnulledLog(hub, lcc, recipient, 120, 0x9411, 1));
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 120);
        assertFalse(_pendingExists(hub, lcc, recipient));

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9412, 2));
        (,, uint256 remaining, bool exists) = hub.pending(key);
        // Fully netted against the first queue increment; entry pruned while remainder stays buffered.
        assertFalse(exists);
        assertEq(remaining, 0);
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 20);

        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9413, 3));
        (,, remaining, exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 30);
        assertEq(hub.bufferedAnnulledDecreaseByKey(key), 0);
    }

    /// @dev Processed-before-queue can exceed the first mirrored queue increment; settled remainder must carry forward.
    function test_buffersProcessedLargerThanFirstQueued_carriesSettledRemainder() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 80, 80, 0x9421, 1));
        (uint256 bufSettled, uint256 bufInflight) = hub.bufferedProcessedDecreaseByKey(key);
        assertEq(bufSettled, 80);
        assertEq(bufInflight, 0);
        assertFalse(_pendingExists(hub, lcc, recipient));

        hub.react(_settlementLog(hub, recipient, lcc, 50, 1, 0x9422, 2));
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertFalse(exists);
        assertEq(remaining, 0);
        (bufSettled, bufInflight) = hub.bufferedProcessedDecreaseByKey(key);
        assertEq(bufSettled, 30);
        assertEq(bufInflight, 0);

        hub.react(_settlementLog(hub, recipient, lcc, 40, 1, 0x9423, 3));
        (,, remaining, exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 10);
        (bufSettled, bufInflight) = hub.bufferedProcessedDecreaseByKey(key);
        assertEq(bufSettled, 0);
        assertEq(bufInflight, 0);
    }

    /// @dev Permissionless requestedAmount no longer releases reservations or buffers synthetic in-flight reductions.
    function test_processedRequestedAmountNoLongerReleasesReservation() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 200, 1, 0x9711, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9712, 2));
        assertEq(hub.inFlightByKey(key), 100);

        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 150, 150, 0x9713, 3));
        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 50);
        assertEq(hub.inFlightByKey(key), 50);
        (uint256 bufSettled, uint256 bufInflight) = hub.bufferedProcessedDecreaseByKey(key);
        assertEq(bufSettled, 0);
        assertEq(bufInflight, 0);

        hub.react(_settlementSucceededLog(hub, lcc, recipient, 150, 0x9714, 4));
        assertEq(hub.inFlightByKey(key), 0);

        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 50, bytes32("mkt"), 0x9715, 5));
        assertEq(hub.inFlightByKey(key), 50);
        (,, remaining, exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 50);

        hub.react(_settlementLog(hub, recipient, lcc, 10, 1, 0x9716, 6));
        assertEq(hub.inFlightByKey(key), 50);
        (,, remaining, exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 60);
    }

    function test_deduplicatesAuthoritativeProcessedByLogIdentity() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 80, 1, 0x9501, 1));

        IReactive.LogRecord memory processedLog = _settlementProcessedLog(hub, lcc, recipient, 30, 0x9502, 2);
        bytes32 authoritativeReportId = keccak256(
            abi.encode(processedLog.chain_id, processedLog._contract, processedLog.tx_hash, processedLog.log_index)
        );

        hub.react(processedLog);
        hub.react(processedLog); // exact duplicate delivery

        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 50); // applied once only
        assertTrue(hub.processedReport(authoritativeReportId));
    }

    function test_releasesUnusedInFlightReservationOnTrustedSuccess() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9601, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9602, 2));
        assertEq(hub.inFlightByKey(key), 100);

        // Destination succeeded but settled only part of requested amount.
        hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 60, 100, 0x9603, 3));
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 100, 0x9604, 4));

        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 40);
        assertEq(hub.inFlightByKey(key), 0);
    }

    function test_releasesInFlightWhenTrustedSuccessSettlesZero() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        bytes32 key = hub.computeKey(lcc, recipient);

        hub.react(_settlementLog(hub, recipient, lcc, 100, 1, 0x9611, 1));
        hub.react(liquidityAvailableLog(hub.liquidityHub(), lcc, 100, bytes32("mkt"), 0x9612, 2));
        assertEq(hub.inFlightByKey(key), 100);

        // Attempt completed with zero settlement, but the trusted success path still releases reservation.
        hub.react(_settlementSucceededLog(hub, lcc, recipient, 100, 0x9613, 3));

        (,, uint256 remaining, bool exists) = hub.pending(key);
        assertTrue(exists);
        assertEq(remaining, 100);
        assertEq(hub.inFlightByKey(key), 0);
    }

    function _settlementLog(
        HubRSC hub,
        address recipient,
        address lcc,
        uint256 amount,
        uint256 nonce,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount, nonce),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    /// @dev When `underlyingAsset` is `address(0)`, matches legacy tests that omit explicit underlying in the log data.
    function liquidityAvailableLog(
        address sourceContract,
        address lcc,
        address underlyingAsset,
        uint256 available,
        bytes32 marketId,
        uint256 txHash,
        uint256 logIndex
    ) internal pure returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: 1,
            _contract: sourceContract,
            topic_0: LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(underlyingAsset, available, marketId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function liquidityAvailableLog(
        address sourceContract,
        address lcc,
        uint256 available,
        bytes32 marketId,
        uint256 txHash,
        uint256 logIndex
    ) internal pure returns (IReactive.LogRecord memory) {
        return liquidityAvailableLog(sourceContract, lcc, address(0), available, marketId, txHash, logIndex);
    }

    function _lccCreatedLog(
        HubRSC hub,
        address underlying,
        address lcc,
        bytes32 marketId,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.protocolChainId(),
            _contract: hub.liquidityHub(),
            topic_0: LCC_CREATED_TOPIC,
            topic_1: uint256(uint160(underlying)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(marketId),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _moreLiquidityAvailableLog(HubRSC hub, address lcc, uint256 available, uint256 txHash, uint256 logIndex)
        internal
        view
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: MORE_LIQUIDITY_AVAILABLE_TOPIC,
            topic_1: uint256(uint160(lcc)),
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(available),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementProcessedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_PROCESSED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount, amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementProcessedLogWithRequested(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 settledAmount,
        uint256 requestedAmount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_PROCESSED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(settledAmount, requestedAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementAnnulledLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 amount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_ANNULLED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(amount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementSucceededLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: ReactiveConstants.SETTLEMENT_SUCCEEDED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(maxAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _settlementFailedLog(
        HubRSC hub,
        address lcc,
        address recipient,
        uint256 maxAmount,
        bytes memory reason,
        uint256 txHash,
        uint256 logIndex
    ) internal view returns (IReactive.LogRecord memory) {
        reason;
        return IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.hubCallback(),
            topic_0: SETTLEMENT_FAILED_REPORTED_TOPIC,
            topic_1: uint256(uint160(recipient)),
            topic_2: uint256(uint160(lcc)),
            topic_3: 0,
            data: abi.encode(maxAmount),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: txHash,
            log_index: logIndex
        });
    }

    function _pendingExists(HubRSC hub, address lcc, address recipient) internal view returns (bool exists) {
        (,,, exists) = hub.pending(hub.computeKey(lcc, recipient));
    }

    function _decodeAndProcess(
        HubRSC hub,
        Vm.Log[] memory entries,
        MockSettlementReceiver receiver,
        uint256 txHashBase,
        uint256 logIndexBase
    ) internal {
        (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayload(entries);
        receiver.processSettlements(dispatcher, lccs, recipients, amounts);
        for (uint256 i = 0; i < lccs.length; i++) {
            hub.react(
                _settlementProcessedLog(hub, lccs[i], recipients[i], amounts[i], txHashBase + i, logIndexBase + i)
            );
            hub.react(
                _settlementSucceededLog(
                    hub, lccs[i], recipients[i], amounts[i], txHashBase + 1000 + i, logIndexBase + i
                )
            );
        }
    }

    function _applyProcessedLogsFromBatch(
        HubRSC hub,
        Vm.Log[] memory entries,
        uint256 txHashBase,
        uint256 logIndexBase
    ) internal {
        _applyProcessedLogsFromBatchAt(hub, entries, 0, txHashBase, logIndexBase);
    }

    function _applyProcessedLogsFromBatchAt(
        HubRSC hub,
        Vm.Log[] memory entries,
        uint256 ordinal,
        uint256 txHashBase,
        uint256 logIndexBase
    ) internal {
        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts) =
            _decodeProcessSettlementsPayloadAt(entries, ordinal);
        for (uint256 i = 0; i < lccs.length; i++) {
            hub.react(
                _settlementProcessedLog(hub, lccs[i], recipients[i], amounts[i], txHashBase + i, logIndexBase + i)
            );
            hub.react(
                _settlementSucceededLog(
                    hub, lccs[i], recipients[i], amounts[i], txHashBase + 1000 + i, logIndexBase + i
                )
            );
        }
    }

    function _queueReservedEntries(
        HubRSC hub,
        address lcc,
        uint256 recipientOffset,
        uint256 txHashBase,
        uint256 nonceBase
    ) internal {
        for (uint256 i = 0; i < hub.maxDispatchItems(); i++) {
            address recipient = address(uint160(recipientOffset + i + 1));
            hub.react(_settlementLog(hub, recipient, lcc, 1, nonceBase + i, txHashBase + i, i + 1));

            bytes32 key = hub.computeKey(lcc, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }
    }

    function _drainQueuedEntries(HubRSC hub, address lcc, uint256 recipientOffset, uint256 txHashBase) internal {
        for (uint256 i = 0; i < hub.maxDispatchItems(); i++) {
            address recipient = address(uint160(recipientOffset + i + 1));
            hub.react(_settlementProcessedLogWithRequested(hub, lcc, recipient, 1, 1, txHashBase + i, i + 1));
        }
    }

    function _decodeProcessSettlementsPayload(Vm.Log[] memory entries)
        internal
        pure
        returns (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts)
    {
        return _decodeProcessSettlementsPayloadAt(entries, 0);
    }

    function _decodeProcessSettlementsPayloadAt(Vm.Log[] memory entries, uint256 ordinal)
        internal
        pure
        returns (address dispatcher, address[] memory lccs, address[] memory recipients, uint256[] memory amounts)
    {
        bytes memory rawPayload =
            _findNthCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR, ordinal);
        require(rawPayload.length > 0, "missing processSettlements callback payload");
        bytes memory args = _slice(rawPayload, 4);
        return abi.decode(args, (address, address[], address[], uint256[]));
    }

    function _findCallbackPayloadBySelector(Vm.Log[] memory entries, bytes4 selector)
        internal
        pure
        returns (bytes memory)
    {
        return _findNthCallbackPayloadBySelector(entries, selector, 0);
    }

    function _findNthCallbackPayloadBySelector(Vm.Log[] memory entries, bytes4 selector, uint256 ordinal)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackSig) {
                bytes memory candidate = abi.decode(entries[i].data, (bytes));
                if (_startsWithSelector(candidate, selector)) {
                    if (ordinal > 0) {
                        ordinal--;
                        continue;
                    }
                    return candidate;
                }
            }
        }
        return bytes("");
    }

    function _startsWithSelector(bytes memory payload, bytes4 selector) internal pure returns (bool) {
        if (payload.length < 4) return false;
        bytes4 found;
        assembly {
            found := mload(add(payload, 0x20))
        }
        return found == selector;
    }

    function _callbackCount(Vm.Log[] memory entries) internal pure returns (uint256 count) {
        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length > 0 && entries[i].topics[0] == callbackSig) {
                count++;
            }
        }
    }
}
