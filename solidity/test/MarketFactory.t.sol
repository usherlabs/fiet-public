// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {MockERC20} from "solmate/test/utils/mocks/MockERC20.sol";

import {MarketFactory} from "../src/MarketFactory.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {PausablePool} from "../src/libraries/PausablePool.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {HookFlags} from "../script/constants/HookFlags.sol";

contract MarketFactoryTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;

    MarketFactory factory;
    IPoolManager poolManager;
    address coreHookAddr;
    address proxyHookAddr;
    MockERC20 token0;
    MockERC20 token1;
    address owner = makeAddr("owner");

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));
        token0 = new MockERC20("Token0", "TK0", 18);
        token1 = new MockERC20("Token1", "TK1", 18);

        address[] memory bounds = new address[](0);

        vm.prank(owner);
        factory = new MarketFactory(address(poolManager), bounds);

        // Compute flags for CoreHook
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        coreHookAddr = address(coreFlags);

        // Deploy CoreHook at computed address
        deployCodeTo("CoreHook.sol:CoreHook", abi.encode(poolManager, address(factory)), coreHookAddr);

        // Compute flags for ProxyHook
        uint160 proxyFlags = HookFlags.PROXY_HOOK_FLAGS;
        proxyHookAddr = address(proxyFlags);

        // Deploy ProxyHook at computed address
        deployCodeTo("ProxyHook.sol:ProxyHook", abi.encode(poolManager, address(factory)), proxyHookAddr);

        vm.prank(owner);
        factory.setHooks(coreHookAddr);
    }

    function testCreateMarket() public {
        // Mock initialize calls
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId coreId, PoolId proxyId) = factory.createMarket(
            proxyHookAddr,
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336 // 1:1 price
        );

        assertTrue(PoolId.unwrap(coreId) != bytes32(0));
        assertTrue(PoolId.unwrap(proxyId) != bytes32(0));

        address lcc0 = factory.getLCC(address(token0));
        address lcc1 = factory.getLCC(address(token1));
        assertEq(factory.getUnderlyingAsset(lcc0), address(token0));
        assertEq(factory.getUnderlyingAsset(lcc1), address(token1));
    }

    function testGetCoreHook() public view {
        assertEq(factory.getCoreHook(), coreHookAddr);
    }

    function testGetProxyHook() public {
        // Mock initialize calls
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId _coreId, PoolId proxyId) = factory.createMarket(
            proxyHookAddr,
            address(token0),
            address(token1),
            3000,
            60,
            79228162514264337593543950336 // 1:1 price
        );

        // get proxy hook address
        address proxyHook = factory.proxyToHook(proxyId);
        assertEq(proxyHook, proxyHookAddr);
    }

    function testAddRemoveBounds() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        factory.createMarket(proxyHookAddr, address(token0), address(token1), 3000, 60, 79228162514264337593543950336);

        address[] memory newBounds = new address[](1);
        newBounds[0] = makeAddr("newBound");

        vm.prank(owner);
        factory.addBounds(newBounds);
        assertTrue(factory.bounds(newBounds[0]));

        vm.prank(owner);
        factory.removeBounds(newBounds);
        assertFalse(factory.bounds(newBounds[0]));
    }

    function testIsBound() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        factory.createMarket(proxyHookAddr, address(token0), address(token1), 3000, 60, 79228162514264337593543950336);

        address boundAddr = makeAddr("bound");

        address[] memory bounds = new address[](1);
        bounds[0] = boundAddr;

        vm.prank(owner);
        factory.addBounds(bounds);

        assertTrue(factory.bounds(boundAddr));
    }

    function testRevertInvalidUnderlying() public {
        vm.prank(owner);
        vm.expectRevert(IMarketFactory.InvalidUnderlyingAsset.selector);
        factory.createMarket(proxyHookAddr, address(0), address(token1), 3000, 60, 79228162514264337593543950336);
    }

    function testPauseMarket() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId coreId,) =
            factory.createMarket(proxyHookAddr, address(token0), address(token1), 3000, 60, 79228162514264337593543950336);

        // Non-owner cannot pause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.pause(coreId);

        // Owner can pause
        vm.prank(owner);
        factory.pause(coreId);

        assertTrue(CoreHook(coreHookAddr).paused(coreId));

        // Cannot re-pause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausablePool.EnforcedPause.selector));
        factory.pause(coreId);
    }

    function testUnpauseMarket() public {
        vm.mockCall(
            address(poolManager), abi.encodeWithSelector(IPoolManager.initialize.selector), abi.encode(bytes32(0))
        );

        vm.prank(owner);
        (PoolId coreId,) =
            factory.createMarket(proxyHookAddr, address(token0), address(token1), 3000, 60, 79228162514264337593543950336);

        vm.prank(owner);
        factory.pause(coreId);

        // Non-owner cannot unpause
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.unpause(coreId);

        // Owner can unpause
        vm.prank(owner);
        factory.unpause(coreId);

        assertFalse(CoreHook(coreHookAddr).paused(coreId));

        // Cannot re-unpause
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PausablePool.ExpectedPause.selector));
        factory.unpause(coreId);
    }
}
