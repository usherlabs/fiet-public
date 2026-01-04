// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockContract} from "./_mocks/MockContract.t.sol";
import {GlobalConfig} from "../src/GlobalConfig.sol";
import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";

contract GlobalConfigTest is Test {
    GlobalConfig public globalConfig;
    MockContract public mockContract;

    function setUp() public {
        globalConfig = new GlobalConfig(address(this));

        // Deploy the mock contract
        mockContract = new MockContract();

        // Assign ownership to the global config
        mockContract.transferOwnership(address(globalConfig));

        // validate owner of mock contract is global config
        assertEq(mockContract.owner(), address(globalConfig));
    }

    // test that the proxy call to the method addTwoToNumber returns the correct number
    // validating that the global config contract can proxy call a method on a contract it is an owner of
    function test_proxyCall() public {
        uint256 initialNumber = 100;
        // make a proxy call to the method addToNumber
        bytes memory data = abi.encodeWithSelector(MockContract.addTwoToNumber.selector, initialNumber);
        bytes memory result = globalConfig.proxyCall(address(mockContract), data);
        uint256 number = abi.decode(result, (uint256));
        assertEq(number, initialNumber + 2);
    }

    function test_proxyCall_revertsOnInvalidTarget() public {
        bytes memory data = abi.encodeWithSelector(MockContract.addTwoToNumber.selector, 123);
        vm.expectRevert(bytes("INVALID_TARGET"));
        globalConfig.proxyCall(address(0), data);
    }

    function test_proxyCall_revertsWhenNotOwner() public {
        address notOwner = makeAddr("notOwner");
        bytes memory data = abi.encodeWithSelector(MockContract.addTwoToNumber.selector, 123);

        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        globalConfig.proxyCall(address(mockContract), data);
    }

    /// @dev Mutation-hardening: ensures the unauthorised-path is attributed to proxyCall() itself
    ///      even under coverage-based test selection by pairing a successful call with the revert.
    function test_proxyCall_onlyOwner_enforced() public {
        // Happy path as owner (this contract).
        bytes memory okData = abi.encodeWithSelector(MockContract.addTwoToNumber.selector, 7);
        bytes memory okResult = globalConfig.proxyCall(address(mockContract), okData);
        assertEq(abi.decode(okResult, (uint256)), 9);

        // Unauthorised path.
        address notOwner = makeAddr("notOwner");
        vm.prank(notOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, notOwner));
        globalConfig.proxyCall(address(mockContract), okData);
    }
}
