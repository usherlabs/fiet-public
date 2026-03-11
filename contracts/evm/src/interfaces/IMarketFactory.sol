// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {IOracleHelper} from "./IOracleHelper.sol";
import {ILiquidityHub} from "./ILiquidityHub.sol";

/**
 * @title IMarketFactory
 * @notice Interface for MarketFactory contract
 * @dev MarketFactory is not the canonical emitter for hub-level events; LiquidityHub is.
 */
interface IMarketFactory {
    // ============ EVENTS ============

    event MarketCreated(
        PoolId indexed corePoolId,
        PoolId indexed proxyPoolId,
        address lcc0,
        address lcc1,
        address lcc0UnderlyingAsset,
        address lcc1UnderlyingAsset,
        address coreHook,
        address proxyHook
    );

    // ============ VIEW FUNCTIONS ============
    /**
     * @notice Gets the proxy hook address for a given core pool ID
     * @param corePoolId The core pool ID
     * @return The proxy hook address
     */
    function corePoolToProxyHook(PoolId corePoolId) external view returns (address);

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
    function coreHook() external view returns (address);

    /**
     * @notice Gets the liquidity hub address
     * @return The liquidity hub address
     */
    function liquidityHub() external view returns (ILiquidityHub);

    /**
     * @notice Gets the oracle helper address
     * @return The oracle helper address
     */
    function oracleHelper() external view returns (IOracleHelper);

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
     * @notice Explicitly initialises the MarketFactory and registers initial bounds.
     * @param _coreHook The core hook address to bind to this factory
     * @param initialBounds Additional protocol-bound endpoints to register
     */
    function initialise(address _coreHook, address[] calldata initialBounds) external;

    /**
     * @notice Returns whether the factory has been initialised.
     */
    function isInitialised() external view returns (bool);

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

    /**
     * @notice Checks if a vault is the canonical proxy hook for a given market
     * @param marketId The market ID (core PoolId as bytes32)
     * @param vault The vault/proxy hook address to validate
     * @return True if the vault is canonical for the market
     */
    function isCanonicalVault(bytes32 marketId, address vault) external view returns (bool);

    /**
     * @notice Gets the market liquidity for a given underlying asset in a market
     * @param underlyingAsset The underlying asset address
     * @param marketId The market ID
     * @return The market liquidity amount
     */
    function marketLiquidity(address underlyingAsset, bytes32 marketId) external view returns (uint256);

    /**
     * @notice Uses market liquidity for a given LCC in a market
     * @param lcc The LCC address (must be token0 or token1 of the core pool)
     * @param marketId The market ID
     * @param amount The amount to use
     */
    function useMarketLiquidity(address lcc, bytes32 marketId, uint256 amount) external returns (uint256);

    /**
     * @notice Called after modifyLiquidity to settle CoreHook's PoolManager deltas
     * @dev Triggers CoreHook to mint/burn ERC6909 claims to clear its hook deltas.
     * @param key The pool key for the currencies to settle
     */
    function afterModifyLiquidity(PoolKey calldata key) external;

    /**
     * @notice Records wrapped ingress facts emitted by LCC during protocol transfers to bucket-exempt sinks.
     * @dev MarketFactory validates canonical market scope and forwards ingress settlement to the canonical vault handler.
     * @param lcc The LCC lane where ingress occurred
     * @param wrappedAmount Wrapped-only component for this transfer slice
     */
    function prepareMarketLiquidity(address lcc, uint256 wrappedAmount) external;
}
