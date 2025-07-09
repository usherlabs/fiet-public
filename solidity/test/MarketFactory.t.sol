// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";

contract MarketFactoryTest is Test {
    using PoolIdLibrary for PoolKey;

    MarketFactory marketFactory;
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
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(owner);
        marketFactory = new MarketFactory(address(poolManager), initialBounds);
        vm.stopPrank();
    }

    function test_Constructor() public {
        assertEq(address(marketFactory.poolManager()), address(poolManager));
        assertEq(marketFactory.owner(), owner);
        assertTrue(marketFactory.bounds(address(poolManager)));
        assertTrue(marketFactory.bounds(address(marketFactory)));
    }

    function test_CreateMarket() public {
        address[] memory initialBounds = new address[](2);
        initialBounds[0] = address(poolManager);
        initialBounds[1] = address(this);

        vm.startPrank(owner);
        (PoolId corePoolId, PoolId proxyPoolId) =
            marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        // Verify LCC tokens were created
        address lccToken0 = marketFactory.getLCC(address(token0));
        address lccToken1 = marketFactory.getLCC(address(token1));

        assertTrue(lccToken0 != address(0));
        assertTrue(lccToken1 != address(0));

        // Verify underlying asset mapping
        assertEq(marketFactory.getUnderlyingAsset(lccToken0), address(token0));
        assertEq(marketFactory.getUnderlyingAsset(lccToken1), address(token1));

        // Verify LCC tokens are properly configured
        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(lccToken0);
        LiquidityCommitmentCertificate lcc1 = LiquidityCommitmentCertificate(lccToken1);

        assertEq(lcc0.underlyingAsset(), address(token0));
        assertEq(lcc1.underlyingAsset(), address(token1));
        assertEq(lcc0.marketFactory(), address(marketFactory));
        assertEq(lcc1.marketFactory(), address(marketFactory));

        // Verify bounds are set
        assertTrue(lcc0.bounds(address(poolManager)));
        assertTrue(lcc0.bounds(address(this)));
        assertTrue(lcc1.bounds(address(poolManager)));
        assertTrue(lcc1.bounds(address(this)));

        // Verify hooks were created
        address coreHook = marketFactory.getHook(corePoolId);
        address proxyHook = marketFactory.getHook(proxyPoolId);

        assertTrue(coreHook != address(0));
        assertTrue(proxyHook != address(0));
    }

    function test_CreateMarketWithExistingLCC() public {
        address[] memory initialBounds = new address[](2);
        initialBounds[0] = address(poolManager);
        initialBounds[1] = address(this);

        vm.startPrank(owner);

        // Create first market
        marketFactory.createMarket(address(token0), address(token1), initialBounds);

        // Create second market with same token0 but different token1
        MockERC20 token2 = new MockERC20("Mock Token 2", "MTK2", 18);
        marketFactory.createMarket(address(token0), address(token2), initialBounds);
        vm.stopPrank();

        // Verify same LCC token is reused for token0
        address lccToken0First = marketFactory.getLCC(address(token0));
        address lccToken0Second = marketFactory.getLCC(address(token0));

        assertEq(lccToken0First, lccToken0Second);
    }

    function test_AddBounds() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(owner);
        (PoolId corePoolId, PoolId proxyPoolId) =
            marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        address lccToken0 = marketFactory.getLCC(address(token0));
        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(lccToken0);

        // Initially only poolManager should be a bound
        assertTrue(lcc0.bounds(address(poolManager)));
        assertFalse(lcc0.bounds(user1));

        // Add new bounds
        address[] memory newBounds = new address[](1);
        newBounds[0] = user1;

        vm.startPrank(owner);
        marketFactory.addBounds(lccToken0, newBounds);
        vm.stopPrank();

        // Verify new bound was added
        assertTrue(lcc0.bounds(user1));
    }

    function test_RemoveBounds() public {
        address[] memory initialBounds = new address[](2);
        initialBounds[0] = address(poolManager);
        initialBounds[1] = user1;

        vm.startPrank(owner);
        (PoolId corePoolId, PoolId proxyPoolId) =
            marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        address lccToken0 = marketFactory.getLCC(address(token0));
        LiquidityCommitmentCertificate lcc0 = LiquidityCommitmentCertificate(lccToken0);

        // Initially both should be bounds
        assertTrue(lcc0.bounds(address(poolManager)));
        assertTrue(lcc0.bounds(user1));

        // Remove user1 from bounds
        address[] memory boundsToRemove = new address[](1);
        boundsToRemove[0] = user1;

        vm.startPrank(owner);
        marketFactory.removeBounds(lccToken0, boundsToRemove);
        vm.stopPrank();

        // Verify user1 was removed from bounds
        assertTrue(lcc0.bounds(address(poolManager)));
        assertFalse(lcc0.bounds(user1));
    }

    function test_IsBound() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = user1;

        vm.startPrank(owner);
        (PoolId corePoolId, PoolId proxyPoolId) =
            marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();

        address lccToken0 = marketFactory.getLCC(address(token0));

        // Test isBound function
        assertTrue(marketFactory.isBound(lccToken0, user1));
        assertFalse(marketFactory.isBound(lccToken0, user2));
    }

    function test_RevertWhenNotOwner() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(user1);
        vm.expectRevert();
        marketFactory.createMarket(address(token0), address(token1), initialBounds);
        vm.stopPrank();
    }

    function test_RevertWhenInvalidUnderlyingAsset() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(owner);
        vm.expectRevert(MarketFactory.InvalidUnderlyingAsset.selector);
        marketFactory.createMarket(address(0), address(token1), initialBounds);
        vm.stopPrank();
    }

    function test_RevertWhenInvalidPoolManager() public {
        address[] memory initialBounds = new address[](1);
        initialBounds[0] = address(poolManager);

        vm.startPrank(owner);
        vm.expectRevert(MarketFactory.InvalidPoolParameters.selector);
        new MarketFactory(address(0), initialBounds);
        vm.stopPrank();
    }
}
