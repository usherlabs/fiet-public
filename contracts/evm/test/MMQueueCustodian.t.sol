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

    address internal attacker = makeAddr("attacker");
    address internal beneficiary = makeAddr("beneficiary");
    address internal otherBeneficiary = makeAddr("otherBeneficiary");

    uint256 internal constant TOKEN_ID_A = 11;
    uint256 internal constant TOKEN_ID_B = 22;

    function setUp() public {
        positionManager = new DummyPositionManager();
        custodian = new MMQueueCustodian(address(positionManager));
        lcc = new MockERC20("LCC", "LCC", 18);
    }

    function test_constructor_revertsForZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        new MMQueueCustodian(address(0));
    }

    function test_constructor_revertsForEoa() public {
        address eoa = makeAddr("eoa");
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, eoa));
        new MMQueueCustodian(eoa);
    }

    function test_positionManager_isImmutable() public {
        assertEq(custodian.positionManager(), address(positionManager));
    }

    function test_record_revertsWhenCallerIsNotPositionManager() public {
        vm.prank(attacker);
        vm.expectRevert(Errors.InvalidSender.selector);
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 1);
    }

    function test_record_revertsForZeroLcc() public {
        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.record(TOKEN_ID_A, address(0), beneficiary, 1);
    }

    function test_record_revertsForZeroBeneficiary() public {
        vm.prank(address(positionManager));
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        custodian.record(TOKEN_ID_A, address(lcc), address(0), 1);
    }

    function test_record_zeroAmount_isNoop() public {
        vm.prank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 0);

        assertEq(custodian.queued(TOKEN_ID_A, address(lcc), beneficiary), 0);
        assertTrue(custodian.isBucketEmpty(TOKEN_ID_A));
    }

    function test_record_accumulatesPerTokenIdLccAndBeneficiary() public {
        vm.startPrank(address(positionManager));
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 10);
        custodian.record(TOKEN_ID_A, address(lcc), beneficiary, 15);
        custodian.record(TOKEN_ID_B, address(lcc), beneficiary, 7);
        custodian.record(TOKEN_ID_A, address(lcc), otherBeneficiary, 100);
        vm.stopPrank();

        assertEq(custodian.queued(TOKEN_ID_A, address(lcc), beneficiary), 25);
        assertEq(custodian.queued(TOKEN_ID_B, address(lcc), beneficiary), 7);
        assertEq(custodian.queued(TOKEN_ID_A, address(lcc), otherBeneficiary), 100);
        assertFalse(custodian.isBucketEmpty(TOKEN_ID_A));
        assertFalse(custodian.isBucketEmpty(TOKEN_ID_B));
    }

    function test_isBucketEmpty_trueWhenBucketUnused() public {
        assertTrue(custodian.isBucketEmpty(TOKEN_ID_A));
    }
}
