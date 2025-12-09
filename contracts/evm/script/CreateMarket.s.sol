// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {SepoliaConstants} from "./constants/ArbitrumSepolia.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {EthSepoliaConstants} from "./constants/EthSepolia.sol";
import {ArbitrumConstants} from "./constants/Arbitrum.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {BitMath} from "@uniswap/v4-core/src/libraries/BitMath.sol";
import {HookMiner} from "v4-periphery/src/utils/HookMiner.sol";
import {ProxyHook} from "../src/ProxyHook.sol";
import {VTSConfigs} from "../src/libraries/VTSConfigs.sol";
import {HookFlags} from "../src/libraries/HookFlags.sol";
import {ILiquidityHub} from "../src/interfaces/ILiquidityHub.sol";

/**
 * @title CreateMarketScript
 * @notice Script to create a new market via the Market Factory
 * @dev Creates both core and proxy pools with LCC tokens and underlying assets
 *
 * Market Creation Process:
 * 1. Read deployed MarketFactory address from deployment file
 * 2. Validate market parameters
 * 3. Create market with core and proxy pools
 * 4. Log market details and pool IDs
 */
contract CreateMarketScript is ScriptHelper {
    using PoolIdLibrary for PoolId;
    using StateLibrary for IPoolManager;

    string public networkName;

    // Market parameters - can be configured via environment variables
    address public underlyingAsset0;
    address public underlyingAsset1;
    Currency public underlyingCurrency0;
    Currency public underlyingCurrency1;
    uint24 public corePoolFee;
    int24 public tickSpacing;
    uint160 public initialSqrtPriceX96;

    address public poolManager;

    // Deployed contract addresses
    address public marketFactory;
    address public create2Deployer;
    address payable public positionManagerAddress;

    // Created market details
    PoolId public corePoolId;
    PoolId public proxyPoolId;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        networkName = vm.envString("NETWORK");

        console.log("Starting market creation via Market Factory...");

        // Load deployment addresses
        _loadDeploymentAddresses();

        console.log("\n=== Market Creation Parameters ===");
        console.log("Market Factory:", marketFactory);
        console.log("Underlying Asset 0:", underlyingAsset0);
        console.log("Underlying Asset 1:", underlyingAsset1);
        console.log("Core Pool Fee:", corePoolFee);
        console.log("Tick Spacing:", tickSpacing);
        console.log("Initial Sqrt Price X96:", initialSqrtPriceX96);

        vm.startBroadcast(deployerPrivateKey);

        // Set market parameters
        _setMarketParameters();

        // Validate parameters
        _validateParameters();

        // Create the market
        console.log("\n=== Creating Market ===");
        _createMarket();

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
        _setFilename(networkName);

        marketFactory = readAddress("marketFactory");
        console.log("MarketFactory address loaded:", marketFactory);

        if (keccak256(bytes(networkName)) == keccak256(bytes("arbitrum"))) {
            poolManager = ArbitrumConstants.POOL_MANAGER;
            create2Deployer = ArbitrumConstants.DEPLOYER_CREATE2;
            positionManagerAddress = payable(ArbitrumConstants.POSITION_MANAGER);
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("sepolia"))) {
            poolManager = SepoliaConstants.POOL_MANAGER;
            create2Deployer = SepoliaConstants.DEPLOYER_CREATE2;
            positionManagerAddress = payable(SepoliaConstants.POSITION_MANAGER);
        } else if (keccak256(bytes(networkName)) == keccak256(bytes("ethsepolia"))) {
            poolManager = EthSepoliaConstants.POOL_MANAGER;
            create2Deployer = EthSepoliaConstants.DEPLOYER_CREATE2;
            positionManagerAddress = payable(EthSepoliaConstants.POSITION_MANAGER);
        } else {
            revert("Unsupported network");
        }
        console.log("PoolManager address loaded:", poolManager);
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
                underlyingAsset1 = address(PositionManager(positionManagerAddress).WETH9());
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
            MarketFactory factory = MarketFactory(marketFactory);

            // Note: LCC tokens are created when markets are created, so we can't get them beforehand
            // For price calculation, we'll use the underlying assets directly
            // The market creation will handle LCC token creation automatically

            if (bytes(referencePoolIdStr).length > 0) {
                console.log("Using reference pool %s for initial price", referencePoolIdStr);

                bytes32 poolIdBytes = vm.parseBytes32(referencePoolIdStr);
                PoolId referencePoolId = PoolId.wrap(poolIdBytes);

                IPoolManager manager = IPoolManager(poolManager);

                (uint160 sqrtPrice,,,) = manager.getSlot0(referencePoolId);

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
    function _createMarket() internal {
        MarketFactory factory = MarketFactory(marketFactory);
        address deployer = MarketFactory(marketFactory).marketVaultDeployer();

        bytes memory constructorArgs = abi.encode(poolManager, marketFactory);

        (bytes32 salt,) = _generateProxyHookAddress(deployer, constructorArgs);

        // Call createMarket function
        (PoolId coreId, PoolId proxyId) = factory.createMarket(
            underlyingAsset0,
            underlyingAsset1,
            corePoolFee,
            tickSpacing,
            initialSqrtPriceX96,
            salt,
            VTSConfigs.getDefaultConfig()
        );

        corePoolId = coreId;
        proxyPoolId = proxyId;

        console.log("Market created successfully");
    }

    /**
     * @dev Logs detailed market information
     */
    function _logMarketDetails() internal view {
        console.log("\n=== Market Details ===");
        console.log("Core Pool ID:", string.concat("", vm.toString(PoolId.unwrap(corePoolId))));
        console.log("Proxy Pool ID:", string.concat("", vm.toString(PoolId.unwrap(proxyPoolId))));

        // Get LCC tokens from LiquidityHub via MarketFactory
        MarketFactory factory = MarketFactory(marketFactory);
        bytes32 marketId = PoolId.unwrap(corePoolId);
        address[2] memory lccPair = factory.corePoolToCurrencyPair(corePoolId);
        address lccTokenOfAsset0 = lccPair[0];
        address lccTokenOfAsset1 = lccPair[1];

        console.log("Underlying Asset 0:", underlyingAsset0);
        console.log("Underlying Asset 1:", underlyingAsset1);

        console.log("LCC Token of Asset 0:", lccTokenOfAsset0);
        console.log("LCC Token of Asset 1:", lccTokenOfAsset1);
        console.log("LCC Token of Asset 0 Symbol:", IERC20Metadata(lccTokenOfAsset0).symbol());
        console.log("LCC Token of Asset 1 Symbol:", IERC20Metadata(lccTokenOfAsset1).symbol());

        console.log("LCC Token of Asset 0 is Currency:", lccTokenOfAsset0 < lccTokenOfAsset1 ? "0" : "1");
        console.log("LCC Token of Asset 1 is Currency:", lccTokenOfAsset0 < lccTokenOfAsset1 ? "1" : "0");

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

        // Get LCC tokens from LiquidityHub via MarketFactory
        MarketFactory factory = MarketFactory(marketFactory);
        bytes32 marketIdBytes = PoolId.unwrap(corePoolId);
        address[2] memory lccPair = factory.corePoolToCurrencyPair(corePoolId);
        address lccTokenOfAsset0 = lccPair[0];
        address lccTokenOfAsset1 = lccPair[1];

        writeString(string.concat(marketId, "_corePoolId"), vm.toString(PoolId.unwrap(corePoolId)));
        writeString(string.concat(marketId, "_proxyPoolId"), vm.toString(PoolId.unwrap(proxyPoolId)));
        writeString(string.concat(marketId, "_underlyingAsset0"), vm.toString(Currency.unwrap(underlyingCurrency0)));
        writeString(string.concat(marketId, "_underlyingAsset1"), vm.toString(Currency.unwrap(underlyingCurrency1)));
        writeString(string.concat(marketId, "_lcc0"), vm.toString(lccTokenOfAsset0));
        writeString(string.concat(marketId, "_lcc1"), vm.toString(lccTokenOfAsset1));
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
        bytes32 marketIdBytes = PoolId.unwrap(corePoolId);
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
        _createMarket();

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
