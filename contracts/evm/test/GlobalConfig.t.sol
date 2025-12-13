// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {MockContract} from "./_mocks/MockContract.t.sol";
import {GlobalConfig} from "../src/GlobalConfig.sol";

import "forge-std/console.sol";

contract GlobalConfigTest is Test {
    GlobalConfig public globalConfig;
    MockContract public mockContract;

    function setUp() public {
        console.log("working");
        globalConfig = new GlobalConfig();

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
}
