//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {IUniversalRouter} from "./external/IUniversalRouter.sol";
import {Commands} from "./external/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Router} from "v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

contract SwapV4 is ScriptHelper {
    using StateLibrary for IPoolManager;

    IUniversalRouter router;
    IPoolManager poolManager;
    IPermit2 permit2;
    IHooks hook;

    // Proxy pool tokens (underlying tokens)
    address token0;
    address token1;

    function run() external {
        console.log("Starting SwapV4 script...");

        string memory networkName = vm.envOr("NETWORK", "sepolia");
        _setFilename(networkName);

        address universalRouterAddr;
        address poolManagerAddr;
        address permit2Addr;

        if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
            universalRouterAddr = SepoliaConstants.UNIVERSAL_ROUTER;
            poolManagerAddr = SepoliaConstants.POOL_MANAGER;
            permit2Addr = SepoliaConstants.PERMIT2;
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            universalRouterAddr = ArbitrumConstants.UNIVERSAL_ROUTER;
            poolManagerAddr = ArbitrumConstants.POOL_MANAGER;
            permit2Addr = ArbitrumConstants.PERMIT2;
        } else {
            revert("Unsupported network");
        }

        router = IUniversalRouter(payable(universalRouterAddr));
        console.log("Universal Router loaded");

        poolManager = IPoolManager(poolManagerAddr);
        console.log("Pool Manager loaded");

        permit2 = IPermit2(permit2Addr);
        console.log("Permit2 loaded");

        hook = IHooks(readAddress("proxyHook"));
        console.log("Proxy Hook loaded");

        address marketFactory = readAddress("marketFactory");

        string memory corePoolId = vm.envOr("CORE_POOL_ID", "");
        bool isSepolia = keccak256(bytes(networkName)) == keccak256(bytes("sepolia"));

        uint24 fee;
        int24 tickSpacing;

        if (bytes(corePoolId).length == 0) {
            if (isSepolia) {
                token0 = readAddress("usdcToken");
                console.log("Token0 (USDC) loaded from defaults");
                token1 = readAddress("usdtToken");
                console.log("Token1 (USDT) loaded from defaults");
            } else {
                revert("CORE_POOL_ID required for non-sepolia networks");
            }
            fee = 0;
            console.log("Pool fee (default):", fee);
            tickSpacing = 60;
            console.log("Tick spacing (default):", tickSpacing);
        } else {
            string memory filePath = string.concat("./deployments/", networkName, "_markets.json");
            string memory json = vm.readFile(filePath);

            string memory keyToken0 = string.concat(".", corePoolId, "_underlyingAsset0");
            string memory keyToken1 = string.concat(".", corePoolId, "_underlyingAsset1");
            string memory keyFee = string.concat(".", corePoolId, "_corePoolFee");
            string memory keyTS = string.concat(".", corePoolId, "_tickSpacing");

            token0 = vm.parseJsonAddress(json, keyToken0);
            console.log("Token0 loaded from markets json");
            token1 = vm.parseJsonAddress(json, keyToken1);
            console.log("Token1 loaded from markets json");

            uint256 jsonFee = vm.parseJsonUint(json, keyFee);
            fee = uint24(jsonFee);
            console.log("Pool fee loaded:", fee);

            uint256 jsonTS = vm.parseJsonUint(json, keyTS);
            tickSpacing = int24(uint24(jsonTS));
            console.log("Tick spacing loaded:", tickSpacing);
        }

        (Currency currencyA, Currency currencyB) = CurrencySortHelper.sortAddresses(token0, token1);
        PoolKey memory poolKey =
            PoolKey({currency0: currencyA, currency1: currencyB, fee: fee, tickSpacing: tickSpacing, hooks: hook});
        console.log("Checking balances...");
        uint256 balanceBeforeCurrency1;
        uint256 balanceBeforeCurrency0;

        try IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(userAddress) returns (uint256 balance) {
            balanceBeforeCurrency1 = balance;
            console.log("Currency1 balance checked");
        } catch {
            console.log("Failed to get Currency1 balance");
            balanceBeforeCurrency1 = 0;
        }

        try IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(userAddress) returns (uint256 balance) {
            balanceBeforeCurrency0 = balance;
            console.log("Currency0 balance checked");
        } catch {
            console.log("Failed to get Currency0 balance");
            balanceBeforeCurrency0 = 0;
        }

        vm.startBroadcast(userPrivateKey);

        console.log("Approving tokens...");
        approveTokenWithPermit2(token0);
        console.log("Token0 approved");

        approveTokenWithPermit2(token1);
        console.log("Token1 approved");

        uint8 swapType = uint8(vm.envOr("SWAP_TYPE", uint8(0)));

        if (swapType < 0 || swapType > 5) {
            revert("Invalid swap type");
        }

        if (swapType == 0 || swapType == 1 || swapType == 5) {
            uint256 amount = vm.envOr("AMOUNT", 10e18);
            console.log("Executing Exact Input swap for Token 0 -> Token 1...");

            // For an 18 decimal token, 10e18 is 10 tokens
            swapExactInputSingle(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: true,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    hookData: new bytes(0)
                })
            );

            // swapExactInputSingle(poolKey, 1, 0, userAddress);
            console.log("Exact Input Token 0 -> Token 1 Swap executed");
        }
        if (swapType == 2 || swapType == 5) {
            uint256 amount = vm.envOr("AMOUNT", 10e18 / 2);
            console.log("Executing Exact Input swap for Token 1 -> Token 0...");

            swapExactInputSingle(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: false,
                    amountIn: amount,
                    amountOutMinimum: 0,
                    hookData: new bytes(0)
                })
            );

            console.log("Exact Input Token 1 -> Token 0 Swap executed");
        }
        if (swapType == 3 || swapType == 5) {
            uint256 amount = vm.envOr("AMOUNT", 10e18);
            console.log("Executing Exact Output swap for Token 0 -> Token 1...");

            swapExactOutputSingle(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: true,
                    amountInMaximum: type(uint128).max,
                    amountOut: amount,
                    hookData: new bytes(0)
                })
            );

            console.log("Exact Output Token 0 -> Token 1 Swap executed");
        }
        if (swapType == 4 || swapType == 5) {
            uint256 amount = vm.envOr("AMOUNT", 10e18 / 2);
            console.log("Executing Exact Output swap for Token 1 -> Token 0...");

            swapExactOutputSingle(
                IV4Router.ExactOutputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: false,
                    amountInMaximum: type(uint128).max,
                    amountOut: amount,
                    hookData: new bytes(0)
                })
            );

            console.log("Exact Output Token 1 -> Token 0 Swap executed");
        }

        console.log(
            "Token 0 - ",
            IERC20Metadata(Currency.unwrap(poolKey.currency0)).name(),
            ": ",
            IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(userAddress) / 1e18
        );
        console.log(
            "Token 1 - ",
            IERC20Metadata(Currency.unwrap(poolKey.currency1)).name(),
            ": ",
            IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(userAddress) / 1e18
        );

        vm.stopBroadcast();
        uint256 balanceAfterCurrency1 = IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(userAddress);
        uint256 balanceAfterCurrency0 = IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(userAddress);
        console.log(
            "user: Currency 0 balance Before: ",
            balanceBeforeCurrency0 / 1e18,
            "Balance After: ",
            balanceAfterCurrency0 / 1e18
        );
        console.log(
            "user: Currency 1 balance Before: ",
            balanceBeforeCurrency1 / 1e18,
            "Balance After: ",
            balanceAfterCurrency1 / 1e18
        );
    }

    function approveTokenWithPermit2(address token) public {
        IERC20(token).approve(address(permit2), type(uint256).max);
        uint48 deadline = uint48(block.timestamp + 1000);
        permit2.approve(token, address(router), type(uint160).max, deadline);
    }

    function swapExactInputSingle(IV4Router.ExactInputSingleParams memory params) public {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_IN_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory rParams = new bytes[](3);

        // First parameter: swap configuration
        rParams[0] = abi.encode(params);

        if (params.zeroForOne) {
            // Second parameter: settle all for input
            rParams[1] = abi.encode(params.poolKey.currency0, type(uint256).max);
            // Third parameter: take all for output with minAmountOut
            rParams[2] = abi.encode(params.poolKey.currency1, params.amountOutMinimum);
        } else {
            // Second parameter: settle all for input
            rParams[1] = abi.encode(params.poolKey.currency1, type(uint256).max);

            // Third parameter: take all for output with minAmountOut
            rParams[2] = abi.encode(params.poolKey.currency0, params.amountOutMinimum);
        }

        bytes[] memory inputs = new bytes[](1);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, rParams);

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);
    }

    function swapExactOutputSingle(IV4Router.ExactOutputSingleParams memory params) public {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions =
            abi.encodePacked(uint8(Actions.SWAP_EXACT_OUT_SINGLE), uint8(Actions.SETTLE_ALL), uint8(Actions.TAKE_ALL));

        bytes[] memory rParams = new bytes[](3);

        // First parameter: swap configuration
        rParams[0] = abi.encode(params);

        if (params.zeroForOne) {
            // zeroForOne means Token 0 -> Token 1.
            // Therefore, here we're specifying Token 1 that we want OUT.
            rParams[1] = abi.encode(params.poolKey.currency0, params.amountInMaximum);
            rParams[2] = abi.encode(params.poolKey.currency1, params.amountOut);
        } else {
            // zeroForOne = false means Token 1 -> Token 0.
            // We're specifying Token 0 that we want OUT.
            rParams[1] = abi.encode(params.poolKey.currency1, params.amountInMaximum);
            rParams[2] = abi.encode(params.poolKey.currency0, params.amountOut);
        }

        bytes[] memory inputs = new bytes[](1);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, rParams);

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);
    }
}
