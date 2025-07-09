// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

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
    event BoundsUpdated(address indexed lccToken, address[] bounds, bool added);

    // ============ ERRORS ============

    error InvalidPoolParameters();
    error LCCAlreadyExists();
    error CorePoolAlreadyExists();
    error ProxyPoolAlreadyExists();
    error InvalidHookAddress();
    error InvalidUnderlyingAsset();
    error InvalidIssuer();
    error InvalidBound();

    // ============ VIEW FUNCTIONS ============

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
     * @notice Gets the hook address for a given pool
     * @param poolId The pool ID
     * @return The hook address
     */
    function getHook(PoolId poolId) external view returns (address);

    /**
     * @notice Gets the proxy pool ID for a given core pool ID
     * @param corePoolId The core pool ID
     * @return The proxy pool ID
     */
    function coreToProxy(PoolId corePoolId) external view returns (PoolId);

    /**
     * @notice Gets the core pool ID for a given proxy pool ID
     * @param proxyPoolId The proxy pool ID
     * @return The core pool ID
     */
    function proxyToCore(PoolId proxyPoolId) external view returns (PoolId);

    /**
     * @notice Checks if an address is a bound for an LCC token
     * @param lccToken The LCC token address
     * @param bound The address to check
     * @return True if the address is a bound
     */
    function isBound(address lccToken, address bound) external view returns (bool);

    /**
     * @notice Checks if an address is a protocol bound
     * @param bound The address to check
     * @return True if the address is a protocol bound
     */
    function bounds(address bound) external view returns (bool);

    /**
     * @notice Gets the pool manager address
     * @return The pool manager address
     */
    function poolManager() external view returns (address);

    // ============ STATE CHANGING FUNCTIONS ============

    /**
     * @notice Creates a new market with core and proxy pools
     * @param underlyingAsset0 First underlying asset address
     * @param underlyingAsset1 Second underlying asset address
     * @param initialBounds Initial protocol bounds for LCC tokens
     * @return corePoolId The ID of the created core pool
     * @return proxyPoolId The ID of the created proxy pool
     */
    function createMarket(address underlyingAsset0, address underlyingAsset1, address[] calldata initialBounds)
        external
        returns (PoolId corePoolId, PoolId proxyPoolId);

    /**
     * @notice Adds protocol bounds to LCC tokens
     * @param lccToken The LCC token address
     * @param bounds Array of addresses to add as bounds
     */
    function addBounds(address lccToken, address[] calldata bounds) external;

    /**
     * @notice Removes protocol bounds from LCC tokens
     * @param lccToken The LCC token address
     * @param bounds Array of addresses to remove from bounds
     */
    function removeBounds(address lccToken, address[] calldata bounds) external;
}
