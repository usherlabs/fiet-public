// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {MarketVaultDeployer} from "../../src/MarketVaultDeployer.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {ILiquidityHub} from "../../src/interfaces/ILiquidityHub.sol";

/// @dev Minimal mock used to satisfy `ProxyHook` -> `MarketVault` constructor call to `marketFactory.liquidityHub()`.
contract MockMarketFactory {
    ILiquidityHub internal immutable _hub;

    constructor(ILiquidityHub hub_) {
        _hub = hub_;
    }

    function liquidityHub() external view returns (ILiquidityHub) {
        return _hub;
    }
}

contract MarketVaultDeployerTest is Test, OlympixUnitTest("MarketVaultDeployer") {
    MarketVaultDeployer internal deployer;
    MockMarketFactory internal factory;
    address internal poolManager;

    function setUp() public {
        factory = new MockMarketFactory(ILiquidityHub(address(0)));
        poolManager = makeAddr("poolManager");

        // MarketVaultDeployer is owned by MarketFactory via ImmutableMarketState(msg.sender)
        vm.prank(address(factory));
        deployer = new MarketVaultDeployer();
    }

    function test_deployProxyHook_revertsOnInvalidProxyHookFlagsForArbitrarySalt() public {
        // ProxyHook inherits BaseHook which validates the deployed address permissions EXACTLY.
        // So "bad salt" fails inside ProxyHook construction with Hooks.HookAddressNotValid,
        // before MarketVaultDeployer can evaluate InvalidProxyHookFlags().
        bytes32 salt = keccak256("random-salt");

        bytes32 initCodeHash =
            keccak256(abi.encodePacked(type(ProxyHook).creationCode, abi.encode(poolManager, address(factory))));
        address expectedDeployedHook =
            address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(deployer), salt, initCodeHash)))));

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, expectedDeployedHook));
        deployer.deployProxyHook(poolManager, salt);
    }

    function test_deployProxyHook_succeedsWithMinedSalt() public {
        bytes memory constructorArgs = abi.encode(poolManager, address(factory));
        (address expectedHook, bytes32 salt) =
            HookMiner.find(address(deployer), HookFlags.PROXY_HOOK_FLAGS, type(ProxyHook).creationCode, constructorArgs);

        vm.prank(address(factory));
        address deployedHook = deployer.deployProxyHook(poolManager, salt);

        assertEq(deployedHook, expectedHook);
    }
}

