// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {SortTokens} from "@uniswap/v4-core/test/utils/SortTokens.sol";
import {MockERC20} from "@uniswap/v4-core/lib/solmate/src/test/utils/mocks/MockERC20.sol";
import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";
import {CurrencySortHelper} from "./CurrencySortHelper.sol";

address constant POOL_MANAGER = SepoliaConstants.POOL_MANAGER;

contract CorePoolScript is ScriptHelper {
    using PoolIdLibrary for PoolKey;

    function run() external {
        address lccTokenA = readAddress("lccTokenUSDT");
        address lccTokenB = readAddress("lccTokenUSDC");
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        console.log("Initializing LCC USDT/USDC Pool on Sepolia");

        (Currency currencyA, Currency currencyB) = CurrencySortHelper
            .sortAddresses(lccTokenA, lccTokenB);
        uint8 currencyADecimals = MockERC20(Currency.unwrap(currencyA))
            .decimals();
        require(currencyADecimals == 18, "Unsupported decimals currency A");

        uint8 currencyBDecimals = MockERC20(Currency.unwrap(currencyB))
            .decimals();
        require(currencyBDecimals == 18, "Unsupported decimals currency B");

        vm.startBroadcast(deployerPrivateKey);
        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: currencyA,
            currency1: currencyB,
            fee: 0, // 0% fee
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Initialize the pool
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        try poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1) {
            PoolId poolId = poolKey.toId();
            console.log("Pool initialized successfully!");
            console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
            writeString("corePoolId", vm.toString(PoolId.unwrap(poolId)));
        } catch (bytes memory reason) {
            console.log("Failed to initialize pool:");
            console.log("Reason: {}", vm.toString(reason));
        }

        vm.stopBroadcast();
    }
}

contract ProxyPoolScript is ScriptHelper {
    using PoolIdLibrary for PoolKey;

    function run() external {
        address tokenA = readAddress("usdtToken");
        address tokenB = readAddress("usdcToken");
        address proxyHook = readAddress("proxyHook");

        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
        vm.startBroadcast(deployerPrivateKey);
        console.log("Initializing USDT/USDC proxy Pool on Sepolia");
        (Currency currencyA, Currency currencyB) = CurrencySortHelper
            .sortAddresses(tokenA, tokenB);

        uint8 currencyADecimals = MockERC20(Currency.unwrap(currencyA))
            .decimals();
        require(currencyADecimals == 18, "Unsupported decimals currency A");

        uint8 currencyBDecimals = MockERC20(Currency.unwrap(currencyB))
            .decimals();
        require(currencyBDecimals == 18, "Unsupported decimals currency B");

        // Create pool configuration
        PoolKey memory poolKey = PoolKey({
            currency0: currencyA,
            currency1: currencyB,
            fee: 0, // 0% fee
            tickSpacing: 60,
            hooks: IHooks(proxyHook)
        });

        // Initialize the pool
        IPoolManager poolManager = IPoolManager(POOL_MANAGER);

        try poolManager.initialize(poolKey, Constants.SQRT_PRICE_1_1) {
            PoolId poolId = poolKey.toId();
            console.log("Pool initialized successfully!");
            console.log("Pool ID:", vm.toString(PoolId.unwrap(poolId)));
            writeString("proxyPoolId", vm.toString(PoolId.unwrap(poolId)));
        } catch (bytes memory reason) {
            console.log("Failed to initialize pool:");
            console.log("Reason: {}", vm.toString(reason));
        }

        vm.stopBroadcast();
    }
}
