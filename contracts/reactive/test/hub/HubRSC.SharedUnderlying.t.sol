// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {ReactiveConstants} from "../../src/libs/ReactiveConstants.sol";
import {MockLiquidityHub} from "../_mocks/MockLiquidityHub.sol";
import {HubRSCTestBase, MockSettlementReceiver, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

contract HubRSCSharedUnderlyingTest is HubRSCTestBase {
    /// @notice Shared underlying: liquidity signalled for `lccA` can dispatch pending work for sibling `lccB`.
    function test_sharedUnderlyingLiquidityEventDispatchesSiblingLccQueues() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8300, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8301, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientB, lccB, 40, 1, 0x8302, 3));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccA, underlying, 1_000, bytes32("mktA"), 0x8303, 4));
        _decodeAndProcess(hub, vm.getRecordedLogs(), receiver, 0x8304, 1);

        assertEq(liq.getTotalAmountSettled(lccA, recipientB), 0);
        assertEq(liq.getTotalAmountSettled(lccB, recipientB), 40);
        assertFalse(_pendingExists(hub, lccB, recipientB));
    }

    function test_sharedUnderlyingBudgetWakesSiblingQueueAfterLiquidityArrivesFirst() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8310, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8311, 2));
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccA, underlying, 55, bytes32("mktA"), 0x8312, 3));
        assertEq(hub.availableBudgetByDispatchLane(underlying), 55);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientB, lccB, 40, 1, 0x8313, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
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
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        bytes32 key1 = _computeKey(lccB, recipient1);
        bytes32 key2 = _computeKey(lccB, recipient2);

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8310, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8311, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient1, lccB, 10, 1, 0x8312, 3));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient2, lccB, 10, 2, 0x8313, 4));

        IReactive.LogRecord memory liquidityLog =
            liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 10, bytes32("mktA"), 0x8314, 5);
        bytes32 reportId = keccak256(
            abi.encode(liquidityLog.chain_id, liquidityLog._contract, liquidityLog.tx_hash, liquidityLog.log_index)
        );

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityLog);
        _deliverReactiveVmLog(hub,liquidityLog);
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
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        uint256 extra = 5;
        uint256 totalEntries = hub.maxDispatchItems() + extra;

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8400, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8401, 2));

        for (uint256 i = 0; i < totalEntries; i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccB, 1, i + 1, 0xA400 + i, i + 1));
        }
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, totalEntries, bytes32("mktA"), 0xA500, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        _assertDispatchedLccs(firstEntries, lccB, hub.maxDispatchItems());

        (address emittedLcc, uint256 emittedRemaining) = _decodeMoreLiquidityAvailablePayload(firstEntries);
        assertEq(emittedLcc, lccA);
        assertEq(emittedRemaining, extra);
        assertEq(hub.queueSize(), totalEntries);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, emittedRemaining, 0xA501, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        _assertDispatchedLccs(secondEntries, lccB, extra);

        _applyProcessedLogsFromBatch(hub, firstEntries, 0xA600, 1);
        _applyProcessedLogsFromBatch(hub, secondEntries, 0xA700, 1);
        assertEq(hub.queueSize(), 0);
    }

    /// @notice Exact duplicate `MoreLiquidityAvailable` delivery is ignored so it cannot reserve another sibling key.
    function test_deduplicatesDuplicateMoreLiquidityAvailableLog() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(1, originChainId, destinationChainId, liquidityHub, destinationReceiverContract, REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        bytes32 key1 = _computeKey(lccB, recipient1);
        bytes32 key2 = _computeKey(lccB, recipient2);

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0xA510, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0xA511, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient1, lccB, 10, 1, 0xA512, 3));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient2, lccB, 10, 2, 0xA513, 4));
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 20, bytes32("mktA"), 0xA5131, 5));
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
        _deliverReactiveVmLog(hub,moreLiquidityLog);
        _deliverReactiveVmLog(hub,moreLiquidityLog);
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
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipientB, lccB, 40, 1, 0x8501, 1));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccA, underlying, 1_000, bytes32("mktA"), 0x8502, 2));
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
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address lccEth = makeAddr("lccEth");
        address lccUnregistered = makeAddr("lccUnregistered");
        address recipient = makeAddr("recipient");

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccUnregistered, 40, 1, 0x8511, 1));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccEth, address(0), 1_000, bytes32("mktEth"), 0x8512, 2));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes memory processPayload =
            _findCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        assertEq(processPayload.length, 0);
        assertTrue(hub.hasUnderlyingForLcc(lccEth));
        assertEq(hub.underlyingByLcc(lccEth), address(0));
        assertFalse(hub.hasUnderlyingForLcc(lccUnregistered));
        assertTrue(_pendingExists(hub, lccUnregistered, recipient));
    }

    /// @notice Historical per-LCC backlog queued before `LCCCreated` is backfilled into the shared underlying lane.
    function test_backfillsPreRegistrationBacklogIntoSharedUnderlyingQueue() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipientB = makeAddr("recipientB");

        _deliverReactiveVmLog(hub,_protocolSettlementQueuedLog(hub, lccB, recipientB, 40, 0x8525, 1));
        assertTrue(_pendingExists(hub, lccB, recipientB));

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8526, 2));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8527, 3));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccA, underlying, 40, bytes32("mktA"), 0x8528, 4));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], recipientB);
        assertEq(amounts[0], 40);
    }

    /// @notice Shared-underlying backfill spends the bounded wake-up budget across LCCs instead of finishing every sibling in one pass.
    function test_underlyingBackfillContinuationStaysBoundedAcrossSiblingLccs() public {
        _clearSystemContract();

        HubRSC hub = new HubRSC(1, originChainId, destinationChainId, liquidityHub, destinationReceiverContract, REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address lccC = makeAddr("lccC");
        address lccD = makeAddr("lccD");

        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(101)), lccB, 1, 1, 0x8600, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(102)), lccB, 1, 2, 0x8601, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(201)), lccC, 1, 3, 0x8602, 3));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(202)), lccC, 1, 4, 0x8603, 4));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(301)), lccD, 1, 5, 0x8604, 5));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(302)), lccD, 1, 6, 0x8605, 6));

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8606, 7));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8607, 8));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccC, bytes32("mktC"), 0x8608, 9));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccD, bytes32("mktD"), 0x8609, 10));

        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 1);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccC), 1);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccD), 1);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 3, bytes32("mktA"), 0x8610, 11));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(_findCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        assertTrue(_moreLiquidityAvailableEventCount(entries) > 0);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 0);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccC), 1);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccD), 1);
    }

    /// @notice Large historical backlogs are mirrored into the shared underlying lane across bounded follow-up callbacks.
    function test_chunkedPreRegistrationBackfillContinuesAcrossLiquidityCallbacks() public {
        _clearSystemContract();

        uint256 boundedDispatchItems = 2;
        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub =
            new HubRSC(boundedDispatchItems, originChainId, destinationChainId, address(liq), address(receiver), REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address[5] memory recipients =
            [address(uint160(1)), address(uint160(2)), address(uint160(3)), address(uint160(4)), address(uint160(5))];

        _deliverReactiveVmLog(hub,_settlementLog(hub, recipients[0], lccB, 1, 1, 0x8610, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipients[1], lccB, 1, 2, 0x8611, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipients[2], lccB, 1, 3, 0x8612, 3));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipients[3], lccB, 1, 4, 0x8613, 4));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipients[4], lccB, 1, 5, 0x8614, 5));

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8615, 6));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8616, 7));

        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 3);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(address(liq), lccA, underlying, 5, bytes32("mktA"), 0x8617, 8));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        bytes memory firstProcessPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        assertEq(firstProcessPayload.length, 0);
        assertTrue(_moreLiquidityAvailableEventCount(firstEntries) > 0);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 1);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 5, 0x8618, 9));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        {
            (
                address dispatcher,
                address[] memory secondLccs,
                address[] memory secondRecipients,
                uint256[] memory secondAmounts,
                uint256[] memory secondAttemptIds
            ) = _decodeProcessSettlementsPayload(secondEntries);
            assertEq(dispatcher, address(0));
            assertEq(secondLccs.length, 2);
            assertEq(secondRecipients.length, 2);
            assertEq(secondAmounts.length, 2);
            assertEq(secondAttemptIds.length, 2);
            assertEq(secondLccs[0], lccB);
            assertEq(secondLccs[1], lccB);
            assertEq(secondRecipients[0], recipients[0]);
            assertEq(secondRecipients[1], recipients[1]);
            assertEq(secondAmounts[0], 1);
            assertEq(secondAmounts[1], 1);
        }
        assertTrue(_moreLiquidityAvailableEventCount(secondEntries) > 0);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 3, 0x8619, 10));
        Vm.Log[] memory thirdEntries = vm.getRecordedLogs();

        {
            (
                ,
                address[] memory thirdLccs,
                address[] memory thirdRecipients,
                uint256[] memory thirdAmounts,
                uint256[] memory thirdAttemptIds
            ) = _decodeProcessSettlementsPayload(thirdEntries);
            assertEq(thirdLccs.length, 2);
            assertEq(thirdRecipients.length, 2);
            assertEq(thirdAmounts.length, 2);
            assertEq(thirdAttemptIds.length, 2);
            assertEq(thirdLccs[0], lccB);
            assertEq(thirdLccs[1], lccB);
            assertEq(thirdRecipients[0], recipients[2]);
            assertEq(thirdRecipients[1], recipients[3]);
            assertEq(thirdAmounts[0], 1);
            assertEq(thirdAmounts[1], 1);
        }
        assertTrue(_moreLiquidityAvailableEventCount(thirdEntries) > 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 1, 0x8620, 11));
        Vm.Log[] memory fourthEntries = vm.getRecordedLogs();

        {
            (
                ,
                address[] memory fourthLccs,
                address[] memory fourthRecipients,
                uint256[] memory fourthAmounts,
                uint256[] memory fourthAttemptIds
            ) = _decodeProcessSettlementsPayload(fourthEntries);
            assertEq(fourthLccs.length, 1);
            assertEq(fourthRecipients.length, 1);
            assertEq(fourthAttemptIds.length, 1);
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

    /// @notice Post-registration queue growth mirrors immediately without spending the remaining historical backfill counter.
    function test_postRegistrationMirrorsDoNotConsumeHistoricalBackfillCounter() public {
        _clearSystemContract();

        HubRSC hub = new HubRSC(1, originChainId, destinationChainId, liquidityHub, destinationReceiverContract, REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(1)), lccB, 1, 1, 0x8620, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(2)), lccB, 1, 2, 0x8621, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(3)), lccB, 1, 3, 0x8622, 3));

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8623, 4));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8624, 5));

        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 2);

        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(4)), lccB, 1, 4, 0x8625, 6));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(5)), lccB, 1, 5, 0x8626, 7));

        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 2);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 5, bytes32("mktA"), 0x8627, 8));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        assertEq(_findCallbackPayloadBySelector(entries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        assertTrue(_moreLiquidityAvailableEventCount(entries) > 0);
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 1);
    }

    /// @notice Repeated liquidity on the active sibling still advances a historical sibling once bounded backfill completes.
    function test_historicalSiblingProgressesUnderSustainedActiveSiblingLiquidity() public {
        _clearSystemContract();

        HubRSC hub = new HubRSC(1, originChainId, destinationChainId, liquidityHub, destinationReceiverContract, REACTIVE_CALLBACK_PROXY_FOR_TESTS);

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(101)), lccB, 1, 1, 0x8630, 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(102)), lccB, 1, 2, 0x8631, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(103)), lccB, 1, 3, 0x8632, 3));

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8633, 4));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8634, 5));
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 2);

        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(201)), lccA, 1, 4, 0x8635, 6));

        {
            vm.recordLogs();
            _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 1, bytes32("mktA"), 0x8636, 7));
            Vm.Log[] memory firstEntries = vm.getRecordedLogs();

            (, address[] memory firstLccs, address[] memory firstRecipients, uint256[] memory firstAmounts,) =
                _decodeProcessSettlementsPayload(firstEntries);
            assertEq(firstLccs.length, 1);
            assertEq(firstRecipients.length, 1);
            assertEq(firstAmounts.length, 1);
            assertEq(firstLccs[0], lccA);
            assertEq(firstRecipients[0], address(uint160(201)));
            assertEq(firstAmounts[0], 1);
        }
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 1);

        _deliverReactiveVmLog(hub,_settlementLog(hub, address(uint160(202)), lccA, 1, 5, 0x8637, 8));

        {
            vm.recordLogs();
            _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 1, bytes32("mktA"), 0x8638, 9));
            Vm.Log[] memory secondEntries = vm.getRecordedLogs();

            (, address[] memory secondLccs, address[] memory secondRecipients, uint256[] memory secondAmounts,) =
                _decodeProcessSettlementsPayload(secondEntries);
            assertEq(secondLccs.length, 1);
            assertEq(secondRecipients.length, 1);
            assertEq(secondAmounts.length, 1);
            assertEq(secondLccs[0], lccB);
            assertEq(secondRecipients[0], address(uint160(101)));
            assertEq(secondAmounts[0], 1);
        }
        assertEq(hub.underlyingBackfillRemainingByLcc(lccB), 0);
    }

    /// @notice Partial processed release on shared-underlying dispatch prunes in-flight the same as the per-LCC lane.
    function test_sharedUnderlyingPartialInFlightReleaseMatchesPerLccSemantics() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        address recipient = makeAddr("recipient");
        bytes32 key = _computeKey(lccB, recipient);

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8600, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8601, 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccB, 100, 1, 0x8602, 3));

        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8603, 4));
        assertEq(hub.inFlightByKey(key), 100);

        _deliverReactiveVmLog(hub,_settlementProcessedLogWithRequested(hub, lccB, recipient, 60, 100, 0x8604, 5));
        _deliverReactiveVmLog(hub,_settlementSucceededLog(hub, lccB, recipient, 100, 1, 0x8605, 6));

        (uint256 remaining, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(remaining, 40);
        assertEq(hub.inFlightByKey(key), 0);
    }
}
