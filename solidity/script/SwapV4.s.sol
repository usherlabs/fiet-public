//SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/Script.sol";
import {UniversalRouter} from "@uniswap/universal-router/contracts/UniversalRouter.sol";
import {Commands} from "@uniswap/universal-router/contracts/libraries/Commands.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IV4Router} from "@uniswap/v4-periphery/src/interfaces/IV4Router.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {IPermit2} from "@uniswap/permit2/src/interfaces/IPermit2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";
import {CurrencySortHelper} from "./CurrencySortHelper.sol";

contract SwapV4 is ScriptHelper {
    using StateLibrary for IPoolManager;

    UniversalRouter router;
    IPoolManager poolManager;
    IPermit2 permit2;
    IHooks hook;

    // Proxy pool tokens (underlying tokens)
    address usdcToken;
    address usdtToken;

    function run() external {
        router = UniversalRouter(payable(SepoliaConstants.UNIVERSAL_ROUTER));
        poolManager = IPoolManager(SepoliaConstants.POOL_MANAGER);
        permit2 = IPermit2(SepoliaConstants.PERMIT2);
        hook = IHooks(readAddress("proxyHook"));
        // Proxy pool tokens (underlying tokens)
        usdcToken = readAddress("usdcToken");
        usdtToken = readAddress("usdtToken");

        uint256 userPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address userAddress = vm.addr(userPrivateKey);
        (Currency currencyA, Currency currencyB) = CurrencySortHelper
            .sortAddresses(usdcToken, usdtToken);
        PoolKey memory poolKey = PoolKey({
            currency0: currencyA,
            currency1: currencyB,
            fee: 0, // 0% fee
            tickSpacing: 1,
            hooks: IHooks(hook)
        });
        uint256 balanceBeforeCurrency1 = IERC20(
            Currency.unwrap(poolKey.currency1)
        ).balanceOf(userAddress);
        uint256 balanceBeforeCurrency0 = IERC20(
            Currency.unwrap(poolKey.currency0)
        ).balanceOf(userAddress);
        vm.startBroadcast(userPrivateKey);
        approveTokenWithPermit2(usdcToken);
        approveTokenWithPermit2(usdtToken);
        swapExactInputSingle(poolKey, 10e18, 0, userAddress);

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
        PoolKey memory key, // PoolKey struct that identifies the v4 pool
        uint128 amountIn, // Exact amount of tokens to swap
        uint128 minAmountOut,
        address user // Minimum amount of output tokens expected
    ) public {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE)
        );

        bytes[] memory params = new bytes[](1);

        // First parameter: swap configuration
        params[0] = abi.encode(
            IV4Router.ExactInputSingleParams({
                poolKey: key,
                zeroForOne: true, // true if we're swapping token0 for token1
                amountIn: amountIn, // amount of tokens we're swapping
                amountOutMinimum: minAmountOut, // minimum amount we expect to receive
                hookData: abi.encode(user)
            })
        );

        // Second parameter: specify input tokens for the swap
        // encode SETTLE_ALL parameters
        // params[1] = abi.encode(key.currency0, amountIn);

        // // Third parameter: specify output tokens from the swap
        // params[2] = abi.encode(key.currency1, minAmountOut);

        bytes[] memory inputs = new bytes[](1);

        // Combine actions and params into inputs
        inputs[0] = abi.encode(actions, params);

        // Execute the swap
        uint256 deadline = block.timestamp + 20;
        router.execute(commands, inputs, deadline);
    }
}
