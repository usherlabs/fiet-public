// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable, Ownable2Step} from "openzeppelin-contracts/contracts/access/Ownable2Step.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {IHookPausable} from "./interfaces/IHookPausable.sol";
import {ProxyHook} from "./ProxyHook.sol";

/**
 * @title MarketFactory
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract MarketFactory is IMarketFactory, Ownable2Step {
    using PoolIdLibrary for PoolKey;

    IPoolManager private immutable _poolManager;
    address public coreHook;

    // Mapping from underlying asset to LCC token
    mapping(address => address) public underlyingToLCC;

    // Mapping from LCC token to underlying asset
    mapping(address => address) public lccToUnderlying;

    // Mapping from LCC token to factory
    mapping(address => address) public lccToFactory;

    // Mapping from core pool ID to proxy pool ID
    mapping(PoolId => PoolId) public coreToProxy;

    // Mapping of addresses that found protocol-bounds
    mapping(address => bool) public bounds;

    // Mapping from proxy pool ID to proxy hook address
    mapping(PoolId => address) private _proxyToHook;

    // Mapping from proxy hook address to currencies it manages
    mapping(address => address[2]) private _proxyHookToCurrencyPair;

    constructor(address poolManagerAddr, address[] memory _bounds) Ownable(msg.sender) {
        if (poolManagerAddr == address(0)) {
            revert InvalidPoolParameters();
        }
        _poolManager = IPoolManager(poolManagerAddr);

        bounds[address(this)] = true;
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = true;
        }
    }

    function setHooks(address _coreHook) external onlyOwner {
        // These variables are immutable. Can only be set once
        // Tie this factory to these hooks as LCCs/markets/hooks are tied to the factory.
        if (coreHook == address(0)) {
            if (_coreHook == address(0)) {
                revert("Invalid hook addresses");
            }
            coreHook = _coreHook;
        }
    }

    /**
     * @notice Pauses a market
     * @param poolId The Core Pool ID to pause
     */
    function pause(PoolId poolId) external onlyOwner {
        IHookPausable(coreHook).pause(poolId);
    }

    /**
     * @notice Unpauses a market
     * @param poolId The Core Pool ID to unpause
     */
    function unpause(PoolId poolId) external onlyOwner {
        IHookPausable(coreHook).unpause(poolId);
    }

    /**
     * @notice Creates a new market with core and proxy pools
     * @param underlyingAsset0 First underlying asset address
     * @param underlyingAsset1 Second underlying asset address
     * @param corePoolFee Fee for the core pool
     * @param tickSpacing Tick spacing for both pools
     * @param initialSqrtPriceX96 Initial sqrt price for core pool
     * @return corePoolId The ID of the created core pool
     * @return proxyPoolId The ID of the created proxy pool
     */
    function createMarket(
        address proxyHook,
        address underlyingAsset0,
        address underlyingAsset1,
        uint24 corePoolFee,
        int24 tickSpacing,
        uint160 initialSqrtPriceX96
    ) external onlyOwner returns (PoolId corePoolId, PoolId proxyPoolId) {
        if (underlyingAsset0 == address(0) || underlyingAsset1 == address(0)) {
            revert InvalidUnderlyingAsset();
        }

        // Create LCC tokens if they don't exist
        address lccToken0 = _getOrCreateLCC(underlyingAsset0);
        address lccToken1 = _getOrCreateLCC(underlyingAsset1);

        // Determine if orders match
        (Currency underlyingCurr0,) = _sortCurrencies(underlyingAsset0, underlyingAsset1);
        (Currency lccCurr0,) = _sortCurrencies(lccToken0, lccToken1);
        bool ordersMatch =
            (underlyingAsset0 == Currency.unwrap(underlyingCurr0)) == (lccToken0 == Currency.unwrap(lccCurr0));

        uint160 proxyInitialPrice = initialSqrtPriceX96;
        if (!ordersMatch) {
            proxyInitialPrice = uint160((uint256(1) << 192) / initialSqrtPriceX96);
        }

        // Create core pool with LCC tokens
        PoolKey memory corePoolKey =
            _createCorePool(lccToken0, lccToken1, corePoolFee, tickSpacing, initialSqrtPriceX96, coreHook);

        // Check if proxy pool already exists
        if (PoolId.unwrap(coreToProxy[corePoolKey.toId()]) != bytes32(0)) {
            revert ProxyPoolAlreadyExists();
        }

        // Create proxy pool with underlying assets
        PoolKey memory proxyPoolKey =
            _createProxyPool(underlyingAsset0, underlyingAsset1, tickSpacing, proxyHook, proxyInitialPrice);

        corePoolId = corePoolKey.toId();
        proxyPoolId = proxyPoolKey.toId();

        // Store the relationship between core and proxy pools
        coreToProxy[corePoolId] = proxyPoolId;
        _proxyToHook[proxyPoolId] = proxyHook;
        // Store the currencies the proxy hook manages
        _proxyHookToCurrencyPair[proxyHook] =
            [Currency.unwrap(proxyPoolKey.currency0), Currency.unwrap(proxyPoolKey.currency1)];

        // Set the core pool key in the proxy hook for this new market
        ProxyHook(proxyHook).setCorePoolKey(corePoolKey);
        ProxyHook(proxyHook).activate();

        emit MarketCreated(
            corePoolId, proxyPoolId, underlyingAsset0, underlyingAsset1, lccToken0, lccToken1, coreHook, proxyHook
        );
    }

    function getOrCreateLCC(address underlyingAsset) external onlyOwner returns (address lccToken) {
        return _getOrCreateLCC(underlyingAsset);
    }

    /**
     * @notice Gets or creates an LCC token for the given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return lccToken The LCC token address
     */
    function _getOrCreateLCC(address underlyingAsset) internal returns (address lccToken) {
        lccToken = underlyingToLCC[underlyingAsset];

        if (lccToken == address(0)) {
            // Create new LCC token
            address[] memory issuers = new address[](2);
            // issuers[1] = address(poolManager); // TODO: Add MMPositionManager as issuer

            lccToken = address(new LiquidityCommitmentCertificate(underlyingAsset, issuers, address(this)));

            underlyingToLCC[underlyingAsset] = lccToken;
            lccToUnderlying[lccToken] = underlyingAsset;
            lccToFactory[lccToken] = address(this);

            emit LCCCreated(underlyingAsset, lccToken);
        }
    }

    /**
     * @notice Creates a core pool with LCC tokens
     * @param lccToken0 First LCC token
     * @param lccToken1 Second LCC token
     * @param corePoolFee Fee for the core pool
     * @param corePoolTickSpacing Tick spacing for the core pool
     * @param initialSqrtPriceX96 Initial sqrt price
     * @param coreHookInstance The core hook instance to use
     * @return poolKey The created pool key
     */
    function _createCorePool(
        address lccToken0,
        address lccToken1,
        uint24 corePoolFee,
        int24 corePoolTickSpacing,
        uint160 initialSqrtPriceX96,
        address coreHookInstance
    ) internal returns (PoolKey memory poolKey) {
        // Create pool key
        (Currency currency0, Currency currency1) = _sortCurrencies(lccToken0, lccToken1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: corePoolFee,
            tickSpacing: corePoolTickSpacing,
            hooks: IHooks(coreHookInstance)
        });

        PoolId poolId = poolKey.toId();

        // Check if pool already exists
        if (PoolId.unwrap(coreToProxy[poolId]) != bytes32(0)) {
            revert CorePoolAlreadyExists();
        }

        // Initialize the pool
        _poolManager.initialize(poolKey, initialSqrtPriceX96);
    }

    /**
     * @notice Creates a proxy pool with underlying assets
     * @param underlyingAsset0 First underlying asset
     * @param underlyingAsset1 Second underlying asset
     * @param proxyPoolTickSpacing Tick spacing for the proxy pool
     * @param proxyHookInstance The proxy hook instance to use
     * @return poolKey The created pool key
     */
    function _createProxyPool(
        address underlyingAsset0,
        address underlyingAsset1,
        int24 proxyPoolTickSpacing,
        address proxyHookInstance,
        uint160 initialSqrtPriceX96 // Add parameter for initial price
    ) internal returns (PoolKey memory poolKey) {
        // Create pool key for proxy pool
        (Currency currency0, Currency currency1) = _sortCurrencies(underlyingAsset0, underlyingAsset1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: proxyPoolTickSpacing,
            hooks: IHooks(proxyHookInstance)
        });

        // Initialize the pool
        _poolManager.initialize(poolKey, initialSqrtPriceX96); // Use provided initial price instead of 0
    }

    /**
     * @notice Sorts currencies to ensure consistent ordering
     * @param token0 First token address
     * @param token1 Second token address
     * @return currency0 First currency
     * @return currency1 Second currency
     */
    function _sortCurrencies(address token0, address token1)
        internal
        pure
        returns (Currency currency0, Currency currency1)
    {
        if (token0 < token1) {
            currency0 = Currency.wrap(token0);
            currency1 = Currency.wrap(token1);
        } else {
            currency0 = Currency.wrap(token1);
            currency1 = Currency.wrap(token0);
        }
    }

    // ============ BOUNDS MANAGEMENT ============

    /**
     * @notice Adds protocol bounds to LCC tokens
     * @param _bounds Array of addresses to add as bounds
     */
    function addBounds(address[] calldata _bounds) external onlyOwner {
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = true;
        }

        emit BoundsUpdated(_bounds, true);
    }

    /**
     * @notice Removes protocol bounds from LCC tokens
     * @param _bounds Array of addresses to remove from bounds
     */
    function removeBounds(address[] calldata _bounds) external onlyOwner {
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = false;
        }

        emit BoundsUpdated(_bounds, false);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Gets the LCC token for a given underlying asset
     * @param underlyingAsset The underlying asset address
     * @return The LCC token address
     */
    function getLCC(address underlyingAsset) external view returns (address) {
        return underlyingToLCC[underlyingAsset];
    }

    /**
     * @notice Gets the underlying asset for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlyingAsset(address lccToken) external view returns (address) {
        return lccToUnderlying[lccToken];
    }

    /**
     * @notice Gets the core hook address
     * @return The core hook address
     */
    function getCoreHook() external view returns (address) {
        return coreHook;
    }

    /**
     * @notice Gets the pool manager address
     * @return The pool manager address
     */
    function poolManager() external view returns (address) {
        return address(_poolManager);
    }

    /**
     * @notice Gets the proxy hook address for a given proxy pool ID
     * @param proxyPoolId The proxy pool ID
     * @return The proxy hook address
     */
    function proxyToHook(PoolId proxyPoolId) external view returns (address) {
        return _proxyToHook[proxyPoolId];
    }

    /**
     * @notice Gets the currency pair managed by a proxy hook
     * @param proxyHook The proxy hook address
     * @return The currency pair
     */
    function proxyHookToCurrencyPair(address proxyHook) external view returns (address[2] memory) {
        return _proxyHookToCurrencyPair[proxyHook];
    }
}
