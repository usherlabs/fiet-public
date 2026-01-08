// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {MMPositionManager} from "../src/MMPositionManager.sol";
import {MMPositionActionsImpl} from "../src/MMPositionActionsImpl.sol";
import {WETH} from "@uniswap/v4-core/lib/solmate/src/tokens/WETH.sol";
import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {VTSOrchestrator} from "../src/VTSOrchestrator.sol";
import {VRLSettlementObserver} from "../src/VRLSettlementObserver.sol";
import {IVRLSettlementObserver} from "../src/interfaces/IVRLSettlementObserver.sol";

contract HookTest is Test, Deployers {
    IPoolManager poolManager;
    MMPositionManager mmPositionManager;
    MarketFactory factory;
    CoreHook coreHook;
    ProxyHook proxyHook;
    VTSOrchestrator vtsOrchestrator;
    address owner = makeAddr("owner");

    function setUp() public {
        poolManager = IPoolManager(makeAddr("poolManager"));
        address[] memory bounds = new address[](0);

        // Deploy VRLSettlementObserver
        vm.prank(owner);
        IVRLSettlementObserver settlementObserver = new VRLSettlementObserver(owner);

        // Deploy VTSOrchestrator
        vm.prank(owner);
        vtsOrchestrator = new VTSOrchestrator(
            address(poolManager),
            makeAddr("signalManager"),
            address(makeAddr("OracleHelper")),
            address(makeAddr("liquidityHub")),
            address(settlementObserver),
            owner
        );

        vm.prank(owner);
        factory = new MarketFactory(
            address(poolManager),
            address(makeAddr("liquidityHub")),
            address(makeAddr("OracleHelper")),
            address(vtsOrchestrator),
            bounds,
            owner
        );
        IWETH9 weth9 = IWETH9(address(new WETH()));
        IAllowanceTransfer permit2 = IAllowanceTransfer(makeAddr("permit2"));

        // Deploy MMPositionActionsImpl first
        MMPositionActionsImpl actionsImpl =
            new MMPositionActionsImpl(address(poolManager), address(factory), address(vtsOrchestrator));

        mmPositionManager = new MMPositionManager(
            address(poolManager),
            address(factory),
            address(vtsOrchestrator),
            makeAddr("descriptor"),
            weth9,
            permit2,
            address(actionsImpl)
        );

        // Compute flags for CoreHook
        uint160 coreFlags = HookFlags.CORE_HOOK_FLAGS;
        address coreHookAddrComputed = address(coreFlags);

        deployCodeTo(
            "CoreHook.sol:CoreHook",
            abi.encode(poolManager, address(factory), address(vtsOrchestrator)),
            coreHookAddrComputed
        );
        coreHook = CoreHook(coreHookAddrComputed);

        // Compute flags for ProxyHook's address
        uint160 proxyFlags = HookFlags.PROXY_HOOK_FLAGS;
        address proxyHookAddrComputed = address(proxyFlags);

        deployCodeTo(
            "ProxyHook.sol:ProxyHook", abi.encode(address(poolManager), address(factory)), proxyHookAddrComputed
        );
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

    // Add more tests for hook functions...
}
