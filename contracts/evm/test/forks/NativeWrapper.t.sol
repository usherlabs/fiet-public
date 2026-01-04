// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {NativeWrapper} from "../../src/forks/NativeWrapper.sol";

import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

contract WETH9Mock is IWETH9 {
    mapping(address => uint256) public balanceOf;

    function deposit() external payable {
        balanceOf[msg.sender] += msg.value;
    }

    function withdraw(uint256 wad) external {
        balanceOf[msg.sender] -= wad;
        (bool ok,) = payable(msg.sender).call{value: wad}("");
        require(ok, "withdraw failed");
    }

    function sendEth(address to, uint256 amount) external {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "send failed");
    }

    // IWETH9 also includes ERC20 methods; not required for these tests.
    function approve(address, uint256) external pure returns (bool) {
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return true;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function allowance(address, address) external pure returns (uint256) {
        return 0;
    }
}

contract PoolManagerMock {
    function sendEth(address to, uint256 amount) external {
        (bool ok,) = payable(to).call{value: amount}("");
        require(ok, "send failed");
    }

    receive() external payable {}
}

contract NativeWrapperHarness is NativeWrapper {
    constructor(IWETH9 weth9, IPoolManager pm) ImmutableState(pm) NativeWrapper(weth9) {}

    function wrap(uint256 amount) external payable {
        _wrap(amount);
    }

    function unwrap(uint256 amount) external {
        _unwrap(amount);
    }
}

contract NativeWrapperForkTest is Test {
    NativeWrapperHarness internal wrapper;
    WETH9Mock internal weth;
    PoolManagerMock internal poolManager;

    function setUp() public {
        weth = new WETH9Mock();
        poolManager = new PoolManagerMock();
        wrapper = new NativeWrapperHarness(IWETH9(address(weth)), IPoolManager(address(poolManager)));
    }

    function test_constructor_wiresWethAndPoolManager() public view {
        assertEq(address(wrapper.WETH9()), address(weth));
        assertEq(address(wrapper.poolManager()), address(poolManager));
    }

    function test_wrap_noopWhenAmountZero() public {
        wrapper.wrap(0);
        assertEq(weth.balanceOf(address(wrapper)), 0);
        assertEq(address(weth).balance, 0);
    }

    function test_wrap_depositsEthWhenAmountNonzero() public {
        vm.deal(address(this), 1 ether);
        wrapper.wrap{value: 1 ether}(1 ether);

        assertEq(weth.balanceOf(address(wrapper)), 1 ether);
        assertEq(address(weth).balance, 1 ether);
        assertEq(address(wrapper).balance, 0);
    }

    function test_wrap_revertsWhenInsufficientEthBalanceForAmount() public {
        vm.expectRevert();
        wrapper.wrap(1);
    }

    function test_wrap_leavesExcessEthInWrapperWhenMsgValueGreaterThanAmount() public {
        vm.deal(address(this), 2 ether);
        wrapper.wrap{value: 2 ether}(1 ether);

        assertEq(weth.balanceOf(address(wrapper)), 1 ether);
        assertEq(address(weth).balance, 1 ether);
        assertEq(address(wrapper).balance, 1 ether);
    }

    function test_unwrap_noopWhenAmountZero() public {
        wrapper.unwrap(0);
        assertEq(address(wrapper).balance, 0);
    }

    function test_unwrap_revertsWhenInsufficientWethBalance() public {
        vm.expectRevert(stdError.arithmeticError);
        wrapper.unwrap(1);
    }

    function test_unwrap_withdrawsAndReceiveAcceptsWethSender() public {
        vm.deal(address(this), 2 ether);
        wrapper.wrap{value: 2 ether}(2 ether);

        wrapper.unwrap(1 ether);

        assertEq(weth.balanceOf(address(wrapper)), 1 ether);
        assertEq(address(wrapper).balance, 1 ether);
        assertEq(address(weth).balance, 1 ether);
    }

    function test_receive_revertsOnUnexpectedSender() public {
        vm.expectRevert(NativeWrapper.InvalidEthSender.selector);
        (bool ok,) = address(wrapper).call{value: 1}("");
        ok; // silence unused warning
    }

    function test_receive_allowsWethSender_directSend() public {
        vm.deal(address(weth), 1 ether);
        weth.sendEth(address(wrapper), 1 ether);
        assertEq(address(wrapper).balance, 1 ether);
    }

    function test_receive_allowsPoolManagerSender() public {
        vm.deal(address(poolManager), 1 ether);
        poolManager.sendEth(address(wrapper), 1 ether);
        assertEq(address(wrapper).balance, 1 ether);
    }
}

