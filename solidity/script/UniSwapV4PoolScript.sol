// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

address constant POOL_MANAGER = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;

contract CorePoolScript is Script {
    using PoolIdLibrary for PoolKey;

    address tokenA = 0xd94c3C1BC47e0Bb528d912089C9cA6A457cfc320; // LCC USDC
    address tokenB = 0x6c8537d89dd1C612AD0D7a9E48eEFFDBe9cB6A8e; // LCC USDT

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        console.log("Initializing USDT/USDC Pool on Sepolia");

        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(tokenA < tokenB ? tokenA : tokenB), // Ensure tokenA < tokenB
            currency1: Currency.wrap(tokenA < tokenB ? tokenB : tokenA),
            fee: 0, // 0% fee
            tickSpacing: 1,
            hooks: IHooks(address(0))
        });

        // Initialize the pool
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        try poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1) {
            PoolId poolId = poolKey.toId();
            console.log("Pool initialized successfully!");
            console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        } catch (bytes memory reason) {
            console.log("Failed to initialize pool:");
            console.log("Reason: {}", vm.toString(reason));
        }

        vm.stopBroadcast();
    }
}

contract ProxyPoolScript is Script {
    using PoolIdLibrary for PoolKey;

    address tokenA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d; // token USDC
    address tokenB = 0x99729dD47ACdA1713171501250E57a36aDCE5D08; // token USDT
    address proxyHook = 0xcf75b350696C9FfdE9D7A69FF10Fb65C57776888;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        console.log("Initializing USDT/USDC proxy Pool on Sepolia");

        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(tokenA < tokenB ? tokenA : tokenB), // Ensure tokenA < tokenB
            currency1: Currency.wrap(tokenA < tokenB ? tokenB : tokenA),
            fee: 0, // 0% fee
            tickSpacing: 1,
            hooks: IHooks(proxyHook)
        });

        // Initialize the pool
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        try poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1) {
            PoolId poolId = poolKey.toId();
            console.log("Pool initialized successfully!");
            console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
        } catch (bytes memory reason) {
            console.log("Failed to initialize pool:");
            console.log("Reason: {}", vm.toString(reason));
        }

        vm.stopBroadcast();
    }
}
