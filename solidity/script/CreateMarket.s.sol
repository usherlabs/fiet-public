// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "forge-std/Script.sol";
import {MarketFactory} from "../src/MarketFactory.sol";
import {SepoliaConstants} from "./constants/Sepolia.sol";
import {ScriptHelper} from "./libraries/ScriptHelper.s.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySortHelper} from "./libraries/CurrencySortHelper.sol";

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

    // Created market details
    PoolId public corePoolId;
    PoolId public proxyPoolId;

    function run() external {
        uint256 deployerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));

        console.log("Starting market creation via Market Factory...");

        // Load deployment addresses
        _loadDeploymentAddresses();

        // Set market parameters
        _setMarketParameters();

        // Validate parameters
        _validateParameters();

        console.log("\n=== Market Creation Parameters ===");
        console.log("Market Factory:", marketFactory);
        console.log("Underlying Asset 0:", underlyingAsset0);
        console.log("Underlying Asset 1:", underlyingAsset1);
        console.log("Core Pool Fee:", corePoolFee);
        console.log("Tick Spacing:", tickSpacing);
        console.log("Initial Sqrt Price X96:", initialSqrtPriceX96);

        vm.startBroadcast(deployerPrivateKey);

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
        _setFilename("sepolia");

        marketFactory = readAddress("marketFactory");
        console.log("MarketFactory address loaded:", marketFactory);
    }

    /**
     * @dev Sets market parameters from environment variables or uses defaults
     */
    function _setMarketParameters() internal {
        // Try to read from environment variables, otherwise use defaults
        try vm.envAddress("UNDERLYING_ASSET_0") returns (address asset0) {
            underlyingAsset0 = asset0;
        } catch {
            underlyingAsset0 = readAddress("usdtToken");
        }

        try vm.envAddress("UNDERLYING_ASSET_1") returns (address asset1) {
            underlyingAsset1 = asset1;
        } catch {
            underlyingAsset1 = readAddress("usdcToken");
        }

        (Currency currency0, Currency currency1) = CurrencySortHelper
            .sortAddresses(underlyingAsset0, underlyingAsset1);

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

        try vm.envUint("INITIAL_SQRT_PRICE_X96") returns (uint256 price) {
            initialSqrtPriceX96 = uint160(price);
        } catch {
            // Default to 1:1 price ratio (sqrt(1) * 2^96)
            initialSqrtPriceX96 = 79228162514264337593543950336;
        }
    }

    /**
     * @dev Validates market creation parameters
     */
    function _validateParameters() internal view {
        require(marketFactory != address(0), "MarketFactory address is zero");
        require(underlyingAsset0 != address(0), "Underlying asset 0 is zero");
        require(underlyingAsset1 != address(0), "Underlying asset 1 is zero");
        require(
            underlyingAsset0 != underlyingAsset1,
            "Assets must be different"
        );
        require(
            corePoolFee >= 0,
            "Core pool fee must be greater than or equal to 0"
        );
        require(tickSpacing > 0, "Tick spacing must be greater than 0");
        require(
            initialSqrtPriceX96 > 0,
            "Initial price must be greater than 0"
        );

        console.log("Market parameters validated");
    }

    /**
     * @dev Creates the market via MarketFactory
     */
    function _createMarket() internal {
        MarketFactory factory = MarketFactory(marketFactory);

        // Call createMarket function
        (PoolId coreId, PoolId proxyId) = factory.createMarket(
            underlyingAsset0,
            underlyingAsset1,
            corePoolFee,
            tickSpacing,
            initialSqrtPriceX96
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
        console.log(
            "Core Pool ID:",
            string.concat("", vm.toString(PoolId.unwrap(corePoolId)))
        );
        console.log(
            "Proxy Pool ID:",
            string.concat("0x", vm.toString(PoolId.unwrap(proxyPoolId)))
        );

        // Get LCC tokens
        MarketFactory factory = MarketFactory(marketFactory);
        address lccTokenOfAsset0 = factory.getLCC(underlyingAsset0);
        address lccTokenOfAsset1 = factory.getLCC(underlyingAsset1);

        console.log("LCC Token 0:", lccTokenOfAsset0);
        console.log("LCC Token 1:", lccTokenOfAsset1);

        // Verify pool relationships
        PoolId storedProxyId = factory.coreToProxy(corePoolId);

        require(
            PoolId.unwrap(storedProxyId) == PoolId.unwrap(proxyPoolId),
            "Core to proxy mapping mismatch"
        );

        console.log("Pool relationships verified");
    }

    /**
     * @dev Writes market details to JSON file for future reference
     */
    function _writeMarketDetails() internal {
        _setFilename("sepolia_markets");

        // Create a unique market identifier
        string memory marketId = string.concat(
            vm.toString(Currency.unwrap(underlyingCurrency0)),
            "_",
            vm.toString(Currency.unwrap(underlyingCurrency1)),
            "_",
            vm.toString(corePoolFee)
        );

        writeString(
            string.concat(marketId, "_corePoolId"),
            vm.toString(PoolId.unwrap(corePoolId))
        );
        writeString(
            string.concat(marketId, "_proxyPoolId"),
            vm.toString(PoolId.unwrap(proxyPoolId))
        );
        writeString(
            string.concat(marketId, "_underlyingAsset0"),
            vm.toString(Currency.unwrap(underlyingCurrency0))
        );
        writeString(
            string.concat(marketId, "_underlyingAsset1"),
            vm.toString(Currency.unwrap(underlyingCurrency1))
        );
        writeString(
            string.concat(marketId, "_corePoolFee"),
            vm.toString(corePoolFee)
        );
        writeString(
            string.concat(marketId, "_tickSpacing"),
            vm.toString(tickSpacing)
        );
        writeString(
            string.concat(marketId, "_initialSqrtPriceX96"),
            vm.toString(initialSqrtPriceX96)
        );

        console.log(
            "Market details written to script/deployments/sepolia_markets_deployments.json"
        );
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

        require(
            PoolId.unwrap(storedProxyId) == PoolId.unwrap(proxyPoolId),
            "Core to proxy mapping mismatch"
        );

        console.log("Pool relationships verified");

        // Verify LCC tokens exist
        address lccToken0 = factory.getLCC(
            Currency.unwrap(underlyingCurrency0)
        );
        address lccToken1 = factory.getLCC(
            Currency.unwrap(underlyingCurrency1)
        );

        require(lccToken0 != address(0), "LCC token 0 not found");
        require(lccToken1 != address(0), "LCC token 1 not found");

        console.log("LCC tokens verified");

        // Verify underlying assets
        require(
            factory.getUnderlyingAsset(lccToken0) ==
                Currency.unwrap(underlyingCurrency0),
            "LCC token 0 underlying mismatch"
        );
        require(
            factory.getUnderlyingAsset(lccToken1) ==
                Currency.unwrap(underlyingCurrency1),
            "LCC token 1 underlying mismatch"
        );

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
        console.log("Core Pool Fee:", corePoolFee);
        console.log("Tick Spacing:", tickSpacing);
        console.log("Initial Sqrt Price X96:", initialSqrtPriceX96);

        (Currency currency0, Currency currency1) = CurrencySortHelper
            .sortAddresses(
                address(underlyingAsset0),
                address(underlyingAsset1)
            );
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
}
