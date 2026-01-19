// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {LiquidityHubTestBase} from "./base/LiquidityHubTestBase.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

/**
 * @title LiquidityHubAccessorTest
 * @notice Fast tests for LiquidityHub view/accessor functions and simple happy paths
 * @dev Intended to cheaply increase line + branch coverage without bloating behavioural suites.
 */
contract LiquidityHubAccessorTest is LiquidityHubTestBase {
    function test_constructor_setsOracleHelper() public view {
        assertEq(address(liquidityHub.oracleHelper()), address(oracleHelper));
    }

    function test_accessors_returnExpectedValues() public view {
        // marketUnderlyingToLCC
        assertEq(liquidityHub.marketUnderlyingToLCC(marketId1, address(underlyingAsset1)), lccToken1);
        assertEq(liquidityHub.marketUnderlyingToLCC(marketId1, address(underlyingAsset2)), lccToken2);

        // lccToUnderlying
        assertEq(liquidityHub.lccToUnderlying(lccToken1), address(underlyingAsset1));
        assertEq(liquidityHub.lccToUnderlying(lccToken2), address(underlyingAsset2));

        // lccToMarket
        (bytes32 id1, address factory1) = liquidityHub.lccToMarket(lccToken1);
        assertEq(id1, marketId1);
        assertEq(factory1, factory);

        // issuers
        assertTrue(liquidityHub.issuers(lccToken1, vtsOrchestrator));

        // getLCC/getUnderlying/isLCC
        assertEq(liquidityHub.getLCC(marketId1, address(underlyingAsset1)), lccToken1);
        assertEq(liquidityHub.getUnderlying(lccToken1), address(underlyingAsset1));
        assertTrue(liquidityHub.isLCC(lccToken1));
        assertFalse(liquidityHub.isLCC(address(0xDEAD)));
    }

    function test_getFactory_returnsFactoryWhenSameMarket() public view {
        assertEq(address(liquidityHub.getFactory(lccToken1, lccToken2)), factory);
    }

    function test_marketLiquidity_marketExistsPath_returnsFactoryValue() public {
        uint256 expected = 123;
        vm.mockCall(
            factory,
            abi.encodeWithSelector(IMarketFactory.marketLiquidity.selector, address(underlyingAsset1), marketId1),
            abi.encode(expected)
        );

        assertEq(liquidityHub.marketLiquidity(lccToken1), expected);
    }
}

