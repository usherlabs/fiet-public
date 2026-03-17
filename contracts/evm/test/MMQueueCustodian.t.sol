// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {MMQueueCustodian} from "../src/MMQueueCustodian.sol";
import {Errors} from "../src/libraries/Errors.sol";
import {MockERC20} from "./_mocks/MockERC20.sol";

contract DummyPositionManager {}

contract MMQueueCustodianTest is Test {
    MMQueueCustodian internal custodian;
    MockERC20 internal lcc;
    DummyPositionManager internal positionManager;

    address internal binder = makeAddr("binder");
    address internal attacker = makeAddr("attacker");
    address internal recipient = makeAddr("recipient");

    uint256 internal constant TOKEN_ID_A = 11;
    uint256 internal constant TOKEN_ID_B = 22;

    function setUp() public {
        custodian = new MMQueueCustodian(binder);
        lcc = new MockERC20("LCC", "LCC", 18);
        positionManager = new DummyPositionManager();
    }

    function _bindPositionManager() internal {
        vm.prank(binder);
        custodian.setPositionManager(address(positionManager));
    }

    function test_constructor_revertsForZeroBinder() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MMQueueCustodian(address(0));
    }

    function test_setPositionManager_revertsWhenCallerIsNotBinder() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.setPositionManager(address(positionManager));
    }

    function test_setPositionManager_revertsForZeroAddress() public {
        vm.prank(binder);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.setPositionManager(address(0));
    }

    function test_setPositionManager_revertsForEoa() public {
        address eoa = makeAddr("eoa");
        vm.prank(binder);
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, eoa));
        custodian.setPositionManager(eoa);
    }

    function test_setPositionManager_bindsOnceAndClearsBinder() public {
        _bindPositionManager();

        assertEq(custodian.positionManager(), address(positionManager));
        assertEq(custodian.authorisedBinder(), address(0));

        vm.prank(binder);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.setPositionManager(address(positionManager));
    }

    function test_record_revertsWhenCallerIsNotPositionManager() public {
        _bindPositionManager();

        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.record(TOKEN_ID_A, address(lcc), 1);
    }

    function test_record_revertsForZeroLcc() public {
        _bindPositionManager();

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.record(TOKEN_ID_A, address(0), 1);
    }

    function test_record_zeroAmount_isNoop() public {
        _bindPositionManager();

        vm.prank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), 0);

        assertEq(custodian.queued(TOKEN_ID_A, address(lcc)), 0);
    }

    function test_record_accumulatesPerTokenIdAndLcc() public {
        _bindPositionManager();

        vm.startPrank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), 10);
        custodian.record(TOKEN_ID_A, address(lcc), 15);
        custodian.record(TOKEN_ID_B, address(lcc), 7);
        vm.stopPrank();

        assertEq(custodian.queued(TOKEN_ID_A, address(lcc)), 25);
        assertEq(custodian.queued(TOKEN_ID_B, address(lcc)), 7);
    }

    function test_release_revertsForInvalidRecipient() public {
        _bindPositionManager();

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.release(TOKEN_ID_A, address(lcc), address(0), 1);
    }

    function test_release_revertsForInvalidLcc() public {
        _bindPositionManager();

        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.release(TOKEN_ID_A, address(0), recipient, 1);
    }

    function test_release_revertsWhenCallerIsNotPositionManager() public {
        _bindPositionManager();

        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.release(TOKEN_ID_A, address(lcc), recipient, 1);
    }

    function test_release_zeroMaxAmount_returnsZero() public {
        _bindPositionManager();

        vm.prank(address(positionManager));
        uint256 released = custodian.release(TOKEN_ID_A, address(lcc), recipient, 0);
        assertEq(released, 0);
    }

    function test_release_zeroAvailable_returnsZero() public {
        _bindPositionManager();

        vm.prank(address(positionManager));
        uint256 released = custodian.release(TOKEN_ID_A, address(lcc), recipient, 10);
        assertEq(released, 0);
    }

    function test_release_partialRelease_debitsQueueAndTransfers() public {
        _bindPositionManager();
        lcc.mint(address(custodian), 100);

        vm.prank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), 80);

        vm.prank(address(positionManager));
        uint256 released = custodian.release(TOKEN_ID_A, address(lcc), recipient, 30);

        assertEq(released, 30);
        assertEq(custodian.queued(TOKEN_ID_A, address(lcc)), 50);
        assertEq(lcc.balanceOf(recipient), 30);
    }

    function test_release_fullRelease_capsAtAvailableAndIsolatesBuckets() public {
        _bindPositionManager();
        lcc.mint(address(custodian), 100);

        vm.startPrank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), 40);
        custodian.record(TOKEN_ID_B, address(lcc), 35);
        vm.stopPrank();

        vm.prank(address(positionManager));
        uint256 released = custodian.release(TOKEN_ID_A, address(lcc), recipient, 1000);

        assertEq(released, 40);
        assertEq(custodian.queued(TOKEN_ID_A, address(lcc)), 0);
        assertEq(custodian.queued(TOKEN_ID_B, address(lcc)), 35);
        assertEq(lcc.balanceOf(recipient), 40);
    }
}
