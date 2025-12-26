// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {MarketVaultDeployer} from "../../src/MarketVaultDeployer.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

contract MarketVaultDeployerTest is Test, OlympixUnitTest("MarketVaultDeployer") {
    MarketVaultDeployer internal deployer;
    address internal factory;
    address internal poolManager;

    function setUp() public {
        factory = makeAddr("marketFactory");
        poolManager = makeAddr("poolManager");

        // MarketVaultDeployer is owned by MarketFactory via ImmutableMarketState(msg.sender)
        vm.prank(factory);
        deployer = new MarketVaultDeployer();
    }

    function test_deployProxyHook_revertsOnInvalidProxyHookFlagsForArbitrarySalt() public {
        // ProxyHook inherits BaseHook which validates the deployed address permissions EXACTLY.
        // So "bad salt" fails inside ProxyHook construction with Hooks.HookAddressNotValid,
        // before MarketVaultDeployer can evaluate InvalidProxyHookFlags().
        vm.prank(factory);
        vm.expectRevert(Hooks.HookAddressNotValid.selector);
        deployer.deployProxyHook(poolManager, keccak256("random-salt"));
    }

    function test_deployProxyHook_succeedsWithMinedSalt() public {
        bytes memory constructorArgs = abi.encode(poolManager, factory);
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(deployer), HookFlags.PROXY_HOOK_FLAGS, type(ProxyHook).creationCode, constructorArgs);

        vm.prank(factory);
        address deployedHook = deployer.deployProxyHook(poolManager, salt);

        assertEq(deployedHook, expectedHook);
    }
}

