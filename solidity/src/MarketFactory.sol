// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {LiquidityCommitmentCertificate} from "./LCC.sol";
import {CoreHook} from "./CoreHook.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";

/**
 * @title MarketFactory
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract MarketFactory is IMarketFactory, Ownable {
    using PoolIdLibrary for PoolKey;

    error InvalidPoolParameters();
    error LCCAlreadyExists();
    error CorePoolAlreadyExists();
    error ProxyPoolAlreadyExists();
    error InvalidHookAddress();
    error InvalidUnderlyingAsset();
    error InvalidIssuer();
    error InvalidBound();

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

    IPoolManager public immutable poolManager;
    address public immutable coreHook;
    address public immutable proxyHook;

    // Mapping from underlying asset to LCC token
    mapping(address => address) public underlyingToLCC;

    // Mapping from LCC token to underlying asset
    mapping(address => address) public lccToUnderlying;

    // Mapping from pool key to hook address
    mapping(PoolId => address) public poolToHook;

    // Mapping from core pool ID to proxy pool ID
    mapping(PoolId => PoolId) public coreToProxy;

    // Mapping of addresses that found protocol-bounds
    mapping(address => bool) public bounds;

    // // Core pool parameters
    // uint24 public constant CORE_POOL_FEE = 3000; // 0.3%
    // uint24 public constant CORE_POOL_TICK_SPACING = 60;

    // // Proxy pool parameters
    // uint24 public constant PROXY_POOL_FEE = 500; // 0.05%
    // uint24 public constant PROXY_POOL_TICK_SPACING = 10;

    constructor(address _poolManager, address[] memory _bounds) Ownable(msg.sender) {
        if (_poolManager == address(0)) {
            revert InvalidPoolParameters();
        }
        poolManager = IPoolManager(_poolManager);

        bounds[address(this)] = true;
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = true;
        }
    }

    function setHooks(address _coreHook, address _proxyHook) external onlyOwner {
        coreHook = _coreHook;
        proxyHook = _proxyHook;
    }

    /**
     * @notice Creates a new market with core and proxy pools
     * @param underlyingAsset0 First underlying asset address
     * @param underlyingAsset1 Second underlying asset address
     * @param initialBounds Initial protocol bounds for LCC tokens
     * @return corePoolId The ID of the created core pool
     * @return proxyPoolId The ID of the created proxy pool
     */
    function createMarket(
        address underlyingAsset0,
        address underlyingAsset1,
        uint24 corePoolFee,
        uint24 tickSpacing,
        uint160 initialSqrtPriceX96
    ) external onlyOwner returns (PoolId corePoolId, PoolId proxyPoolId) {
        if (underlyingAsset0 == address(0) || underlyingAsset1 == address(0)) {
            revert InvalidUnderlyingAsset();
        }

        // Create LCC tokens if they don't exist
        address lccToken0 = _getOrCreateLCC(underlyingAsset0);
        address lccToken1 = _getOrCreateLCC(underlyingAsset1);

        // Create core pool with LCC tokens
        PoolKey memory corePoolKey =
            _createCorePool(lccToken0, lccToken1, corePoolFee, tickSpacing, initialSqrtPriceX96);

        // Create proxy pool with underlying assets
        PoolKey memory proxyPoolId = _createProxyPool(corePoolKey, underlyingAsset0, underlyingAsset1, tickSpacing);

        corePoolId = corePoolKey.toId();
        proxyPoolId = proxyPoolKey.toId();

        // Store the relationship between core and proxy pools
        coreToProxy[corePoolId] = proxyPoolId;
        proxyToCore[proxyPoolId] = corePoolId;

        emit MarketCreated(
            corePoolId,
            proxyPoolId,
            underlyingAsset0,
            underlyingAsset1,
            lccToken0,
            lccToken1,
            poolToHook[corePoolId],
            poolToHook[proxyPoolId]
        );
    }

    /**
     * @notice Gets or creates an LCC token for the given underlying asset
     * @param underlyingAsset The underlying asset address
     * @param initialBounds Initial protocol bounds
     * @return lccToken The LCC token address
     */
    function _getOrCreateLCC(address underlyingAsset) internal returns (address lccToken) {
        lccToken = underlyingToLCC[underlyingAsset];

        if (lccToken == address(0)) {
            // Create new LCC token
            address[] memory issuers = new address[](2);
            issuers[0] = address(this); // ProxyHook
            // issuers[1] = address(poolManager); // PoolManager as issuer

            lccToken = address(new LiquidityCommitmentCertificate(underlyingAsset, issuers));

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
     * @return poolId The created pool ID
     */
    function _createCorePool(
        address lccToken0,
        address lccToken1,
        uint24 corePoolFee,
        uint24 corePoolTickSpacing,
        uint160 initialSqrtPriceX96
    ) internal returns (PoolKey memory poolKey) {
        // Create pool key
        (Currency currency0, Currency currency1) = _sortCurrencies(lccToken0, lccToken1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: corePoolFee,
            tickSpacing: corePoolTickSpacing,
            hooks: IHooks(coreHook)
        });

        PoolId poolId = poolKey.toId();

        // Check if pool already exists
        if (poolToHook[poolId] != address(0)) {
            revert CorePoolAlreadyExists();
        }

        // Initialize the pool
        poolManager.initialize(poolKey, initialSqrtPriceX96);

        // Store hook reference
        poolToHook[poolId] = coreHook;
    }

    /**
     * @notice Creates a proxy pool with underlying assets
     * @param underlyingAsset0 First underlying asset
     * @param underlyingAsset1 Second underlying asset
     * @param corePoolId The associated core pool ID
     * @return poolId The created pool ID
     */
    function _createProxyPool(
        PoolKey memory corePoolKey,
        address underlyingAsset0,
        address underlyingAsset1,
        uint24 proxyPoolTickSpacing
    ) internal returns (PoolKey memory poolKey) {
        // Create pool key for proxy pool
        (Currency currency0, Currency currency1) = _sortCurrencies(underlyingAsset0, underlyingAsset1);

        poolKey = PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: 0,
            tickSpacing: proxyPoolTickSpacing,
            hooks: IHooks(proxyHook)
        });

        PoolId poolId = poolKey.toId();

        // Check if pool already exists
        if (poolToHook[poolId] != address(0)) {
            revert ProxyPoolAlreadyExists();
        }

        // Initialize the pool
        poolManager.initialize(poolKey, 0);

        // Set corePoolKey for Proxy PoolId on ProxyHook
        ProxyHook(proxyHook).setCorePoolKey(poolId, corePoolKey);

        // Store hook reference
        poolToHook[poolId] = proxyHook;
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
     * @param lccToken The LCC token address
     * @param bounds Array of addresses to add as bounds
     */
    function addBounds(address lccToken, address[] calldata bounds) external onlyOwner {
        if (lccToFactory[lccToken] != address(this)) {
            revert InvalidBound();
        }

        LiquidityCommitmentCertificate(lccToken).addBounds(bounds);
        emit BoundsUpdated(lccToken, bounds, true);
    }

    /**
     * @notice Removes protocol bounds from LCC tokens
     * @param lccToken The LCC token address
     * @param bounds Array of addresses to remove from bounds
     */
    function removeBounds(address lccToken, address[] calldata bounds) external onlyOwner {
        if (lccToFactory[lccToken] != address(this)) {
            revert InvalidBound();
        }

        LiquidityCommitmentCertificate(lccToken).removeBounds(bounds);
        emit BoundsUpdated(lccToken, bounds, false);
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
     * @notice Gets the hook address for a given pool
     * @param poolId The pool ID
     * @return The hook address
     */
    function getHook(PoolId poolId) external view returns (address) {
        return poolToHook[poolId];
    }

    /**
     * @notice Checks if an address is a bound for an LCC token
     * @param lccToken The LCC token address
     * @param bound The address to check
     * @return True if the address is a bound
     */
    function isBound(address lccToken, address bound) external view returns (bool) {
        if (lccToFactory[lccToken] != address(this)) {
            return false;
        }
        return LiquidityCommitmentCertificate(lccToken).bounds(bound);
    }
}
