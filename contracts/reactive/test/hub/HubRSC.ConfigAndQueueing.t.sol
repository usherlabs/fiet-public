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
            DEFAULT_MAX_DISPATCH_ITEMS, 0, destinationChainId, liquidityHub, destinationReceiverContract, address(1)
        );

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, 0, liquidityHub, destinationReceiverContract, address(1));

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            address(0),
            destinationReceiverContract,
            address(1)
        );

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(DEFAULT_MAX_DISPATCH_ITEMS, originChainId, destinationChainId, liquidityHub, address(0), address(1));

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(0, originChainId, destinationChainId, liquidityHub, destinationReceiverContract, address(1));

        vm.expectRevert(abi.encodeWithSelector(invalidConfigSelector));
        new HubRSC(
            RECEIVER_BATCH_SIZE_CAP + 1,
            originChainId,
            destinationChainId,
            liquidityHub,
            destinationReceiverContract,
            address(1)
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
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        _deliverReactiveVmLog(hub, _settlementLog(hub, recipient, lcc, amount, 1, 0x1234, 7));

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
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            address(liq),
            address(receiver),
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");
        address recipient = makeAddr("recipient");

        _deliverReactiveVmLog(hub, _lccCreatedLog(hub, underlying, lcc, bytes32("mkt"), 0x1200, 1));
        _deliverReactiveVmLog(hub, _protocolSettlementQueuedLog(hub, lcc, recipient, 50, 0x1201, 2));

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 storedAmount, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(storedAmount, 50);

        vm.recordLogs();
        _deliverReactiveVmLog(hub, liquidityAvailableLog(address(liq), lcc, underlying, 50, bytes32("mkt"), 0x1202, 3));
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
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");
        uint256 amount = 50;

        IReactive.LogRecord memory log = _settlementLog(hub, recipient, lcc, amount, 1, 0x4567, 9);

        _deliverReactiveVmLog(hub, log);
        _deliverReactiveVmLog(hub, log);

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
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        IReactive.LogRecord memory log = _settlementLog(hub, recipient, lcc, 0, 1, 0xabc1, 1);

        _deliverReactiveVmLog(hub, log);

        assertFalse(_pendingExists(hub, lcc, recipient));
    }

    function test_acceptsLowerNonceWhenLogIdentityIsNew() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address recipient = makeAddr("recipient");
        address lcc = makeAddr("lcc");

        _deliverReactiveVmLog(hub, _settlementLog(hub, recipient, lcc, 10, 2, 0xabc2, 1));
        _deliverReactiveVmLog(hub, _settlementLog(hub, recipient, lcc, 10, 1, 0xabc3, 2));

        bytes32 key = _computeKey(lcc, recipient);
        (uint256 amountAfter, bool exists) = _pendingState(hub, key);
        assertTrue(exists);
        assertEq(amountAfter, 20);
    }
}
