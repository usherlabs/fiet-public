// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "./tools/OlympixUnitTest.sol";
import {ProxyHook} from "../../src/ProxyHook.sol";
import {IMarketFactory} from "../../src/interfaces/IMarketFactory.sol";
import {Errors} from "../../src/libraries/Errors.sol";
import {MarketVaultDeployer} from "../../src/MarketVaultDeployer.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {HookFlags} from "../../src/libraries/HookFlags.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract ProxyHookTest_Autocover is Test, OlympixUnitTest("ProxyHook") {
    ProxyHook internal hook;
    address internal marketFactory;
    MarketVaultDeployer internal vaultDeployer;

    function setUp() public {
        marketFactory = makeAddr("marketFactory");
        address liquidityHub = makeAddr("liquidityHub");
        address poolManager = makeAddr("poolManager");

        // MarketVault (base) reads marketFactory.liquidityHub() in constructor.
        vm.mockCall(
            marketFactory, abi.encodeWithSelector(IMarketFactory.liquidityHub.selector), abi.encode(liquidityHub)
        );

        // Deploy the hook via MarketVaultDeployer + CREATE2, using HookMiner to ensure the deployed
        // address has the exact hook permission bits required by ProxyHook (BaseHook validation).
        vm.prank(marketFactory);
        vaultDeployer = new MarketVaultDeployer();

        bytes memory constructorArgs = abi.encode(poolManager, marketFactory);
        (address expectedHook, bytes32 salt) = HookMiner.find(
            address(vaultDeployer), HookFlags.PROXY_HOOK_FLAGS, type(ProxyHook).creationCode, constructorArgs
        );

        vm.prank(marketFactory);
        address deployedHook = vaultDeployer.deployProxyHook(poolManager, salt);
        assertEq(deployedHook, expectedHook);

        hook = ProxyHook(payable(deployedHook));
    }

    function test_setCorePoolKey_revertsWhenNotFactory() public {
        vm.expectRevert(Errors.InvalidSender.selector);
        hook.setCorePoolKey(
            PoolKey({
                currency0: Currency.wrap(address(1)),
                currency1: Currency.wrap(address(2)),
                fee: 0,
                tickSpacing: 1,
                hooks: IHooks(address(0))
            })
        );
    }

    function test_activate_setsCoreHookFromFactory() public {
        address coreHook = makeAddr("coreHook");
        vm.mockCall(marketFactory, abi.encodeWithSelector(IMarketFactory.coreHook.selector), abi.encode(coreHook));

        vm.prank(marketFactory);
        hook.activate();

        assertEq(hook.coreHook(), coreHook);
    }
}

