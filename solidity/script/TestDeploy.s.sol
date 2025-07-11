// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";

import {CoreHook} from "../src/CoreHook.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {SepoliaConstants} from "./constants.sol";

/**
 * @title TestDeployScript
 * @notice Test script to verify deployment logic without actual deployment
 * @dev This script tests the HookMiner logic and contract interactions
 */
contract TestDeployScript is Script {
    // Hook flags for proper address mining
    uint160 constant CORE_HOOK_FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_ADD_LIQUIDITY_FLAG | Hooks.AFTER_REMOVE_LIQUIDITY_FLAG);

    uint160 constant PROXY_HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    function run() external {
        console.log("Testing deployment logic...");
        console.log("Pool Manager:", SepoliaConstants.POOL_MANAGER);
        console.log("CREATE2 Deployer:", SepoliaConstants.DEPLOYER_CREATE2);

        // Test MarketFactory deployment
        console.log("\n=== Testing MarketFactory Deployment ===");
        _testMarketFactoryDeployment();

        // Test CoreHook mining
        console.log("\n=== Testing CoreHook Mining ===");
        _testCoreHookMining();

        // Test ProxyHook mining
        console.log("\n=== Testing ProxyHook Mining ===");
        _testProxyHookMining();

        console.log("\n=== All tests passed! ===");
    }

    function _testCoreHookMining() internal {
        // Create a mock MarketFactory for testing
        address mockMarketFactory = address(0x3333333333333333333333333333333333333333);

        // CoreHook constructor takes (poolManager, marketFactory)
        bytes memory constructorArgs = abi.encode(SepoliaConstants.POOL_MANAGER, mockMarketFactory);

        // Mine the correct address with proper flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            SepoliaConstants.DEPLOYER_CREATE2, CORE_HOOK_FLAGS, type(CoreHook).creationCode, constructorArgs
        );

        console.log("CoreHook will be deployed to:", hookAddress);
        console.log("CoreHook salt:", vm.toString(salt));

        // Verify flags
        uint160 hookFlags = uint160(hookAddress) & Hooks.ALL_HOOK_MASK;
        require(hookFlags == CORE_HOOK_FLAGS, "CoreHook: incorrect flags");

        console.log("✓ CoreHook mining test passed");
    }

    function _testProxyHookMining() internal {
        // Create a mock MarketFactory for testing
        address mockMarketFactory = address(0x3333333333333333333333333333333333333333);

        // ProxyHook constructor takes (poolManager, marketFactory)
        bytes memory constructorArgs = abi.encode(SepoliaConstants.POOL_MANAGER, mockMarketFactory);

        // Mine the correct address with proper flags
        (address hookAddress, bytes32 salt) = HookMiner.find(
            SepoliaConstants.DEPLOYER_CREATE2, PROXY_HOOK_FLAGS, type(ProxyHook).creationCode, constructorArgs
        );

        console.log("ProxyHook will be deployed to:", hookAddress);
        console.log("ProxyHook salt:", vm.toString(salt));

        // Verify flags
        uint160 hookFlags = uint160(hookAddress) & Hooks.ALL_HOOK_MASK;
        require(hookFlags == PROXY_HOOK_FLAGS, "ProxyHook: incorrect flags");

        console.log("✓ ProxyHook mining test passed");
    }

    function _testMarketFactoryDeployment() internal {
        // Test with mock addresses
        address mockCoreHook = address(0x1111111111111111111111111111111111111111);
        address mockProxyHook = address(0x2222222222222222222222222222222222222222);

        // Initial bounds array
        address[] memory initialBounds = new address[](0);

        // Test MarketFactory constructor (without hooks)
        MarketFactory factory = new MarketFactory(SepoliaConstants.POOL_MANAGER, initialBounds);

        // Verify basic configuration
        require(factory.poolManager() == SepoliaConstants.POOL_MANAGER, "MarketFactory: wrong poolManager");

        // Test setHooks function
        factory.setHooks(mockCoreHook, mockProxyHook);

        // Verify hooks are set correctly
        require(factory.getCoreHook() == mockCoreHook, "MarketFactory: wrong coreHook");
        require(factory.getProxyHook() == mockProxyHook, "MarketFactory: wrong proxyHook");

        console.log("✓ MarketFactory deployment test passed");
    }

    /**
     * @dev Test hook permissions
     */
    function testHookPermissions() external {
        console.log("\n=== Testing Hook Permissions ===");

        // Create a mock MarketFactory for testing
        address mockMarketFactory = address(0x3333333333333333333333333333333333333333);

        // Test CoreHook permissions
        CoreHook coreHookInstance = new CoreHook(SepoliaConstants.POOL_MANAGER, mockMarketFactory);
        Hooks.Permissions memory corePermissions = coreHookInstance.getHookPermissions();

        require(corePermissions.beforeInitialize, "CoreHook should have beforeInitialize");
        require(corePermissions.afterAddLiquidity, "CoreHook should have afterAddLiquidity");
        require(corePermissions.afterRemoveLiquidity, "CoreHook should have afterRemoveLiquidity");
        require(!corePermissions.beforeSwap, "CoreHook should not have beforeSwap");

        console.log("✓ CoreHook permissions verified");

        // Test ProxyHook permissions
        ProxyHook proxyHookInstance = new ProxyHook(SepoliaConstants.POOL_MANAGER, mockMarketFactory);
        Hooks.Permissions memory proxyPermissions = proxyHookInstance.getHookPermissions();

        require(proxyPermissions.beforeInitialize, "ProxyHook should have beforeInitialize");
        require(proxyPermissions.beforeAddLiquidity, "ProxyHook should have beforeAddLiquidity");
        require(proxyPermissions.beforeSwap, "ProxyHook should have beforeSwap");
        require(proxyPermissions.beforeSwapReturnDelta, "ProxyHook should have beforeSwapReturnDelta");
        require(!proxyPermissions.afterAddLiquidity, "ProxyHook should not have afterAddLiquidity");

        console.log("✓ ProxyHook permissions verified");
        console.log("✓ All hook permissions verified");
    }
}
