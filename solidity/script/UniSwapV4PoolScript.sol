// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IHooks} from "v4-core/libraries/Hooks.sol";
import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";

contract CorePoolScript is Script {
    using PoolIdLibrary for PoolKey;

    address constant POOL_MANAGER = 0xFB3e0C6F74eB1a21CC1Da29aeC80D2Dfe6C9a317;
    address lccTokenA = 0xd94c3C1BC47e0Bb528d912089C9cA6A457cfc320;
    address lccTokenB = 0x6c8537d89dd1C612AD0D7a9E48eEFFDBe9cB6A8e;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);
        console.log("Initializing USDT/USDC Pool on Sepolia");

        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(lccTokenA < lccTokenB ? lccTokenA : lccTokenB), // Ensure token0 < token1
            currency1: Currency.wrap(lccTokenA < lccTokenB ? lccTokenB : lccTokenA),
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
