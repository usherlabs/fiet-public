// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {OracleHelper} from "../../src/OracleHelper.sol";

import {Errors} from "../../src/libraries/Errors.sol";
import {ILCC} from "../../src/interfaces/ILCC.sol";
import {IResilientOracle} from "../../src/interfaces/IResilientOracle.sol";

contract OracleHelperTest_Autocover is Test, OlympixUnitTest("OracleHelper") {
    OracleHelper internal helper;

    function setUp() public {
        helper = new OracleHelper(makeAddr("resilientOracle"), address(this));
    }

    function test_registerTicker_onlyOwner() public {
        vm.prank(makeAddr("notOwner"));
        vm.expectRevert();
        helper.registerTicker("ETH", makeAddr("eth"));

        helper.registerTicker("ETH", makeAddr("eth"));
        assertEq(helper.getAssetByTicker("ETH"), makeAddr("eth"));
    }

    function test_registerTicker_zeroAsset_reverts() public {
        // Asset is address(0) - should revert with Errors.InvalidAddress
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAddress.selector, address(0)));
        helper.registerTicker("ZERO", address(0));
    }

    function test_getAssetByTicker_reverts_if_not_registered() public {
        // Revert with the Errors.TickerNotRegistered custom error if ticker is not registered
        vm.expectRevert(abi.encodeWithSelector(Errors.TickerNotRegistered.selector, "FOO"));
        helper.getAssetByTicker("FOO");
    }

    function test_validateMarketOracles_reverts_when_mainDisabledOrAssetZero() public {
        // Prepare two LCC addresses and assets
        address lcc0 = address(0x100);
        address lcc1 = address(0x200);
        address asset0 = address(0xabc1);
        address asset1 = address(0xabc2);

        // Deploy OracleHelper with this contract as owner, as in setUp
        OracleHelper realHelper = new OracleHelper(address(this), address(this));

        // Mock ILCC responses for underlying().
        // asset0 and asset1 are returned as underlying for lcc0 and lcc1
        vm.mockCall(lcc0, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset0));
        vm.mockCall(lcc1, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset1));

        // Prepare TokenConfig with MAIN disabled for asset 0
        IResilientOracle.TokenConfig memory tc0;
        IResilientOracle.TokenConfig memory tc1;
        tc0.asset = asset0;
        tc1.asset = asset1;
        tc0.enableFlagsForOracles = [false, true, true]; // MAIN disabled for asset0
        tc1.enableFlagsForOracles = [true, true, true]; // MAIN enabled for asset1

        // Mock oracle.getTokenConfig(asset0) returns tc0, asset1 returns tc1
        vm.mockCall(
            address(this), abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset0), abi.encode(tc0)
        );
        vm.mockCall(
            address(this), abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset1), abi.encode(tc1)
        );

        // Expect revert due to MAIN being disabled for asset0
        vm.expectRevert(Errors.MarketOraclesNotConfigured.selector);
        realHelper.validateMarketOracles(lcc0, lcc1);

        // Also test zero asset: asset field in TokenConfig is address(0)
        tc0.enableFlagsForOracles = [true, true, true];
        tc0.asset = address(0); // now asset0 config is missing asset
        vm.mockCall(
            address(this), abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset0), abi.encode(tc0)
        );
        // Expect revert due to asset==address(0)
        vm.expectRevert(Errors.MarketOraclesNotConfigured.selector);
        realHelper.validateMarketOracles(lcc0, lcc1);
    }

    function test_validateMarketOracles_mainEnabledAndAssetSet_doesNotRevert() public {
        // Setup two LCCs and asset addresses
        address lcc0 = address(0x100);
        address lcc1 = address(0x200);
        address asset0 = address(0xabc1);
        address asset1 = address(0xabc2);

        OracleHelper realHelper = new OracleHelper(address(this), address(this));

        // Mock ILCC responses for underlying()
        vm.mockCall(lcc0, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset0));
        vm.mockCall(lcc1, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset1));

        // Construct TokenConfig structs with all MAIN flags enabled and asset set
        IResilientOracle.TokenConfig memory tc0;
        IResilientOracle.TokenConfig memory tc1;
        tc0.asset = asset0;
        tc1.asset = asset1;
        tc0.enableFlagsForOracles = [true, true, true];
        tc1.enableFlagsForOracles = [true, true, true];

        // Mock oracle.getTokenConfig for asset0 and asset1
        vm.mockCall(
            address(this), abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset0), abi.encode(tc0)
        );
        vm.mockCall(
            address(this), abi.encodeWithSelector(IResilientOracle.getTokenConfig.selector, asset1), abi.encode(tc1)
        );

        // Should NOT revert (enters the 'else' branch)
        realHelper.validateMarketOracles(lcc0, lcc1);
    }

    function test_getPriceForLcc_branch_true() public {
        // Test the opix-target-branch-120-True for getPriceForLcc
        // Arrange: Deploy OracleHelper with this as owner and mock oracle
        address lcc = address(0x100);
        address asset = address(0xabc1);
        address resilientOracle = makeAddr("oracle");
        OracleHelper realHelper = new OracleHelper(resilientOracle, address(this));

        // Mock: lcc.underlying() -> asset
        vm.mockCall(lcc, abi.encodeWithSelector(ILCC.underlying.selector), abi.encode(asset));
        // Mock: oracle.getPrice(asset) -> 1234e18
        vm.mockCall(
            resilientOracle, abi.encodeWithSelector(IResilientOracle.getPrice.selector, asset), abi.encode(1234e18)
        );

        // Act: Query the price via subject contract
        uint256 price = realHelper.getPriceForLcc(lcc);
        // Assert: Should match mocked price
        assertEq(price, 1234e18);
    }
}
