// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console, VmSafe} from "forge-std/Script.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

import {IToken} from "../src/IToken.sol";
import {SepoliaConstants} from "./constants.sol";
import {ScriptHelper} from "./deployments/ScriptHelper.s.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {CurrencySortHelper} from "./CurrencySortHelper.sol";

contract DiagnosticScript is ScriptHelper {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    IPositionManager positionManager;
    IPoolManager poolManager;
    ProxyHook proxyHook;

    // Core pool tokens (LCC tokens)
    IToken lccUSDCToken;
    IToken lccUSDTToken;

    // Proxy pool tokens (underlying tokens)
    address usdcToken;
    address usdtToken;

    PoolKey corePoolKey;
    PoolKey proxyPoolKey;

    function run() external {
        console.log("=== DIAGNOSTIC SCRIPT ===");

        positionManager = IPositionManager(SepoliaConstants.POSITION_MANAGER);
        poolManager = IPoolManager(SepoliaConstants.POOL_MANAGER);

        // Load tokens
        lccUSDCToken = IToken(readAddress("lccTokenUSDC"));
        lccUSDTToken = IToken(readAddress("lccTokenUSDT"));
        usdcToken = readAddress("usdcToken");
        usdtToken = readAddress("usdtToken");
        proxyHook = ProxyHook(readAddress("proxyHook"));

        setupPoolKeys();

        console.log("\n=== POOL STATE ANALYSIS ===");
        checkPoolStates();

        console.log("\n=== TOKEN BALANCES ===");
        checkTokenBalances();

        console.log("\n=== POSITION ANALYSIS ===");
        checkPositions();

        console.log("\n=== LIQUIDITY ANALYSIS ===");
        checkLiquidity();
    }

    function setupPoolKeys() internal {
        // Core pool: LCC tokens, no hooks
        (Currency currency0Core, Currency currency1Core) =
            CurrencySortHelper.sortAddresses(address(lccUSDCToken), address(lccUSDTToken));
        corePoolKey = PoolKey({
            currency0: currency0Core,
            currency1: currency1Core,
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(0))
        });

        // Proxy pool: underlying tokens, with hooks
        (Currency currency0Proxy, Currency currency1Proxy) =
            CurrencySortHelper.sortAddresses(address(usdcToken), address(usdtToken));
        proxyPoolKey =
            PoolKey({currency0: currency0Proxy, currency1: currency1Proxy, fee: 0, tickSpacing: 60, hooks: proxyHook});
    }

    function checkPoolStates() internal {
        console.log("Core Pool ID:", corePoolKey.toId());
        console.log("Proxy Pool ID:", proxyPoolKey.toId());

        // Check if pools are initialized
        {
            (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(poolManager, corePoolKey.toId());
            console.log("Core Pool - SqrtPriceX96:", sqrtPriceX96);
            console.log("Core Pool - Tick:", tick);
            console.log("Core Pool - Initialized: YES");
        }

        {
            (uint160 sqrtPriceX96, int24 tick,,) = StateLibrary.getSlot0(poolManager, proxyPoolKey.toId());
            console.log("Proxy Pool - SqrtPriceX96:", sqrtPriceX96);
            console.log("Proxy Pool - Tick:", tick);
            console.log("Proxy Pool - Initialized: YES");
        }
    }

    function checkTokenBalances() internal {
        console.log("Pool Manager balances:");
        console.log("  LCC USDC:", lccUSDCToken.balanceOf(address(poolManager)));
        console.log("  LCC USDT:", lccUSDTToken.balanceOf(address(poolManager)));
        console.log("  USDC:", IERC20(usdcToken).balanceOf(address(poolManager)));
        console.log("  USDT:", IERC20(usdtToken).balanceOf(address(poolManager)));

        console.log("\nProxy Hook balances:");
        console.log("  LCC USDC:", lccUSDCToken.balanceOf(address(proxyHook)));
        console.log("  LCC USDT:", lccUSDTToken.balanceOf(address(proxyHook)));
        console.log("  USDC:", IERC20(usdcToken).balanceOf(address(proxyHook)));
        console.log("  USDT:", IERC20(usdtToken).balanceOf(address(proxyHook)));

        console.log("\nLP User balances (from LP_PRIVATE_KEY):");
        uint256 lpPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address lpAddress = vm.addr(lpPrivateKey);
        console.log("  LCC USDC:", lccUSDCToken.balanceOf(lpAddress));
        console.log("  LCC USDT:", lccUSDTToken.balanceOf(lpAddress));
        console.log("  USDC:", IERC20(usdcToken).balanceOf(lpAddress));
        console.log("  USDT:", IERC20(usdtToken).balanceOf(lpAddress));
    }

    function checkPositions() internal {
        console.log("Checking positions...");

        // Try to find positions by checking recent token IDs
        for (uint256 i = 0; i < 10; i++) {
            try positionManager.getPositionLiquidity(i) returns (uint128 liquidity) {
                if (liquidity > 0) {
                    console.log("Position", i, "has liquidity:", liquidity);

                    try positionManager.getPoolAndPositionInfo(i) returns (PoolKey memory poolKey) {
                        console.log("  Pool ID:", poolKey.toId());
                        console.log("  Currency0:", Currency.unwrap(poolKey.currency0));
                        console.log("  Currency1:", Currency.unwrap(poolKey.currency1));
                    } catch {
                        console.log("  Could not get pool info for position", i);
                    }
                }
            } catch {
                // Position doesn't exist or error
            }
        }
    }

    function checkLiquidity() internal {
        console.log("Checking liquidity in core pool...");

        try poolManager.getSlot0(corePoolKey.toId()) returns (uint160 sqrtPriceX96, int24 tick) {
            console.log("Current tick:", tick);

            // Check liquidity at current tick and nearby ticks
            for (int24 offset = -60; offset <= 60; offset += 60) {
                int24 checkTick = tick + offset;
                try poolManager.getLiquidity(corePoolKey.toId(), checkTick) returns (uint128 liquidity) {
                    if (liquidity > 0) {
                        console.log("  Tick", checkTick, "has liquidity:", liquidity);
                    }
                } catch {
                    // No liquidity at this tick
                }
            }
        } catch {
            console.log("Could not get pool state");
        }
    }
}
