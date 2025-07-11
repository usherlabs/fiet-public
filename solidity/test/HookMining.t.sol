// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {HookDeployer} from "../src/deployers/HookDeployer.sol";

/**
 * @title HookMiningTest
 * @notice Tests for hook mining functionality
 * @dev Verifies that hooks can be mined and deployed with correct flags
 */
contract HookMiningTest is Test, HookDeployer {
    IPoolManager poolManager;
    MarketFactory marketFactory;
    address coreHook;
    address proxyHook;

    function setUp() public {
        // Deploy mock pool manager
        poolManager = IPoolManager(address(0x1234567890123456789012345678901234567890));

        // Deploy market factory
        address[] memory bounds = new address[](0);
        marketFactory = new MarketFactory(address(poolManager), bounds, address(0), address(0));
    }

    function testCoreHookMining() public {
        // Deploy core hook using inherited functionality
        coreHook = _deployCoreHook(address(poolManager), address(marketFactory));

        // Verify the hook has the correct flags
        uint160 expectedFlags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        uint160 hookFlags = uint160(coreHook) & Hooks.ALL_HOOK_MASK;
        require(hookFlags == expectedFlags, "CoreHook: incorrect flags");

        console.log("CoreHook deployed successfully at:", coreHook);
    }

    function testProxyHookMining() public {
        // Deploy proxy hook using inherited functionality
        proxyHook = _deployProxyHook(address(poolManager), address(marketFactory));

        // Verify the hook has the correct flags
        uint160 expectedFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        uint160 hookFlags = uint160(proxyHook) & Hooks.ALL_HOOK_MASK;
        require(hookFlags == expectedFlags, "ProxyHook: incorrect flags");

        console.log("ProxyHook deployed successfully at:", proxyHook);
    }

    function testBothHooksMining() public {
        // Deploy both hooks using inherited functionality
        (coreHook, proxyHook) = _deployBothHooks(address(poolManager), address(marketFactory));

        // Verify both hooks have correct flags
        uint160 coreExpectedFlags =
            uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);
        uint160 proxyExpectedFlags = uint160(
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
                | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );

        uint160 coreHookFlags = uint160(coreHook) & Hooks.ALL_HOOK_MASK;
        uint160 proxyHookFlags = uint160(proxyHook) & Hooks.ALL_HOOK_MASK;

        require(coreHookFlags == coreExpectedFlags, "CoreHook: incorrect flags");
        require(proxyHookFlags == proxyExpectedFlags, "ProxyHook: incorrect flags");

        console.log("Both hooks deployed successfully");
        console.log("CoreHook:", coreHook);
        console.log("ProxyHook:", proxyHook);
    }

    function testMarketFactoryHookDeployment() public {
        // Test that MarketFactory can deploy hooks automatically
        address underlyingAsset0 = address(0x1111111111111111111111111111111111111111);
        address underlyingAsset1 = address(0x2222222222222222222222222222222222222222);

        // This should trigger hook deployment
        (PoolId corePoolId, PoolId proxyPoolId) = marketFactory.createMarket(
            underlyingAsset0,
            underlyingAsset1,
            3000, // 0.3% fee
            60, // tick spacing
            79228162514264337593543950336 // sqrt price 1:1
        );

        // Verify pools were created
        assertTrue(corePoolId != PoolId.wrap(0), "Core pool should be created");
        assertTrue(proxyPoolId != PoolId.wrap(0), "Proxy pool should be created");

        console.log("Market created successfully");
        console.log("Core Pool ID:", vm.toString(corePoolId));
        console.log("Proxy Pool ID:", vm.toString(proxyPoolId));
    }

    function testHookPermissions() public {
        // Test that hooks have correct permissions
        CoreHook coreHookInstance = new CoreHook(poolManager, address(marketFactory));
        ProxyHook proxyHookInstance = new ProxyHook(poolManager, address(marketFactory));

        Hooks.Permissions memory corePermissions = coreHookInstance.getHookPermissions();
        Hooks.Permissions memory proxyPermissions = proxyHookInstance.getHookPermissions();

        // Verify core hook permissions
        assertTrue(corePermissions.beforeInitialize, "CoreHook should have beforeInitialize");
        assertTrue(corePermissions.afterAddLiquidity, "CoreHook should have afterAddLiquidity");
        assertTrue(corePermissions.afterRemoveLiquidity, "CoreHook should have afterRemoveLiquidity");

        // Verify proxy hook permissions
        assertTrue(proxyPermissions.beforeInitialize, "ProxyHook should have beforeInitialize");
        assertTrue(proxyPermissions.beforeAddLiquidity, "ProxyHook should have beforeAddLiquidity");
        assertTrue(proxyPermissions.beforeSwap, "ProxyHook should have beforeSwap");
        assertTrue(proxyPermissions.beforeSwapReturnDelta, "ProxyHook should have beforeSwapReturnDelta");

        console.log("Hook permissions verified successfully");
    }
}
