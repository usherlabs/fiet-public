// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

contract IMarketFactoryTest is Test {
    IMarketFactory marketFactory;
    MockERC20 token0;
    MockERC20 token1;
    IPoolManager poolManager;

    address owner = makeAddr("owner");
    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        // Deploy mock tokens
        token0 = new MockERC20("Mock Token 0", "MTK0", 18);
        token1 = new MockERC20("Mock Token 1", "MTK1", 18);

        // Deploy mock pool manager
        poolManager = IPoolManager(makeAddr("poolManager"));

        // Deploy MarketFactory with initial bounds
        address[] memory initialBounds = new address[](2);
        initialBounds[0] = address(poolManager);
        initialBounds[1] = user1;

        vm.startPrank(owner);
        marketFactory = IMarketFactory(address(new MarketFactory(address(poolManager), initialBounds)));
        vm.stopPrank();
    }

    function test_BoundsInterface() public {
        // Test that the interface correctly returns bounds
        assertTrue(marketFactory.bounds(address(poolManager)));
        assertTrue(marketFactory.bounds(user1));
        assertTrue(marketFactory.bounds(address(marketFactory)));
        assertFalse(marketFactory.bounds(user2));
    }

    function test_PoolManagerInterface() public {
        // Test that the interface correctly returns pool manager
        assertEq(marketFactory.poolManager(), address(poolManager));
    }

    function test_CreateMarketInterface() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(owner);
        (bytes32 corePoolId, bytes32 proxyPoolId) =
            marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        // Verify LCC tokens were created
        address lccToken0 = marketFactory.getLCC(address(token0));
        address lccToken1 = marketFactory.getLCC(address(token1));

        assertTrue(lccToken0 != address(0));
        assertTrue(lccToken1 != address(0));

        // Test isBound function
        assertTrue(marketFactory.isBound(lccToken0, address(poolManager)));
        assertFalse(marketFactory.isBound(lccToken0, user2));
    }

    function test_AddBoundsInterface() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(owner);
        marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        address lccToken0 = marketFactory.getLCC(address(token0));

        // Add new bounds
        address[] memory newBounds = new address[](1);
        newBounds[0] = user2;

        vm.startPrank(owner);
        marketFactory.addBounds(lccToken0, newBounds);
        vm.stopPrank();

        // Verify new bound was added
        assertTrue(marketFactory.isBound(lccToken0, user2));
    }

    function test_RemoveBoundsInterface() public {
        address[] memory initialBounds = new address[](2);
        initialBounds[0] = address(poolManager);
        initialBounds[1] = user1;

        vm.startPrank(owner);
        marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        address lccToken0 = marketFactory.getLCC(address(token0));

        // Remove user1 from bounds
        address[] memory boundsToRemove = new address[](1);
        boundsToRemove[0] = user1;

        vm.startPrank(owner);
        marketFactory.removeBounds(lccToken0, boundsToRemove);
        vm.stopPrank();

        // Verify user1 was removed from bounds
        assertFalse(marketFactory.isBound(lccToken0, user1));
    }
}
