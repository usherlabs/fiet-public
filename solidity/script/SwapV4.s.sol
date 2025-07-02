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
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";

contract SwapV4 is ScriptHelper {
    using StateLibrary for IPoolManager;

    UniversalRouter router;
    IPoolManager poolManager;
    IPermit2 permit2;

    // Proxy pool tokens (underlying tokens)
    address usdcToken;
    address usdtToken;

    function run() external {
        router = UniversalRouter(payable(SepoliaConstants.UNIVERSAL_ROUTER));
        poolManager = IPoolManager(SepoliaConstants.POOL_MANAGER);
        permit2 = IPermit2(SepoliaConstants.PERMIT2);

        // Proxy pool tokens (underlying tokens)
        usdcToken = readAddress("usdcToken");
        usdtToken = readAddress("usdtToken");
    }

    function approveTokenWithPermit2(
        address token,
        uint160 amount,
        uint48 expiration
    ) external {
        IERC20(token).approve(address(permit2), type(uint256).max);
        permit2.approve(token, address(router), amount, expiration);
    }

    function swapExactInputSingle(
        PoolKey calldata key, // PoolKey struct that identifies the v4 pool
        uint128 amountIn, // Exact amount of tokens to swap
        uint128 minAmountOut, // Minimum amount of output tokens expected
        uint256 deadline // Timestamp after which the transaction will revert
    ) external returns (uint256 amountOut) {
        bytes memory commands = abi.encodePacked(uint8(Commands.V4_SWAP));

        // Encode V4Router actions
        bytes memory actions = abi.encodePacked(
            uint8(Actions.SWAP_EXACT_IN_SINGLE),
            uint8(Actions.SETTLE_ALL),
            uint8(Actions.TAKE_ALL)
        );
    }
}
