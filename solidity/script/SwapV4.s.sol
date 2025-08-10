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
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {IMarketFactory} from "../src/interfaces/IMarketFactory.sol";
import {LiquidityCommitmentCertificate} from "../src/LCC.sol";

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

contract SwapV4 is ScriptHelper {
    using StateLibrary for IPoolManager;

    IUniversalRouter router;
    IPoolManager poolManager;
    IPermit2 permit2;
    IHooks hook;

    // Proxy pool tokens (underlying tokens)
    address token0;
    address token1;

    // variables for meta logs
    string corePoolId;
    PoolId _corePoolId;
    address lccToken0;
    address lccToken1;
    PoolKey corePoolKey;

    function run() external {
        console.log("Starting SwapV4 script...");

        string memory networkName;
        try vm.envString("NETWORK") returns (string memory envNetworkName) {
            networkName = envNetworkName;
        } catch {
            networkName = "sepolia";
        }

        // Fetch the mode from the env to determine if we are running a local fork
        string memory mode;
        try vm.envString("MODE") returns (string memory envMode) {
            mode = envMode;
        } catch {}

        // Load deployment addresses
        _setFilename(networkName);
        address marketFactoryAddr = readAddress("marketFactory");
        IMarketFactory marketFactory = IMarketFactory(marketFactoryAddr);
        console.log("Market Factory loaded: ", marketFactoryAddr);

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
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            universalRouterAddr = EthSepoliaConstants.UNIVERSAL_ROUTER;
            poolManagerAddr = EthSepoliaConstants.POOL_MANAGER;
            permit2Addr = EthSepoliaConstants.PERMIT2;
        } else {
            revert("Unsupported network");
        }

        router = IUniversalRouter(payable(universalRouterAddr));
        console.log("Universal Router loaded");

        poolManager = IPoolManager(poolManagerAddr);
        console.log("Pool Manager loaded");

        permit2 = IPermit2(permit2Addr);
        console.log("Permit2 loaded");

        console.log("Proxy Hook loaded");

        // if MODE="local" then do not load core pool id from env variable
        // the address is hardcoded in the script solidity/make/exp.mk:111
        // and it is overriding the core pool id and thus the proxy pool id
        // for a newly created market
        bool isLocalFork = keccak256(bytes(mode)) == keccak256(bytes("LOCAL"));
        if (!isLocalFork) {
            try vm.envString("CORE_POOL_ID") returns (string memory envCorePoolId) {
                console.log("CORE_POOL_ID loaded from env: ", envCorePoolId);
                corePoolId = envCorePoolId;
                _corePoolId = PoolId.wrap(bytes32(bytes(corePoolId)));
            } catch {}
        } else {
            console.log("is running local fork, skipping core pool id loading from env...");
        }

        bool isSepolia = keccak256(bytes(networkName)) == keccak256(bytes("sepolia"));

        uint24 fee = 0;
        // if core pool key is set locally then load it into fee variable
        // because core pool fee is not always 0
        try vm.envUint("CORE_POOL_FEE") returns (uint256 envFee) {
            fee = uint24(envFee);
            console.log("Pool fee loaded from env:", fee);
        } catch {}
        int24 tickSpacing;

        if (bytes(corePoolId).length == 0) {
            if (isSepolia) {
                token0 = readAddress("usdcToken");
                console.log("Token0 (USDC) loaded from defaults: ", token0);
                token1 = readAddress("usdtToken");
                console.log("Token1 (USDT) loaded from defaults: ", token1);
            } else {
                revert("CORE_POOL_ID required for non-sepolia networks");
            }
            // fee = 0;
            console.log("Pool fee (default):", fee);
            tickSpacing = 60;
            console.log("Tick spacing (default):", tickSpacing);
        } else {
            string memory filePath = string.concat("./deployments/", networkName, "_markets_deployments.json");
            string memory json = vm.readFile(filePath);

            string memory keyToken0 = string.concat(".", corePoolId, "_underlyingAsset0");
            string memory keyToken1 = string.concat(".", corePoolId, "_underlyingAsset1");
            string memory keyFee = string.concat(".", corePoolId, "_corePoolFee");
            string memory keyTS = string.concat(".", corePoolId, "_tickSpacing");

            token0 = vm.parseJsonAddress(json, keyToken0);
            console.log("Token0 loaded from markets json: ", token0);
            token1 = vm.parseJsonAddress(json, keyToken1);
            console.log("Token1 loaded from markets json: ", token1);

            uint256 jsonFee = vm.parseJsonUint(json, keyFee);
            fee = uint24(jsonFee);
            console.log("Pool fee loaded:", fee);

            uint256 jsonTS = vm.parseJsonUint(json, keyTS);
            tickSpacing = int24(uint24(jsonTS));
            console.log("Tick spacing loaded:", tickSpacing);
        }

        address coreHookAddr = marketFactory.getCoreHook();
        console.log("Core Hook loaded");
        lccToken0 = marketFactory.getLCC(token0);
        lccToken1 = marketFactory.getLCC(token1);
        console.log("LCC Tokens loaded");
        console.log("lccToken0: ", lccToken0);
        console.log("lccToken1: ", lccToken1);
        console.log("token0: ", token0);
        (Currency currencyLccA, Currency currencyLccB) = CurrencySortHelper.sortAddresses(lccToken0, lccToken1);
        corePoolKey = PoolKey({
            currency0: currencyLccA,
            currency1: currencyLccB,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: IHooks(coreHookAddr)
        });
        console.log("Currency0: ", Currency.unwrap(corePoolKey.currency0));
        console.log("Currency1: ", Currency.unwrap(corePoolKey.currency1));
        console.log("Fee: ", corePoolKey.fee);
        console.log("Tick Spacing: ", corePoolKey.tickSpacing);
        console.log("Hooks: ", address(corePoolKey.hooks));

        console.log("Core PoolKey constructed");
        console.log("Core PoolKey toId: ");
        console.logBytes32(PoolId.unwrap(corePoolKey.toId()));

        PoolId proxyPoolId = marketFactory.coreToProxy(corePoolKey.toId());
        hook = IHooks(marketFactory.proxyToHook(proxyPoolId));
        console.log("Proxy Hook loaded");
        console.log("Proxy Hook Address: ", address(hook));

        if (bytes(corePoolId).length == 0) {
            _corePoolId = corePoolKey.toId();
        }

        uint256 userPrivateKey = uint256(vm.envBytes32("LP_PRIVATE_KEY"));
        address userAddress = vm.addr(userPrivateKey);
        (Currency currencyA, Currency currencyB) = CurrencySortHelper.sortAddresses(token0, token1);
        console.log("Proxy Currency 0 Address: ", Currency.unwrap(currencyA));
        console.log("Proxy Currency 0 Name: ", IERC20Metadata(Currency.unwrap(currencyA)).name());
        console.log("Proxy Currency 1 Address: ", Currency.unwrap(currencyB));
        console.log("Proxy Currency 1 Name: ", IERC20Metadata(Currency.unwrap(currencyB)).name());
        uint24 proxyFee = 0;
        PoolKey memory poolKey =
            PoolKey({currency0: currencyA, currency1: currencyB, fee: proxyFee, tickSpacing: tickSpacing, hooks: hook});
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

        uint8 swapType;
        try vm.envUint("SWAP_TYPE") returns (uint256 envSwapType) {
            swapType = uint8(envSwapType);
        } catch {
            swapType = 0;
        }

        if (swapType < 0 || swapType > 5) {
            revert("Invalid swap type");
        }

        uint128 amount;

        if (swapType == 0 || swapType == 1 || swapType == 5) {
            try vm.envUint("AMOUNT") returns (uint256 envAmount) {
                amount = uint128(envAmount);
            } catch {
                amount = 10e18;
            }
            console.log("\n\nExecuting Exact Input swap for Token 0 -> Token 1 with amount:", amount);

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

            console.log("Exact Input Token 0 -> Token 1 Swap executed");
        }
        if (swapType == 2 || swapType == 5) {
            try vm.envUint("AMOUNT") returns (uint256 envAmount) {
                amount = uint128(envAmount);
            } catch {
                amount = 10e18 / 2;
            }
            console.log("\n\nExecuting Exact Input swap for Token 1 -> Token 0...");

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
            try vm.envUint("AMOUNT") returns (uint256 envAmount) {
                amount = uint128(envAmount);
            } catch {
                amount = 10e18;
            }
            console.log("\n\nExecuting Exact Output swap for Token 0 -> Token 1...");

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
            try vm.envUint("AMOUNT") returns (uint256 envAmount) {
                amount = uint128(envAmount);
            } catch {
                amount = 10e18 / 2;
            }
            console.log("\n\nExecuting Exact Output swap for Token 1 -> Token 0...");

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
        (uint160 sqrtPriceX96Before, int24 tickBefore,,) = poolManager.getSlot0(_corePoolId);
        uint128 liquidityBefore = poolManager.getLiquidity(_corePoolId);
        uint256 uaSupply0Before = LiquidityCommitmentCertificate(lccToken0).uaSupply();
        uint256 uaSupply1Before = LiquidityCommitmentCertificate(lccToken1).uaSupply();
        console.log("Before Swap (Exact Input Single):");
        console.log("Core Pool - sqrtPriceX96: %s", sqrtPriceX96Before);
        console.log("Core Pool - tick: %d", tickBefore);
        console.log("Core Pool - liquidity: %s", liquidityBefore);
        console.log("LCC - uaSupply0: %s", uaSupply0Before);
        console.log("LCC - uaSupply1: %s", uaSupply1Before);

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
        uint256 deadline = block.timestamp + 300;
        router.execute(commands, inputs, deadline);

        // Log after
        (uint160 sqrtPriceX96After, int24 tickAfter,,) = poolManager.getSlot0(_corePoolId);
        uint128 liquidityAfter = poolManager.getLiquidity(_corePoolId);
        uint256 uaSupply0After = LiquidityCommitmentCertificate(lccToken0).uaSupply();
        uint256 uaSupply1After = LiquidityCommitmentCertificate(lccToken1).uaSupply();
        console.log("After Swap (Exact Input Single):");
        console.log("Core Pool - sqrtPriceX96: %s", sqrtPriceX96After);
        console.log("Core Pool - tick: %d", tickAfter);
        console.log("Core Pool - liquidity: %s", liquidityAfter);
        console.log("LCC - uaSupply0: %s", uaSupply0After);
        console.log("LCC - uaSupply1: %s", uaSupply1After);
        console.log("Deltas:");
        console.log("Core Pool - tick delta: %d", tickAfter - tickBefore);
        console.log("liquidity delta: %d", int128(liquidityAfter) - int128(liquidityBefore));
        console.log("LCC - uaSupply0 delta: %d", int256(uaSupply0After) - int256(uaSupply0Before));
        console.log("uaSupply1 delta: %d", int256(uaSupply1After) - int256(uaSupply1Before));
    }

    function swapExactOutputSingle(IV4Router.ExactOutputSingleParams memory params) public {
        (uint160 sqrtPriceX96Before, int24 tickBefore,,) = poolManager.getSlot0(_corePoolId);
        uint128 liquidityBefore = poolManager.getLiquidity(_corePoolId);
        uint256 uaSupply0Before = LiquidityCommitmentCertificate(lccToken0).uaSupply();
        uint256 uaSupply1Before = LiquidityCommitmentCertificate(lccToken1).uaSupply();
        console.log("Before Swap (Exact Output Single):");
        console.log("Core Pool - sqrtPriceX96: %s", sqrtPriceX96Before);
        console.log("Core Pool - tick: %d", tickBefore);
        console.log("Core Pool - liquidity: %s", liquidityBefore);
        console.log("LCC - uaSupply0: %s", uaSupply0Before);
        console.log("LCC - uaSupply1: %s", uaSupply1Before);

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
        uint256 deadline = block.timestamp + 300;
        router.execute(commands, inputs, deadline);

        // Log after
        (uint160 sqrtPriceX96After, int24 tickAfter,,) = poolManager.getSlot0(_corePoolId);
        uint128 liquidityAfter = poolManager.getLiquidity(_corePoolId);
        uint256 uaSupply0After = LiquidityCommitmentCertificate(lccToken0).uaSupply();
        uint256 uaSupply1After = LiquidityCommitmentCertificate(lccToken1).uaSupply();
        console.log("After Swap (Exact Output Single):");
        console.log("Core Pool - sqrtPriceX96: %s", sqrtPriceX96After);
        console.log("Core Pool - tick: %d", tickAfter);
        console.log("Core Pool - liquidity: %s", liquidityAfter);
        console.log("LCC - uaSupply0: %s", uaSupply0After);
        console.log("LCC - uaSupply1: %s", uaSupply1After);
        console.log("Deltas:");
        console.log("Core Pool - tick delta: %d", tickAfter - tickBefore);
        console.log("liquidity delta: %d", int128(liquidityAfter) - int128(liquidityBefore));
        console.log("LCC - uaSupply0 delta: %d", int256(uaSupply0After) - int256(uaSupply0Before));
        console.log("uaSupply1 delta: %d", int256(uaSupply1After) - int256(uaSupply1Before));
    }
}
