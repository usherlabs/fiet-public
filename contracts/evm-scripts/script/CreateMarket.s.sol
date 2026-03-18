// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import "forge-std/Script.sol";
import {MarketFactory} from "src/MarketFactory.sol";
import {NetworkConfig} from "./base/NetworkConfig.sol";
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ProxyHook} from "src/ProxyHook.sol";
import {HookFlags} from "src/libraries/HookFlags.sol";
import {ILiquidityHub} from "src/interfaces/ILiquidityHub.sol";
import {GlobalConfig} from "src/GlobalConfig.sol";
import {MarketVTSConfiguration} from "src/types/VTS.sol";
import {VTSConfigFileBase} from "./base/VTSConfigFileBase.sol";

/**
 * @title CreateMarketScript
 * @notice Script to create a new market via the Market Factory
 * @dev Creates both core and proxy pools with LCC tokens and underlying assets
 *
 * Env vars
 * - REQUIRED:
 *   - `PRIVATE_KEY`: Deployer key (must be authorised to call `MarketFactory.createMarket`)
 * - OPTIONAL (network + assets):
 *   - `NETWORK`: e.g. `sepolia`, `arbitrum`, `ethsepolia` (defaults come from `NetworkConfig`)
 *   - `UNDERLYING_ASSET_0`, `UNDERLYING_ASSET_1`: underlying token addresses (some dev networks have fallbacks)
 *   - `CORE_POOL_FEE`: default `0`
 *   - `TICK_SPACING`: default `60`
 * - OPTIONAL (initial price; pick one strategy):
 *   - `INITIAL_SQRT_PRICE_X96`: exact uint160 sqrt price for the **core** pool
 *   - `REFERENCE_POOL_ID`: bytes32 pool id to copy `sqrtPriceX96` from (with optional inversion controls below)
 *   - `ASSET0_PRICE` + `ASSET1_PRICE`: integer prices for the two underlyings (see `PRICE_DECIMALS`)
 *     - `PRICE_DECIMALS`: default `6`
 * - OPTIONAL (reference pool inversion controls):
 *   - `REFERENCE_POOL_CURRENCY0`, `REFERENCE_POOL_CURRENCY1`: explicit reference-pool token order; if swapped vs
 *     `UNDERLYING_ASSET_0/1` the script will invert the reference `sqrtPriceX96`
 *   - `REFERENCE_POOL_INVERT`: set to `1` to force inversion when you cannot (or do not want to) provide ref order
 * - REQUIRED (VTS configuration):
 *   - `VTS_CONFIG_FILE_PATH`: JSON/TOML path to a fully-specified VTS config file
 *
 * Market Creation Process:
 * 1. Read deployed MarketFactory address from deployment file
 * 2. Validate market parameters
 * 3. Create market with core and proxy pools
 * 4. Log market details and pool IDs
 */
contract CreateMarketScript is NetworkConfig, VTSConfigFileBase {
    using PoolIdLibrary for PoolId;
    using StateLibrary for IPoolManager;

    // Market parameters - can be configured via environment variables
    address public underlyingAsset0;
    address public underlyingAsset1;
    Currency public underlyingCurrency0;
    Currency public underlyingCurrency1;
    uint24 public corePoolFee;
    int24 public tickSpacing;
    uint160 public initialSqrtPriceX96;

    // Deployed contract addresses
    address public marketFactory;
    address public globalConfig;
    address public coreHook;
    address public liquidityHub;

    // Created market details
    PoolId public corePoolId;
    PoolId public proxyPoolId;

    function _invertSqrtPriceX96(uint160 sqrtPriceX96) internal pure returns (uint160) {
        require(sqrtPriceX96 != 0, "sqrtPriceX96 is 0");
        return uint160((uint256(1) << 192) / sqrtPriceX96);
    }

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        // Initialise network configuration
        _initNetwork();

        console.log("Starting market creation via Market Factory...");

        // Load deployment addresses
        _loadDeploymentAddresses();

        vm.startBroadcast(deployerPrivateKey);

        // Set market parameters
        _setMarketParameters();

        console.log("\n=== Market Creation Parameters ===");
        console.log("GlobalConfig:", globalConfig);
        console.log("Market Factory:", marketFactory);
        console.log("CoreHook:", coreHook);
        console.log("Underlying Asset 0:", underlyingAsset0);
        console.log("Underlying Asset 1:", underlyingAsset1);
        console.log("Core Pool Fee:", corePoolFee);
        console.log("Tick Spacing:", tickSpacing);
        console.log("Initial Sqrt Price X96:", initialSqrtPriceX96);

        // Validate parameters
        _validateParameters();

        (MarketVTSConfiguration memory vtsCfg, string memory vtsCfgSource) = _loadVTSConfig();
        console.log("VTS_CONFIG_SOURCE:", vtsCfgSource);

        // Create the market
        console.log("\n=== Creating Market ===");
        _createMarket(vtsCfg);

        vm.stopBroadcast();

        // Log results
        _logMarketDetails();

        // Write market details to file
        _writeMarketDetails();

        console.log("\n=== Market Creation Complete ===");
    }

    /**
     * @dev Loads deployed contract addresses from deployment file
     */
    function _loadDeploymentAddresses() internal {
        marketFactory = readAddress("marketFactory");
        globalConfig = readAddress("globalConfig");
        coreHook = readAddress("coreHook");
        liquidityHub = readAddress("liquidityHub");
        console.log("MarketFactory address loaded:", marketFactory);
        console.log("PoolManager address loaded:", config.poolManager);
        console.log("LiquidityHub address loaded:", liquidityHub);
    }

    /**
     * @dev Sets market parameters from environment variables or uses defaults
     */
    function _setMarketParameters() internal {
        // Try to read from environment variables, otherwise use defaults
        try vm.envAddress("UNDERLYING_ASSET_0") returns (address asset0) {
            console.log("UNDERLYING_ASSET_0:", asset0);
            underlyingAsset0 = asset0;
        } catch {
            if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
                underlyingAsset0 = readAddress("usdtToken");
            } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
                underlyingAsset0 = EthSepoliaConstants.USDC_ADDRESS;
            } else {
                revert("Please specify UNDERLYING_ASSET_0 via environment variable for this network");
            }
        }

        try vm.envAddress("UNDERLYING_ASSET_1") returns (address asset1) {
            console.log("UNDERLYING_ASSET_1:", asset1);
            underlyingAsset1 = asset1;
        } catch {
            if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
                underlyingAsset1 = readAddress("usdcToken");
            } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
                // Query WETH9 from PositionManager instead of using constant
                underlyingAsset1 = address(PositionManager(payable(config.positionManager)).WETH9());
            } else {
                revert("Please specify UNDERLYING_ASSET_1 via environment variable for this network");
            }
        }

        (Currency currency0, Currency currency1) = CurrencySortHelper.sortAddresses(underlyingAsset0, underlyingAsset1);

        underlyingCurrency0 = currency0;
        underlyingCurrency1 = currency1;

        underlyingAsset0 = Currency.unwrap(underlyingCurrency0);
        underlyingAsset1 = Currency.unwrap(underlyingCurrency1);

        try vm.envUint("CORE_POOL_FEE") returns (uint256 fee) {
            corePoolFee = uint24(fee);
        } catch {
            // Default to 0.3% fee (3000)
            // corePoolFee = 3000;
            corePoolFee = 0;
        }

        try vm.envUint("TICK_SPACING") returns (uint256 spacing) {
            tickSpacing = int24(uint24(spacing));
        } catch {
            // Default tick spacing for 0.3% fee
            tickSpacing = 60;
        }

        string memory referencePoolIdStr = vm.envOr("REFERENCE_POOL_ID", string(""));
        try vm.envUint("INITIAL_SQRT_PRICE_X96") returns (uint256 price) {
            initialSqrtPriceX96 = uint160(price);
        } catch {
            // Note: LCC tokens are created when markets are created, so we can't get them beforehand
            // For price calculation, we'll use the underlying assets directly
            // The market creation will handle LCC token creation automatically

            if (bytes(referencePoolIdStr).length > 0) {
                console.log("Using reference pool %s for initial price", referencePoolIdStr);

                bytes32 poolIdBytes = vm.parseBytes32(referencePoolIdStr);
                PoolId referencePoolId = PoolId.wrap(poolIdBytes);

                IPoolManager manager = IPoolManager(config.poolManager);

                (uint160 sqrtPrice,,,) = manager.getSlot0(referencePoolId);

                // If the reference pool's (currency0,currency1) ordering is known and differs from the market's
                // sorted underlying ordering, invert the reference sqrtPrice so it matches this script's
                // (underlyingAsset0, underlyingAsset1) semantics.
                bool shouldInvertReference;
                bool hasRefOrder;
                try vm.envAddress("REFERENCE_POOL_CURRENCY0") returns (address ref0) {
                    address ref1 = vm.envAddress("REFERENCE_POOL_CURRENCY1");
                    hasRefOrder = true;
                    if (ref0 == underlyingAsset0 && ref1 == underlyingAsset1) {
                        shouldInvertReference = false;
                    } else if (ref0 == underlyingAsset1 && ref1 == underlyingAsset0) {
                        shouldInvertReference = true;
                    } else {
                        revert("REFERENCE_POOL_CURRENCY0/1 do not match UNDERLYING_ASSET_0/1");
                    }
                } catch {
                    hasRefOrder = false;
                }

                if (!hasRefOrder) {
                    shouldInvertReference = vm.envOr("REFERENCE_POOL_INVERT", uint256(0)) == 1;
                }

                if (shouldInvertReference) {
                    sqrtPrice = _invertSqrtPriceX96(sqrtPrice);
                    console.log("Inverted reference sqrt price to match underlying ordering");
                }

                // For price calculation, we assume underlying assets are already sorted
                // LCC tokens will be sorted the same way when created
                uint8 dec0 = IERC20Metadata(underlyingAsset0).decimals();
                uint8 dec1 = IERC20Metadata(underlyingAsset1).decimals();

                int8 decDiff = int8(dec1) - int8(dec0);
                if (decDiff != 0) {
                    int256 absDiff = decDiff >= 0 ? int256(decDiff) : -int256(decDiff);
                    uint160 sqrtScale = uint160(TickMath.getSqrtPriceAtTick(int24(absDiff / 2)));
                    if (absDiff % 2 != 0) {
                        sqrtScale = uint160(FullMath.mulDiv(sqrtScale, TickMath.getSqrtPriceAtTick(1), 1 << 96));
                    }
                    if (decDiff > 0) {
                        sqrtPrice = uint160(FullMath.mulDiv(sqrtPrice, sqrtScale, 1 << 96));
                    } else {
                        sqrtPrice = uint160(FullMath.mulDiv(sqrtPrice, 1 << 96, sqrtScale));
                    }
                }

                initialSqrtPriceX96 = sqrtPrice;

                // IMPORTANT: Core pool ordering is based on sorted LCC token addresses, which may NOT align with
                // sorted underlying addresses. Since LiquidityHub creates the LCC pair with sequential CREATEs,
                // we can predict the two LCC addresses from LiquidityHub's nonce and flip the price if needed.
                //
                // This makes the core pool initialise at the same *economic* price as the reference pool, even when
                // `lccToken0/lccToken1` ordering differs from `underlyingAsset0/underlyingAsset1`.
                uint64 hubNonce = vm.getNonce(liquidityHub);
                address predictedLcc0 = vm.computeCreateAddress(liquidityHub, uint256(hubNonce));
                address predictedLcc1 = vm.computeCreateAddress(liquidityHub, uint256(hubNonce) + 1);
                console.log("Predicted LCC(underlyingAsset0) address:", predictedLcc0);
                console.log("Predicted LCC(underlyingAsset1) address:", predictedLcc1);
                if (predictedLcc0 > predictedLcc1) {
                    initialSqrtPriceX96 = _invertSqrtPriceX96(initialSqrtPriceX96);
                    console.log("Inverted initial sqrt price to match core/LCC ordering");
                }

                console.log("Adjusted initial sqrt price: %s", vm.toString(initialSqrtPriceX96));
            } else {
                bool hasAsset0Price = vm.envExists("ASSET0_PRICE");
                bool hasAsset1Price = vm.envExists("ASSET1_PRICE");
                if (hasAsset0Price && hasAsset1Price) {
                    uint256 asset0Price = vm.envUint("ASSET0_PRICE");
                    uint256 asset1Price = vm.envUint("ASSET1_PRICE");

                    uint8 priceDecimals = uint8(vm.envOr("PRICE_DECIMALS", uint256(6)));

                    // Scale prices to 18 decimals
                    asset0Price = asset0Price * (10 ** (18 - priceDecimals));
                    asset1Price = asset1Price * (10 ** (18 - priceDecimals));

                    uint8 dec0 = IERC20Metadata(underlyingAsset0).decimals();
                    uint8 dec1 = IERC20Metadata(underlyingAsset1).decimals();

                    // Assets are already sorted by CurrencySortHelper earlier in the function
                    // LCC tokens will maintain the same order when created
                    bool isAsset0Core0 = (underlyingAsset0 < underlyingAsset1);

                    uint256 price;
                    if (isAsset0Core0) {
                        price = FullMath.mulDiv(asset0Price, 10 ** dec1, asset1Price) * (10 ** (18 - dec0));
                    } else {
                        price = FullMath.mulDiv(asset1Price, 10 ** dec0, asset0Price) * (10 ** (18 - dec1));
                    }

                    uint256 sqrtPrice = _sqrt(price);
                    initialSqrtPriceX96 = uint160(FullMath.mulDiv(sqrtPrice, 1 << 96, 10 ** 9)); // Since sqrt(price) * 10^9 for 18-decimal price

                    // Apply the same predicted-LCC ordering adjustment as the reference-pool path, so manual price
                    // inputs are also mapped correctly to core/LCC ordering.
                    uint64 hubNonce = vm.getNonce(liquidityHub);
                    address predictedLcc0 = vm.computeCreateAddress(liquidityHub, uint256(hubNonce));
                    address predictedLcc1 = vm.computeCreateAddress(liquidityHub, uint256(hubNonce) + 1);
                    if (predictedLcc0 > predictedLcc1) {
                        initialSqrtPriceX96 = _invertSqrtPriceX96(initialSqrtPriceX96);
                        console.log("Inverted derived initial sqrt price to match core/LCC ordering");
                    }

                    console.log("Derived initial sqrt price: %s", vm.toString(initialSqrtPriceX96));
                } else {
                    // Default to 1:1 price ratio (sqrt(1) * 2^96)
                    initialSqrtPriceX96 = 79228162514264337593543950336;
                }
            }
        }
    }

    /**
     * @dev Validates market creation parameters
     */
    function _validateParameters() internal view {
        require(marketFactory != address(0), "MarketFactory address is zero");
        require(globalConfig != address(0), "GlobalConfig address is zero");
        require(coreHook != address(0), "CoreHook address is zero");
        require(underlyingAsset0 != address(0), "Underlying asset 0 is zero");
        require(underlyingAsset1 != address(0), "Underlying asset 1 is zero");
        require(underlyingAsset0 != underlyingAsset1, "Assets must be different");
        require(corePoolFee >= 0, "Core pool fee must be greater than or equal to 0");
        require(tickSpacing > 0, "Tick spacing must be greater than 0");
        require(initialSqrtPriceX96 > 0, "Initial price must be greater than 0");

        console.log("Market parameters validated");
    }

    /**
     * @dev Creates the market via MarketFactory
     */
    function _createMarket(MarketVTSConfiguration memory vtsCfg) internal {
        MarketFactory factory = MarketFactory(marketFactory);
        address deployer = MarketFactory(marketFactory).marketVaultDeployer();
        require(factory.isInitialised(), "MarketFactory not initialised; deploy with bounds first");

        bytes memory constructorArgs = abi.encode(config.poolManager, marketFactory);

        (bytes32 salt,) = _generateProxyHookAddress(deployer, constructorArgs);

        // MarketFactory.createMarket is `onlyOwner` and MarketFactory owner is GlobalConfig (set during deployment),
        // so call it via GlobalConfig.proxyCall (where msg.sender == GlobalConfig).
        bytes memory result = GlobalConfig(globalConfig)
            .proxyCall(
                marketFactory,
                abi.encodeCall(
                    MarketFactory.createMarket,
                    (underlyingAsset0, underlyingAsset1, corePoolFee, tickSpacing, initialSqrtPriceX96, salt, vtsCfg)
                )
            );

        (bytes32 coreIdRaw, bytes32 proxyIdRaw) = abi.decode(result, (bytes32, bytes32));
        corePoolId = PoolId.wrap(coreIdRaw);
        proxyPoolId = PoolId.wrap(proxyIdRaw);

        console.log("Market created successfully");
    }

    /**
     * @dev Logs detailed market information
     */
    function _logMarketDetails() internal view {
        console.log("\n=== Market Details ===");
        console.log("Core Pool ID:", string.concat("", vm.toString(PoolId.unwrap(corePoolId))));
        console.log("Proxy Pool ID:", string.concat("", vm.toString(PoolId.unwrap(proxyPoolId))));

        // Canonical market LCC order is core pool key order (NOT the same as "of underlyingAsset0/1").
        // If you need the LCC derived from a specific underlying, ask the Hub for it.
        MarketFactory factory = MarketFactory(marketFactory);
        ILiquidityHub hub = factory.liquidityHub();
        bytes32 marketId = PoolId.unwrap(corePoolId);
        address lccOfUnderlying0 = hub.getLCC(marketId, underlyingAsset0);
        address lccOfUnderlying1 = hub.getLCC(marketId, underlyingAsset1);

        console.log("Underlying Asset 0:", underlyingAsset0);
        console.log("Underlying Asset 1:", underlyingAsset1);

        console.log("LCC of Underlying Asset 0:", lccOfUnderlying0);
        console.log("LCC of Underlying Asset 1:", lccOfUnderlying1);
        console.log("LCC of Underlying Asset 0 Symbol:", IERC20Metadata(lccOfUnderlying0).symbol());
        console.log("LCC of Underlying Asset 1 Symbol:", IERC20Metadata(lccOfUnderlying1).symbol());

        // Verify pool relationships
        PoolId storedProxyId = factory.coreToProxy(corePoolId);

        require(PoolId.unwrap(storedProxyId) == PoolId.unwrap(proxyPoolId), "Core to proxy mapping mismatch");

        console.log("Pool relationships verified");
    }

    /**
     * @dev Writes market details to JSON file for future reference
     */
    function _writeMarketDetails() internal {
        _setFilenameWithSuffix(networkName, "_markets");

        // Create a unique market identifier
        string memory marketId = vm.toString(PoolId.unwrap(corePoolId));

        // Store both:
        // - core-ordered LCC pair (canonical market lanes)
        // - underlying→LCC mapping for each underlying
        MarketFactory factoryInstance = MarketFactory(marketFactory);
        address[2] memory coreLccPair = factoryInstance.corePoolToCurrencyPair(corePoolId);
        ILiquidityHub hub = factoryInstance.liquidityHub();
        bytes32 marketIdBytes = PoolId.unwrap(corePoolId);
        address lccOfUnderlying0 = hub.getLCC(marketIdBytes, Currency.unwrap(underlyingCurrency0));
        address lccOfUnderlying1 = hub.getLCC(marketIdBytes, Currency.unwrap(underlyingCurrency1));

        writeString(string.concat(marketId, "_corePoolId"), vm.toString(PoolId.unwrap(corePoolId)));
        writeString(string.concat(marketId, "_proxyPoolId"), vm.toString(PoolId.unwrap(proxyPoolId)));
        writeString(string.concat(marketId, "_underlyingAsset0"), vm.toString(Currency.unwrap(underlyingCurrency0)));
        writeString(string.concat(marketId, "_underlyingAsset1"), vm.toString(Currency.unwrap(underlyingCurrency1)));
        writeString(string.concat(marketId, "_coreLcc0"), vm.toString(coreLccPair[0]));
        writeString(string.concat(marketId, "_coreLcc1"), vm.toString(coreLccPair[1]));
        writeString(string.concat(marketId, "_lccOfUnderlying0"), vm.toString(lccOfUnderlying0));
        writeString(string.concat(marketId, "_lccOfUnderlying1"), vm.toString(lccOfUnderlying1));
        writeString(string.concat(marketId, "_corePoolFee"), vm.toString(corePoolFee));
        writeString(string.concat(marketId, "_tickSpacing"), vm.toString(tickSpacing));
        writeString(string.concat(marketId, "_initialSqrtPriceX96"), vm.toString(initialSqrtPriceX96));

        console.log("Market details written to deployments/%s_deployments.json", _getFilename());
    }

    /**
     * @dev Verifies the created market
     * Can be called after market creation to ensure everything is set up correctly
     */
    function verifyMarket() external view {
        console.log("\n=== Verifying Market ===");

        MarketFactory factory = MarketFactory(marketFactory);

        // Verify pool relationships
        PoolId storedProxyId = factory.coreToProxy(corePoolId);

        require(PoolId.unwrap(storedProxyId) == PoolId.unwrap(proxyPoolId), "Core to proxy mapping mismatch");

        console.log("Pool relationships verified");

        // Verify LCC tokens exist via MarketFactory
        MarketFactory factoryInstance = MarketFactory(marketFactory);
        address[2] memory lccPair = factoryInstance.corePoolToCurrencyPair(corePoolId);
        address lccToken0 = lccPair[0];
        address lccToken1 = lccPair[1];

        require(lccToken0 != address(0), "LCC token 0 not found");
        require(lccToken1 != address(0), "LCC token 1 not found");

        console.log("LCC tokens verified");

        // Verify underlying assets via LiquidityHub
        ILiquidityHub hub = factoryInstance.liquidityHub();
        require(hub.getUnderlying(lccToken0) == Currency.unwrap(underlyingCurrency0), "LCC token 0 underlying mismatch");
        require(hub.getUnderlying(lccToken1) == Currency.unwrap(underlyingCurrency1), "LCC token 1 underlying mismatch");

        console.log("Underlying assets verified");
        console.log("Market verification complete!");
    }

    /**
     * @dev Creates a market with custom parameters
     * Useful for testing or creating markets with specific configurations
     */
    function createCustomMarket(
        address _underlyingAsset0,
        address _underlyingAsset1,
        uint24 _corePoolFee,
        int24 _tickSpacing,
        uint160 _initialSqrtPriceX96
    ) external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        // Initialise network configuration
        _initNetwork();

        // Load deployment addresses
        _loadDeploymentAddresses();

        // Set custom parameters
        underlyingAsset0 = _underlyingAsset0;
        underlyingAsset1 = _underlyingAsset1;
        corePoolFee = _corePoolFee;
        tickSpacing = _tickSpacing;
        initialSqrtPriceX96 = _initialSqrtPriceX96;

        // Validate parameters
        _validateParameters();

        console.log("\n=== Creating Custom Market ===");
        console.log("Underlying Asset 0:", underlyingAsset0);
        console.log("Underlying Asset 1:", underlyingAsset1);
        console.log("Underlying Asset 0 Symbol:", IERC20Metadata(underlyingAsset0).symbol());
        console.log("Underlying Asset 1 Symbol:", IERC20Metadata(underlyingAsset1).symbol());
        console.log("Core Pool Fee:", corePoolFee);
        console.log("Tick Spacing:", tickSpacing);
        console.log("Initial Sqrt Price X96:", initialSqrtPriceX96);

        (Currency currency0, Currency currency1) =
            CurrencySortHelper.sortAddresses(address(underlyingAsset0), address(underlyingAsset1));
        underlyingCurrency0 = currency0;
        underlyingCurrency1 = currency1;

        vm.startBroadcast(deployerPrivateKey);

        // Create the market
        (MarketVTSConfiguration memory vtsCfg,) = _loadVTSConfig();
        _createMarket(vtsCfg);

        vm.stopBroadcast();

        // Log results
        _logMarketDetails();

        console.log("\n=== Custom Market Creation Complete ===");
    }

    /**
     * @dev Custom square root function using Babylonian method for approximation.
     * This is a simplified version and might not be as accurate as BitMath.sqrt
     * for very large numbers or very small numbers.
     */
    function _sqrt(uint256 x) internal pure returns (uint256) {
        if (x == 0) return 0;
        uint256 z = (x + 1) / 2;
        uint256 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }

    /**
     * @dev Deploys ProxyHook using HookMiner to find correct address
     * @return The deployed ProxyHook address
     */
    function _generateProxyHookAddress(address deployer, bytes memory constructorArgs)
        internal
        view
        returns (bytes32, address)
    {
        // ProxyHook constructor takes (poolManager, marketFactory)
        // Now we pass the actual marketFactory address

        // Mine the correct address with proper flags
        (address hookAddress, bytes32 salt) =
            HookMiner.find(deployer, HookFlags.PROXY_HOOK_FLAGS, type(ProxyHook).creationCode, constructorArgs);

        console.log("ProxyHook will be deployed to:", hookAddress);
        console.log("ProxyHook salt:", vm.toString(salt));

        return (salt, address(hookAddress));
    }
}
