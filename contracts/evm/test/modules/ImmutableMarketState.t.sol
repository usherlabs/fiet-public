// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {ImmutableMarketState} from "../../src/modules/ImmutableMarketState.sol";
import {Errors} from "../../src/libraries/Errors.sol";

contract ImmutableMarketStateHarness is ImmutableMarketState {
    constructor(address mf) ImmutableMarketState(mf) {}

    function onlyFactoryFn() external onlyFactory returns (bool) {
        return true;
    }

    function onlyFactoryWithSenderFn(address sender) external onlyFactoryWithSender(sender) returns (bool) {
        return true;
    }

    function assertFactoryFn(address sender) external view {
        _assertFactory(sender);
    }
}

contract ImmutableMarketStateTest is Test {
    function test_constructor_revertsWhenFactoryIsZero() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        new ImmutableMarketStateHarness(address(0));
    }

    function test_onlyFactory_revertsWhenCallerNotFactory() public {
        ImmutableMarketStateHarness h = new ImmutableMarketStateHarness(makeAddr("factory"));
        vm.expectRevert(Errors.InvalidSender.selector);
        h.onlyFactoryFn();
    }

    function test_onlyFactory_succeedsWhenCallerIsFactory() public {
        address factory = makeAddr("factory");
        ImmutableMarketStateHarness h = new ImmutableMarketStateHarness(factory);

        vm.prank(factory);
        assertTrue(h.onlyFactoryFn());
    }

    function test_onlyFactoryWithSender_revertsWhenSenderNotFactory() public {
        ImmutableMarketStateHarness h = new ImmutableMarketStateHarness(makeAddr("factory"));
        vm.expectRevert(Errors.InvalidSender.selector);
        h.onlyFactoryWithSenderFn(makeAddr("notFactory"));
    }

    function test_onlyFactoryWithSender_succeedsWhenSenderIsFactory_evenIfMsgSenderDiffers() public {
        address factory = makeAddr("factory");
        ImmutableMarketStateHarness h = new ImmutableMarketStateHarness(factory);

        // Note: only the provided `sender` is checked (mirrors how hook callbacks pass the original sender).
        assertTrue(h.onlyFactoryWithSenderFn(factory));
    }

    function test__assertFactory_revertsWhenSenderNotFactory() public {
        ImmutableMarketStateHarness h = new ImmutableMarketStateHarness(makeAddr("factory"));
        vm.expectRevert(Errors.InvalidSender.selector);
        h.assertFactoryFn(makeAddr("notFactory"));
    }

    function test__assertFactory_succeedsWhenSenderIsFactory() public {
        address factory = makeAddr("factory");
        ImmutableMarketStateHarness h = new ImmutableMarketStateHarness(factory);
        h.assertFactoryFn(factory);
    }
}
