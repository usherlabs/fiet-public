//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {IUniversalRouter} from "./libraries/universal-router/IUniversalRouter.sol";
import {Commands} from "./libraries/universal-router/Commands.sol";
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

import {SepoliaConstants} from "./constants/sepolia.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";

contract SwapV4 is ScriptHelper {
    using StateLibrary for IPoolManager;

    IUniversalRouter router;
    IPoolManager poolManager;
    IPermit2 permit2;
    IHooks hook;

    // Core pool tokens (intent tokens - WHERE LIQUIDITY GOES)
    LiquidityCommitmentCertificate lccUSDCToken;
    LiquidityCommitmentCertificate lccUSDTToken;

    // Proxy pool tokens (underlying tokens)
    address usdcToken;
    address usdtToken;

    function run() external {
        console.log("Starting SwapV4 script...");

        // Load deployment addresses
        _setFilename("sepolia");

        router = IUniversalRouter(payable(SepoliaConstants.UNIVERSAL_ROUTER));
        console.log("Universal Router loaded");

        poolManager = IPoolManager(SepoliaConstants.POOL_MANAGER);
        console.log("Pool Manager loaded");

        permit2 = IPermit2(SepoliaConstants.PERMIT2);
        console.log("Permit2 loaded");

        hook = IHooks(readAddress("proxyHook"));
        console.log("Proxy Hook loaded");

        address marketFactory = readAddress("marketFactory");

        usdcToken = readAddress("usdcToken");
        console.log("USDC Token loaded");
        usdtToken = readAddress("usdtToken");
        console.log("USDT Token loaded");

        // Core pool tokens
        lccUSDCToken = LiquidityCommitmentCertificate(
            IMarketFactory(marketFactory).getLCC(usdcToken)
        );
        lccUSDTToken = LiquidityCommitmentCertificate(
            IMarketFactory(marketFactory).getLCC(usdtToken)
        );

        uint256 userPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address userAddress = vm.addr(userPrivateKey);

        (Currency currencyA, Currency currencyB) = CurrencySortHelper
            .sortAddresses(usdcToken, usdtToken);
        PoolKey memory poolKey = PoolKey({
            currency0: currencyA,
            currency1: currencyB,
            fee: 0, // 0% fee
            tickSpacing: 60,
            hooks: hook
        });
        console.log("Checking balances...");
        uint256 balanceBeforeCurrency1;
        uint256 balanceBeforeCurrency0;

        try
            IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(userAddress)
        returns (uint256 balance) {
            balanceBeforeCurrency1 = balance;
            console.log("Currency1 balance checked");
        } catch {
            console.log("Failed to get Currency1 balance");
            balanceBeforeCurrency1 = 0;
        }

        try
            IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(userAddress)
        returns (uint256 balance) {
            balanceBeforeCurrency0 = balance;
            console.log("Currency0 balance checked");
        } catch {
            console.log("Failed to get Currency0 balance");
            balanceBeforeCurrency0 = 0;
        }

        vm.startBroadcast(userPrivateKey);

        console.log("Approving tokens...");
        approveTokenWithPermit2(usdcToken);
        console.log("USDC approved");

        approveTokenWithPermit2(usdtToken);
        console.log("USDT approved");

        console.log("Executing swap...");

        uint8 swapType = uint8(vm.envOr("SWAP_TYPE", uint8(0)));

        if (swapType == 0 || swapType == 1) {
            // For an 18 decimal token, 10e18 is 10 tokens
            swapExactInputSingle(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: true,
                    amountIn: 10e18,
                    amountOutMinimum: 0,
                    hookData: new bytes(0)
                })
            );

            // swapExactInputSingle(poolKey, 1, 0, userAddress);
            console.log("Exact Input Token 0 -> Token 1 Swap executed");
            console.log(
                "Token 0 - ",
                IERC20Metadata(Currency.unwrap(poolKey.currency0)).name(),
                ": ",
                IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(
                    userAddress
                ) / 1e18
            );
            console.log(
                "Token 1 - ",
                IERC20Metadata(Currency.unwrap(poolKey.currency1)).name(),
                ": ",
                IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(
                    userAddress
                ) / 1e18
            );
        } else if (swapType == 2) {
            swapExactInputSingle(
                IV4Router.ExactInputSingleParams({
                    poolKey: poolKey,
                    zeroForOne: false,
                    amountIn: 10e18 / 2, // Half the first swap
                    amountOutMinimum: 0,
                    hookData: new bytes(0)
                })
            );

            console.log("Exact Input Token 1 -> Token 0 Swap executed");
            console.log(
                "Token 0 - ",
                IERC20Metadata(Currency.unwrap(poolKey.currency0)).name(),
                ": ",
                IERC20(Currency.unwrap(poolKey.currency0)).balanceOf(
                    userAddress
                ) / 1e18
            );
            console.log(
                "Token 1 - ",
                IERC20Metadata(Currency.unwrap(poolKey.currency1)).name(),
                ": ",
                IERC20(Currency.unwrap(poolKey.currency1)).balanceOf(
                    userAddress
                ) / 1e18
            );
        } else {
            revert("Invalid swap type");
        }

        vm.stopBroadcast();
        uint256 balanceAfterCurrency1 = IERC20(
            Currency.unwrap(poolKey.currency1)
        ).balanceOf(userAddress);
        uint256 balanceAfterCurrency0 = IERC20(
            Currency.unwrap(poolKey.currency0)
        ).balanceOf(userAddress);
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

    function swapExactInputSingle(
        IV4Router.ExactInputSingleParams memory params
    ) public {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory rParams = new bytes[](3);

        // First parameter: swap configuration
        rParams[0] = abi.encode(params);

        if (params.zeroForOne) {
            // Second parameter: settle all for input
            rParams[1] = abi.encode(
                params.poolKey.currency0,
                type(uint256).max
            );
            // Third parameter: take all for output with minAmountOut
            rParams[2] = abi.encode(
                params.poolKey.currency1,
                params.amountOutMinimum
            );
        } else {
            // Second parameter: settle all for input
            rParams[1] = abi.encode(
                params.poolKey.currency1,
                type(uint256).max
            );

            // Third parameter: take all for output with minAmountOut
            rParams[2] = abi.encode(
                params.poolKey.currency0,
                params.amountOutMinimum
            );
        }

        bytes[] memory inputs = new bytes[](1);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, rParams);

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);
    }

    function swapExactOutputSingle(
        IV4Router.ExactOutputSingleParams memory params
    ) public {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );

        bytes[] memory rParams = new bytes[](3);

        // First parameter: swap configuration
        rParams[0] = abi.encode(params);

        if (params.zeroForOne) {
            rParams[1] = abi.encode(
                params.poolKey.currency0,
                type(uint256).max
            );
            rParams[2] = abi.encode(
                params.poolKey.currency1,
                params.amountInMaximum
            );
        } else {
            rParams[1] = abi.encode(
                params.poolKey.currency1,
                type(uint256).max
            );
            rParams[2] = abi.encode(
                params.poolKey.currency0,
                params.amountInMaximum
            );
        }

        bytes[] memory inputs = new bytes[](1);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, rParams);

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);
    }
}
