// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Pausable} from "openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
<<<<<<< HEAD
import {IOracleRegistry} from "../src/interfaces/IOracleRegistry.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
=======
>>>>>>> main

contract HookTest is Test, Deployers {
    IPoolManager poolManager;
    MMPositionManager mmPositionManager;
    MarketFactory factory;
    CoreHook coreHook;
    ProxyHook proxyHook;
    address owner = makeAddr("owner");

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));
        address[] memory bounds = new address[](0);
        vm.prank(owner);

<<<<<<< HEAD
        factory = new MarketFactory(address(poolManager), address(oracleRegistry), bounds);
        IWETH9 weth9 = IWETH9(address(new WETH()));
        mmPositionManager =
            new MMPositionManager(address(poolManager), makeAddr("spokeReceiver"), address(factory), address(0), weth9);
=======
        factory = new MarketFactory(address(poolManager), address(makeAddr("OracleHelper")), bounds);
        mmPositionManager = new MMPositionManager(
            address(poolManager), makeAddr("spokeReceiver"), address(factory), makeAddr("settlementObserver")
        );
>>>>>>> main

        // Compute flags for CoreHook
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        address coreHookAddrComputed = address(coreFlags);

        deployCodeTo(
            "CoreHook.sol:CoreHook",
<<<<<<< HEAD
            abi.encode(poolManager, address(factory), address(mmPositionManager)),
=======
            abi.encode(poolManager, address(factory), address(mmPositionManager), address(0), address(0)),
>>>>>>> main
            coreHookAddrComputed
        );
        coreHook = CoreHook(coreHookAddrComputed);

        // Compute flags for ProxyHook's address
        uint160 proxyFlags = HookFlags.PROXY_HOOK_FLAGS;
        address proxyHookAddrComputed = address(proxyFlags);

        deployCodeTo("ProxyHook.sol:ProxyHook", abi.encode(poolManager, address(factory)), proxyHookAddrComputed);
        proxyHook = ProxyHook(payable(proxyHookAddrComputed));

        // Activate proxy hook
        vm.prank(address(factory));
        proxyHook.activate();
    }

    function testCoreHookPermissions() public view {
        Hooks.Permissions memory perms = coreHook.getHookPermissions();
        assertTrue(perms.beforeInitialize);
        assertFalse(perms.afterInitialize);
        assertTrue(perms.beforeAddLiquidity); // CoreHook has BEFORE_ADD_LIQUIDITY_FLAG
        assertTrue(perms.afterAddLiquidity);
        assertTrue(perms.beforeRemoveLiquidity); // CoreHook has BEFORE_REMOVE_LIQUIDITY_FLAG
        assertTrue(perms.afterRemoveLiquidity);
        assertTrue(perms.beforeSwap);
        assertTrue(perms.afterSwap);
        assertTrue(perms.afterRemoveLiquidityReturnDelta);
    }

    function testProxyHookPermissions() public view {
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

    function testActivate() public view {
        // Activation is called in setHooks, test if hooks have factory set or something
        assertEq(address(coreHook.marketFactory()), address(factory));
        assertEq(address(proxyHook.marketFactory()), address(factory));
    }

    function testPauseHook() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));

        // Non-factory cannot pause
        vm.expectRevert(CoreHook.InvalidSender.selector);
        coreHook.pause(poolId);

        // Factory can pause
        vm.prank(address(factory));
        coreHook.pause(poolId);

        assertTrue(coreHook.paused(poolId));

        // Cannot re-pause
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Pausable.EnforcedPause.selector));
        coreHook.pause(poolId);
    }

    function testUnpauseHook() public {
        PoolId poolId = PoolId.wrap(keccak256("test_pool"));

        vm.prank(address(factory));
        coreHook.pause(poolId);

        // Non-factory cannot unpause
        vm.expectRevert(CoreHook.InvalidSender.selector);
        coreHook.unpause(poolId);

        // Factory can unpause
        vm.prank(address(factory));
        coreHook.unpause(poolId);

        assertFalse(coreHook.paused(poolId));

        // Cannot re-unpause
        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Pausable.ExpectedPause.selector));
        coreHook.unpause(poolId);
    }

    // Add more tests for hook functions...
}
