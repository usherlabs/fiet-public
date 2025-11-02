// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";

/**
 * @title IMarketFactory
 * @notice Interface for MarketFactory contract
 * @dev Provides functions for fetching bounds and managing LCC tokens
 */
interface IMarketFactory {
    // ============ EVENTS ============

    event MarketCreated(
        PoolId indexed corePoolId,
        PoolId indexed proxyPoolId,
        address indexed underlyingAsset0,
        address underlyingAsset1,
        address lccToken0,
        address lccToken1,
        address coreHook,
        address proxyHook
    );

    event LCCCreated(address indexed underlyingAsset, address indexed lccToken);
    event BoundsUpdated(address[] bounds, bool added);

    // ============ ERRORS ============

    error CorePoolAlreadyExists();
    error ProxyPoolAlreadyExists();
    error InvalidHookAddress();
    error InvalidUnderlyingAsset();
    error InvalidIssuer();
    error InvalidBound();

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Gets the proxy hook address for a given core pool ID
     * @param corePoolId The core pool ID
     * @return The proxy hook address
     */
    function corePoolToProxyHook(PoolId corePoolId) external view returns (address);

    /**
     * @notice Gets the LCC token for a given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return The LCC token address
     */
    function getLCC(address underlyingAsset) external view returns (address);

    /**
     * @notice Gets the underlying asset for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlyingAsset(address lccToken) external view returns (address);

    /**
     * @notice Gets the proxy pool ID for a given core pool ID
     * @param corePoolId The core pool ID
     * @return The proxy pool ID
     */
    function coreToProxy(PoolId corePoolId) external view returns (PoolId);

    /**
     * @notice Checks if an address is a protocol bound
     * @param bound The address to check
     * @return True if the address is a protocol bound
     */
    function bounds(address bound) external view returns (bool);

    /**
     * @notice Gets the core hook address
     * @return The core hook address
     */
    function getCoreHook() external view returns (address);

    /**
     * @notice Gets the market maker position manager address
     * @return The market maker position manager address
     */
    function mmPositionManager() external view returns (address);

    // ============ STATE CHANGING FUNCTIONS ============

    /**
     * @notice Creates a new market with core and proxy pools
     * @param underlyingAsset0 First underlying asset address
     * @param underlyingAsset1 Second underlying asset address
     * @param corePoolFee Fee for the core pool
     * @param tickSpacing Tick spacing for both pools
     * @param initialSqrtPriceX96 Initial sqrt price for core pool
     * @param salt Salt for the proxy hook
     * @param vtsConfiguration VTS configuration
     * @return corePoolId The ID of the created core pool
     * @return proxyPoolId The ID of the created proxy pool
     */
    function createMarket(
        address underlyingAsset0,
        address underlyingAsset1,
        uint24 corePoolFee,
        int24 tickSpacing,
        uint160 initialSqrtPriceX96,
        bytes32 salt,
        MarketVTSConfiguration calldata vtsConfiguration
    ) external returns (PoolId corePoolId, PoolId proxyPoolId);

    /**
     * @notice Adds protocol bounds to LCC tokens
     * @param bounds Array of addresses to add as bounds
     */
    function addBounds(address[] calldata bounds) external;

    /**
     * @notice Removes protocol bounds from LCC tokens
     * @param bounds Array of addresses to remove from bounds
     */
    function removeBounds(address[] calldata bounds) external;

    /**
     * @notice Gets the pool manager address
     * @return The pool manager address
     */
    function poolManager() external view returns (address);

    /**
     * @notice Gets the proxy hook address for a given proxy pool ID
     * @param proxyPoolId The proxy pool ID
     * @return The proxy hook address
     */
    function proxyToHook(PoolId proxyPoolId) external view returns (address);

    /**
     * @notice Gets the currency pair managed by a proxy hook
     * @param proxyHook The proxy hook address
     * @return The currency pair
     */
    function proxyHookToCurrencyPair(address proxyHook) external view returns (address[2] memory);

    /**
     * @notice Gets the currency pair managed by a core pool
     * @param corePoolId The core pool ID
     * @return The currency pair
     */
    function corePoolToCurrencyPair(PoolId corePoolId) external view returns (address[2] memory);
}
