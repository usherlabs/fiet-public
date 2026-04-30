// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {IReactive} from "reactive-lib/interfaces/IReactive.sol";
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
        hub.applyCanonicalProtocolLog(log);
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
        hub.applyCanonicalProtocolLog(log);
    }
}
