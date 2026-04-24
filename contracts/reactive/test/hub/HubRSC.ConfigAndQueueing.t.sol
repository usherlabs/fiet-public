// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {MockLiquidityHub} from "../_mocks/MockLiquidityHub.sol";
import {
    HubRSCTestBase,
    MockSettlementReceiver,
    DEFAULT_MAX_DISPATCH_ITEMS,
    RECEIVER_BATCH_SIZE_CAP
} from "./HubRSCTestBase.sol";

contract HubRSCConfigAndQueueingTest is HubRSCTestBase {
    function test_constructorRevertsOnInvalidConfig() public {
        bytes4 invalidConfigSelector = bytes4(keccak256("InvalidConfig()"));

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, 0, destinationChainId, liquidityHub, hubCallback, destinationReceiverContract
        );

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, 0, liquidityHub, hubCallback, destinationReceiverContract);

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            address(0),
            hubCallback,
            destinationReceiverContract
        );

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            address(0),
            destinationReceiverContract
        );

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, hubCallback, address(0));

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(
            RECEIVER_BATCH_SIZE_CAP + 1,
            originChainId,
            destinationChainId,
            liquidityHub,
            hubCallback,
            destinationReceiverContract
        );
    }

    /// @notice Aggregates pending settlements from an authoritative LiquidityHub queue log.
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

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 storedAmount, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(storedAmount, amount);
    }

    /// @notice First queued work is mirrored directly from LiquidityHub without requiring recipient-specific spoke onboarding.
    function test_firstQueuedSettlementIsVisibleWithoutRecipientSpokeOnboarding() public {
        _clearSystemContract();

        MockLiquidityHub liq = new MockLiquidityHub();
        MockSettlementReceiver receiver = new MockSettlementReceiver(address(liq));
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, address(liq), hubCallback, address(receiver)
        );

        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        hub.react(_lccCreatedLog(hub, underlying, lcc, bytes32("mkt"), 0x1200, 1));
        hub.react(_protocolSettlementQueuedLog(hub, lcc, recipient, 50, 0x1201, 2));

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 storedAmount, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(storedAmount, 50);

        vm.recordLogs();
        hub.react(liquidityAvailableLog(address(liq), lcc, underlying, 50, bytes32("mkt"), 0x1202, 3));
        Vm.Log[] memory entries = vm.getRecordedLogs();

        (, address[] memory lccs, address[] memory recipients, uint256[] memory amounts,) =
            _decodeProcessSettlementsPayload(entries);
        assertEq(lccs.length, 1);
        assertEq(recipients.length, 1);
        assertEq(amounts.length, 1);
        assertEq(lccs[0], lcc);
        assertEq(recipients[0], recipient);
        assertEq(amounts[0], 50);
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

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 storedAmount, bool exists) = _pendingState(hub, key);
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

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 amountAfter, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(amountAfter, 20);
    }
}
