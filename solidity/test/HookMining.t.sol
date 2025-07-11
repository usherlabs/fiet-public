// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";

contract HookTest is Test {
    IPoolManager poolManager;
    MarketFactory factory;
    CoreHook coreHook;
    ProxyHook proxyHook;
    address owner = makeAddr("owner");

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));

        address[] memory bounds = new address[](0);
        vm.prank(owner);
        factory = new MarketFactory(address(poolManager), bounds);

        coreHook = new CoreHook(address(poolManager), address(factory));
        proxyHook = new ProxyHook(address(poolManager), address(factory));

        vm.prank(owner);
        factory.setHooks(address(coreHook), address(proxyHook));
    }

    function testCoreHookPermissions() public {
        Hooks.Permissions memory perms = coreHook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertFalse(perms.beforeAddLiquidity);
        assertTrue(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertTrue(perms.afterRemoveLiquidity);
        assertFalse(perms.beforeSwap);
        assertFalse(perms.afterSwap);
    }

    function testProxyHookPermissions() public {
        Hooks.Permissions memory perms = proxyHook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertTrue(perms.beforeAddLiquidity);
        assertFalse(perms.afterAddLiquidity);
        assertFalse(perms.beforeRemoveLiquidity);
        assertFalse(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertFalse(perms.afterSwap);
        assertTrue(perms.beforeSwapReturnDelta);
    }

    function testActivate() public {
        // Activation is called in setHooks, test if hooks have factory set or something
        assertEq(address(coreHook.marketFactory()), address(factory));
        assertEq(address(proxyHook.marketFactory()), address(factory));
    }

    // Add more tests for hook functions...
}
