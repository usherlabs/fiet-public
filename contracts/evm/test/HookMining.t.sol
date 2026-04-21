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
import {CanonicalVault} from "../src/CanonicalVault.sol";

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
        address liquidityHubAddr = makeAddr("liquidityHub");
        address oracleHelperAddr = makeAddr("OracleHelper");
        // Deploy VTSOrchestrator
        vm.prank(owner);
        vtsOrchestrator = new VTSOrchestrator(address(poolManager), oracleHelperAddr, liquidityHubAddr, owner);

        // Deploy VRLSettlementObserver
        vm.prank(owner);
        new VRLSettlementObserver(address(vtsOrchestrator), owner);

        vm.prank(owner);
        factory = new MarketFactory(
            address(poolManager), liquidityHubAddr, oracleHelperAddr, address(vtsOrchestrator), owner
        );
        vm.prank(owner);
        CanonicalVault canonicalVault = new CanonicalVault(address(poolManager), liquidityHubAddr, address(factory));
        IWETH9 weth9 = IWETH9(address(new WETH()));
        IAllowanceTransfer permit2 = IAllowanceTransfer(makeAddr("permit2"));

        // Deploy MMPositionActionsImpl first
        MMPositionActionsImpl actionsImpl = new MMPositionActionsImpl(
            address(poolManager), address(factory), address(vtsOrchestrator), address(canonicalVault)
        );
        mmPositionManager = new MMPositionManager(
            MMPositionManager.MMPositionManagerInit({
                poolManager: poolManager,
                marketFactory: address(factory),
                vtsOrchestrator: address(vtsOrchestrator),
                canonicalCustody: address(canonicalVault),
                descriptor: makeAddr("descriptor"),
                weth9: weth9,
                permit2: permit2,
                actionsImpl: address(actionsImpl)
            })
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
        // This test only checks hook wiring; it does not exercise MarketFactory.initialise() or market creation.
        assertEq(address(coreHook.marketFactory()), address(factory));
        assertEq(address(proxyHook.marketFactory()), address(factory));
    }

    // Add more tests for hook functions...
}
