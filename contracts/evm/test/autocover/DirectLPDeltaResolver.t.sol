// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {DirectLPDeltaResolver} from "../../src/DirectLPDeltaResolver.sol";
import {IPositionManager} from "v4-periphery/src/interfaces/IPositionManager.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
contract DirectLPDeltaResolverTest_Autocover is Test, OlympixUnitTest("DirectLPDeltaResolver") {
    DirectLPDeltaResolver internal resolver;

    function setUp() public {
        resolver = new DirectLPDeltaResolver(IPositionManager(makeAddr("positionManager")), ILiquidityHub(makeAddr("hub")));
    }

    function test_notifyModifyLiquidity_revertsWhenNotPositionManager() public {
        vm.expectRevert(DirectLPDeltaResolver.NotPositionManager.selector);
        resolver.notifyModifyLiquidity(1, 0, toBalanceDelta(0, 0));
    }

    function test_notifyUnsubscribe_revertsWhenNotPositionManager() public {
        // Should revert with NotPositionManager if called not by positionManager
        vm.expectRevert(DirectLPDeltaResolver.NotPositionManager.selector);
        resolver.notifyUnsubscribe(1234);
    }
    

    function test_notifySubscribe_revertsWhenFactoryNotFound() public {
        // Set up mock currency0 and currency1 addresses
        address currency0 = address(0xabc1);
        address currency1 = address(0xabc2);
    
        // Set up a dummy PoolKey (fee, tickSpacing, hooks arbitrary)
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(currency0),
            currency1: Currency.wrap(currency1),
            fee: 500,
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });
    
        // Mock the positionManager.getPoolAndPositionInfo to return our dummy poolKey for a tokenId
        address pm = address(resolver.positionManager());
        uint256 tokenId = 7777;
        vm.mockCall(
            pm,
            abi.encodeWithSelector(IPositionManager.getPoolAndPositionInfo.selector, tokenId),
            abi.encode(poolKey, bytes32(0))
        );
    
        // Mock the liquidityHub.getFactory(currency0, currency1) to return address(0)
        address hub = address(resolver.liquidityHub());
        vm.mockCall(
            hub,
            abi.encodeWithSelector(ILiquidityHub.getFactory.selector, currency0, currency1),
            abi.encode(address(0))
        );
    
        // Expect revert with DirectLPDeltaResolver.FactoryNotFound error
        vm.expectRevert(abi.encodeWithSelector(DirectLPDeltaResolver.FactoryNotFound.selector, currency0, currency1));
    
        // Call notifySubscribe with pm as msg.sender
        vm.prank(pm);
        resolver.notifySubscribe(tokenId, "");
    }
    
}