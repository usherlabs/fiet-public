// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {NativeWrapper} from "../../../src/forks/NativeWrapper.sol";

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

    // IWETH9 also includes ERC20 methods; not required for this skeleton.
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

contract NativeWrapperHarness is NativeWrapper {
    constructor(IWETH9 weth9, IPoolManager pm) ImmutableState(pm) NativeWrapper(weth9) {}

    function wrap(uint256 amount) external payable {
        _wrap(amount);
    }

    function unwrap(uint256 amount) external {
        _unwrap(amount);
    }
}

contract NativeWrapperForkTest is Test, OlympixUnitTest("forks/NativeWrapper") {
    NativeWrapperHarness internal wrapper;
    WETH9Mock internal weth;

    function setUp() public {
        weth = new WETH9Mock();
        wrapper = new NativeWrapperHarness(IWETH9(address(weth)), IPoolManager(makeAddr("poolManager")));
    }

    function test_receive_revertsOnUnexpectedSender() public {
        vm.expectRevert(NativeWrapper.InvalidEthSender.selector);
        (bool ok,) = address(wrapper).call{value: 1}("");
        ok; // silence unused warning
    }
}


