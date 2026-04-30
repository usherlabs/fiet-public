// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {StdStorage, stdStorage} from "forge-std/StdStorage.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {ReactiveConstants} from "../../src/libs/ReactiveConstants.sol";
import {HubRSCTestBase, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

contract HubRSCZeroBatchRetryTest is HubRSCTestBase {
    using stdStorage for StdStorage;

    /// @notice Reserved-only head windows still retry later unseen siblings, but a single remaining window consumes
    /// the only retry credit immediately.
    function test_zeroBatchSharedUnderlyingScanEmitsRetryThenDispatchesNextWindow() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8520, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8521, 2));

        for (uint256 i = 0; i < hub.maxDispatchItems(); i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccB, 1, i + 1, 0x8522 + i, i + 1));

            bytes32 key = _computeKey(lccB, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }

        address laterRecipient = address(uint160(hub.maxDispatchItems() + 1));
        _deliverReactiveVmLog(hub,
            _settlementLog(hub, laterRecipient, lccB, 1, hub.maxDispatchItems() + 1, 0x8600, hub.maxDispatchItems() + 1)
        );

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8601, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        bytes memory firstProcessPayload =
            _findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR);
        assertEq(firstProcessPayload.length, 0);

        assertTrue(_moreLiquidityAvailableEventCount(firstEntries) > 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 100, 0x8602, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(secondEntries);
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], laterRecipient);
        assertEq(amounts[0], 1);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice A reserved prefix longer than one scan window still reaches a trailing dispatchable entry after multiple retries.
    function test_zeroBatchSharedUnderlyingLongReservedPrefixDispatchesAfterMultipleRetries() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x9500, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x9501, 2));

        uint256 m = hub.maxDispatchItems();
        for (uint256 i = 0; i < 2 * m + 1; i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccB, 1, i + 1, 0x9510 + i, i + 1));

            bytes32 key = _computeKey(lccB, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }

        address laterRecipient = address(uint160(2 * m + 2));
        _deliverReactiveVmLog(hub,_settlementLog(hub, laterRecipient, lccB, 1, 2 * m + 2, 0x9600, 2 * m + 2));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8601, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();
        assertEq(_findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        assertTrue(_moreLiquidityAvailableEventCount(firstEntries) > 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 100, 0x8602, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();
        assertEq(
            _findCallbackPayloadBySelector(secondEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0
        );
        assertTrue(_moreLiquidityAvailableEventCount(secondEntries) > 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 100, 0x8603, 3));
        Vm.Log[] memory thirdEntries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(thirdEntries);
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
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x9700, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x9701, 2));

        _queueReservedEntries(hub, lccB, 0, 0x9710, 1);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x9720, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();
        assertEq(_findCallbackPayloadBySelector(firstEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0);
        assertEq(_moreLiquidityAvailableEventCount(firstEntries), 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 100, 0x9721, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();
        assertEq(_callbackCount(secondEntries), 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice A continuation callback that hits a blocked shared-underlying window still reaches a later live sibling entry.
    function test_nonEmptyBatchContinuationReachesLaterWindowAfterBlockedReentry() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");
        uint256 m = hub.maxDispatchItems();
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x9800, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x9801, 2));

        for (uint256 i = 0; i < m; i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccB, 1, i + 1, 0x9810 + i, i + 1));
        }

        _queueReservedEntries(hub, lccB, m, 0x9900, m + 1);

        address laterRecipient = address(uint160(2 * m + 1));
        _deliverReactiveVmLog(hub,_settlementLog(hub, laterRecipient, lccB, 1, 2 * m + 1, 0x9A00, 2 * m + 1));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 1_000, bytes32("mktA"), 0x9A10, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();
        _assertDispatchedLength(firstEntries, m);

        (, uint256 firstRemainingLiquidity) = _decodeMoreLiquidityAvailablePayload(firstEntries);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, firstRemainingLiquidity, 0x9A11, 2));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();
        assertEq(
            _findCallbackPayloadBySelector(secondEntries, ReactiveConstants.PROCESS_SETTLEMENTS_SELECTOR).length, 0
        );

        (, uint256 secondRemainingLiquidity) = _decodeMoreLiquidityAvailablePayload(secondEntries);
        assertGt(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, secondRemainingLiquidity, 0x9A12, 3));
        Vm.Log[] memory thirdEntries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(thirdEntries);
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lccB);
        assertEq(recipients[0], laterRecipient);
        assertEq(amounts[0], 1);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }

    /// @notice A stale shared-underlying retry credit is cleared if the follow-up callback later falls back to per-LCC routing.
    function test_clearsStaleSharedRetryFlagWhenFollowupFallsBackToPerLcc() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lccA = makeAddr("lccA");
        address lccB = makeAddr("lccB");

        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccA, bytes32("mktA"), 0x8610, 1));
        _deliverReactiveVmLog(hub,_lccCreatedLog(hub, underlying, lccB, bytes32("mktB"), 0x8611, 2));

        uint256 m = hub.maxDispatchItems();
        for (uint256 i = 0; i < 2 * m + 1; i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementLog(hub, recipient, lccB, 1, i + 1, 0x8612 + i, i + 1));

            bytes32 key = _computeKey(lccB, recipient);
            stdstore.target(address(hub)).sig("inFlightByKey(bytes32)").with_key(key).checked_write(uint256(1));
        }

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8620, 1));
        Vm.Log[] memory firstEntries = vm.getRecordedLogs();

        assertTrue(_moreLiquidityAvailableEventCount(firstEntries) > 0);
        assertGt(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        for (uint256 i = 0; i < 2 * m + 1; i++) {
            address recipient = address(uint160(i + 1));
            _deliverReactiveVmLog(hub,_settlementProcessedLogWithRequested(hub, lccB, recipient, 1, 1, 0x8630 + i, i + 1));
            _clearSyntheticReservationAndPrune(hub, lccB, recipient, 0x8730 + i, i + 1);
        }
        assertEq(hub.queueSize(), 0);

        vm.recordLogs();
        _deliverReactiveVmLog(hub,_moreLiquidityAvailableLog(hub, lccA, 100, 0x8640, 1));
        Vm.Log[] memory fallbackEntries = vm.getRecordedLogs();
        assertEq(_callbackCount(fallbackEntries), 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);

        _queueReservedEntries(hub, lccB, 100, 0x8650, 101);
        address laterRecipient = address(uint160(m + 101));
        _deliverReactiveVmLog(hub,_settlementLog(hub, laterRecipient, lccB, 1, m + 101, 0x8661, m + 101));

        vm.recordLogs();
        _deliverReactiveVmLog(hub,liquidityAvailableLog(hub.liquidityHub(), lccA, underlying, 100, bytes32("mktA"), 0x8660, 1));
        Vm.Log[] memory secondEntries = vm.getRecordedLogs();

        assertTrue(_moreLiquidityAvailableEventCount(secondEntries) > 0);
        assertEq(hub.zeroBatchRetryCreditsRemaining(underlying), 0);
    }
}
