// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * E2E: Swap (standalone)
 *
 * Goal:
 * - Deploy a fresh full stack + create a fresh market
 * - Seed core pool liquidity (LCC/LCC)
 * - Perform an EXACT OUTPUT swap and assert the user receives exactly `amountOut`
 *
 * Env (signing only):
 * - PRIVATE_KEY (deployer / GlobalConfig owner)
 * - LP_PRIVATE_KEY (acts as LP and swapper to avoid extra env vars)
 */

import {console} from "forge-std/Script.sol";

import {IV4Quoter} from "v4-periphery/src/interfaces/IV4Quoter.sol";
import {V4Quoter} from "v4-periphery/src/lens/V4Quoter.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {E2EBase} from "./base/E2EBase.sol";

contract SwapE2E is E2EBase {
    using StateLibrary for IPoolManager;

    uint256 internal constant WRAP_AMOUNT_PER_ASSET = 1_200e18; // leaves room for swap after adding liquidity
    uint256 internal constant LIQUIDITY_AMOUNT_MAX = 1_000e18; // max per asset to deposit into liquidity
    uint128 internal constant AMOUNT_OUT = 10e18; // exact output amount to receive
    uint24 internal constant CORE_POOL_FEE = 0; // core pool fee used when creating the market
    bool internal constant ZERO_FOR_ONE = true; // swap direction: currency0 -> currency1

    function run() external {
        console.log("=== E2E: Swap (Exact Output) ===");
        // Initialize network configuration.
        _initNetwork();

        // Single actor for simplicity: provides liquidity and performs the swap.
        uint256 lpPk = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lp = vm.addr(lpPk);

        // Deploy full stack.
        CoreDeployment memory d = _deployCoreContracts();

        // Create a fresh market, mint underlyings to LP, and configure oracle.
        StandaloneMarket memory m = _createMarket(d, lp, CORE_POOL_FEE);

        console.log("=== E2E: Swap (Exact Output) ===");
        console.log("lp/swapper:", lp);
        console.log("MarketFactory:", m.stack.contracts.marketFactory);
        console.log("LiquidityHub:", m.stack.contracts.liquidityHub);
        console.log("CoreHook:", m.stack.contracts.coreHook);
        console.log("PositionManager:", config.positionManager);
        console.log("lcc0:", m.lcc0);
        console.log("lcc1:", m.lcc1);

        // Deploy a quoter (used via eth_call; not broadcast).
        IV4Quoter quoter;
        {
            vm.startBroadcast(_getDeployerPrivateKey());
            quoter = IV4Quoter(address(new V4Quoter(IPoolManager(config.poolManager))));
            vm.stopBroadcast();
            console.log("V4Quoter:", address(quoter));
        }

        // Seed core liquidity (wrap + mint full-range position + subscribe resolver).
        _addCoreLiquidityFullRange(m, lpPk, WRAP_AMOUNT_PER_ASSET, LIQUIDITY_AMOUNT_MAX);

        // Snapshot core pool price before swap.
        IPoolManager poolManager = IPoolManager(config.poolManager);
        PoolKey memory corePoolKey = _corePoolKey(m);
        (uint160 sqrtPriceX96Before,,,) = poolManager.getSlot0(corePoolKey.toId());
        console.log("sqrtPriceX96Before:", sqrtPriceX96Before);

        // Quote expected input for an exact-output swap on the core pool.
        // We swap currency0 -> currency1 (zeroForOne = true) and assert we receive exactly AMOUNT_OUT of currency1.
        uint256 expectedAmountIn;
        {
            (expectedAmountIn,) = quoter.quoteExactOutputSingle(
                IV4Quoter.QuoteExactSingleParams({
                    poolKey: corePoolKey, zeroForOne: ZERO_FOR_ONE, exactAmount: AMOUNT_OUT, hookData: ""
                })
            );
            console.log("Quoted expectedAmountIn:", expectedAmountIn);
        }

        // Execute exact-output swap, then assert exact deltas.
        (address tokenIn, address tokenOut, uint256 spent, uint256 received) =
            _swapExactOutputSingle(m, lpPk, ZERO_FOR_ONE, AMOUNT_OUT, expectedAmountIn);

        console.log("tokenIn:", tokenIn);
        console.log("tokenOut:", tokenOut);
        console.log("spent:", spent);
        console.log("received:", received);

        // Snapshot core pool price after swap.
        (uint160 sqrtPriceX96After,,,) = poolManager.getSlot0(corePoolKey.toId());
        console.log("sqrtPriceX96After:", sqrtPriceX96After);

        require(received == uint256(AMOUNT_OUT), "swap: output mismatch");
        require(spent == expectedAmountIn, "swap: input mismatch");

        // Price movement sanity:
        // In Uniswap v4, sqrtPriceX96 represents price for the ordered pair (currency0, currency1).
        // For a zeroForOne swap (currency0 -> currency1), price moves down => sqrtPriceX96 decreases.
        // For a oneForZero swap, price moves up => sqrtPriceX96 increases.
        if (ZERO_FOR_ONE) {
            require(sqrtPriceX96After < sqrtPriceX96Before, "swap: expected price to decrease");
        } else {
            require(sqrtPriceX96After > sqrtPriceX96Before, "swap: expected price to increase");
        }

        console.log("OK: swap exact output asserted (received == amountOut)");
    }
}

