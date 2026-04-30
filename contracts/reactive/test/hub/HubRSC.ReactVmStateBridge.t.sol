// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
import {Vm} from "forge-std/Vm.sol";
import {HubRSC} from "../../src/HubRSC.sol";
import {AbstractHubReactiveBridge} from "../../src/libs/AbstractHubReactiveBridge.sol";
import {HubRSCTestBase, DEFAULT_MAX_DISPATCH_ITEMS} from "./HubRSCTestBase.sol";

/// @notice Regression coverage for ReactVM observation vs canonical callback application.
contract HubRSCReactVmStateBridgeTest is HubRSCTestBase {
    function test_reactAloneDoesNotMutateCanonicalLccUnderlyingState() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");

        IReactive.LogRecord memory log = _lccCreatedLog(hub, underlying, lcc, bytes32("mkt"), 0xA001, 1);

        assertEq(hub.canonicalReactiveHub(), address(hub));

        hub.react(log);
        assertFalse(hub.hasUnderlyingForLcc(lcc));

        vm.prank(REACTIVE_CALLBACK_PROXY_FOR_TESTS);
        hub.applyCanonicalProtocolLog(address(this), log);
        assertTrue(hub.hasUnderlyingForLcc(lcc));
    }

    function test_applyCanonicalProtocolLogAcceptsInjectedCallbackOrigin() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        address rvmOrigin = makeAddr("rvmOrigin");
        address underlying = makeAddr("underlying");
        address lcc = makeAddr("lcc");
        IReactive.LogRecord memory log = _lccCreatedLog(hub, underlying, lcc, bytes32("mkt"), 0xA003, 1);

        vm.prank(REACTIVE_CALLBACK_PROXY_FOR_TESTS);
        hub.applyCanonicalProtocolLog(rvmOrigin, log);

        assertEq(hub.underlyingByLcc(lcc), underlying);
        assertTrue(hub.hasUnderlyingForLcc(lcc));
    }

    function test_applyCanonicalProtocolLogRevertsUnlessReactiveCallbackProxy() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        IReactive.LogRecord memory log =
            _lccCreatedLog(hub, makeAddr("underlying"), makeAddr("lcc"), bytes32("mkt"), 0xA002, 1);

        vm.expectRevert(AbstractHubReactiveBridge.UnauthorizedReactiveCallback.selector);
        hub.applyCanonicalProtocolLog(address(this), log);
    }

    function test_reactRelaysCanonicalDestinationCallbackRequestToProtocolReceiver() public {
        _clearSystemContract();
        HubRSC hub = new HubRSC(
            DEFAULT_MAX_DISPATCH_ITEMS,
            originChainId,
            destinationChainId,
            liquidityHub,
            destinationReceiverContract,
            REACTIVE_CALLBACK_PROXY_FOR_TESTS
        );

        bytes memory payload = abi.encodeWithSelector(bytes4(0xdeaf7cc0), address(this));
        IReactive.LogRecord memory log = IReactive.LogRecord({
            chain_id: hub.reactChainId(),
            _contract: hub.canonicalReactiveHub(),
            topic_0: hub.DESTINATION_CALLBACK_REQUESTED_TOPIC(),
            topic_1: 0,
            topic_2: 0,
            topic_3: 0,
            data: abi.encode(payload),
            block_number: 0,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0xA004,
            log_index: 1
        });

        vm.recordLogs();
        hub.react(log);
        Vm.Log[] memory entries = vm.getRecordedLogs();

        bytes32 callbackSig = keccak256("Callback(uint256,address,uint64,bytes)");
        bool sawDestinationCallback;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics.length == 4 && entries[i].topics[0] == callbackSig) {
                assertEq(uint256(entries[i].topics[1]), hub.protocolChainId());
                assertEq(address(uint160(uint256(entries[i].topics[2]))), hub.destinationReceiverContract());
                assertEq(abi.decode(entries[i].data, (bytes)), payload);
                sawDestinationCallback = true;
            }
        }
        assertTrue(sawDestinationCallback);
    }
}
