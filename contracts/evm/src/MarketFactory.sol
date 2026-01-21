// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {ProxyHook} from "./ProxyHook.sol";
import {MarketVaultDeployer} from "./MarketVaultDeployer.sol";
import {MarketVTSConfiguration} from "./types/VTS.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {LiquidityUtils} from "./libraries/LiquidityUtils.sol";
import {Bounds} from "./libraries/Bounds.sol";
import {Errors} from "./libraries/Errors.sol";
import {ImmutableState} from "v4-periphery/src/base/ImmutableState.sol";
import {ImmutableVTSState} from "./modules/ImmutableVTSState.sol";
import {ICoreHook} from "./interfaces/ICoreHook.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";

/**
 * @title MarketFactory
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract MarketFactory is IMarketFactory, Ownable, ImmutableState, ImmutableVTSState {
    using PoolIdLibrary for PoolKey;
    using TransientStateLibrary for IPoolManager;

    // ═══════════════════════════════════════════════════════════════════════════
    // Internal Structs
    // ═══════════════════════════════════════════════════════════════════════════

    /// @dev Internal struct to reduce stack depth in createMarket
    struct MarketCreationContext {
        address proxyHookAddress;
        bytes marketRef;
        address lccToken0;
        address lccToken1;
        Currency underlyingCurr0;
        Currency underlyingCurr1;
        Currency lccCurr0;
        Currency lccCurr1;
    }

    // ═══════════════════════════════════════════════════════════════════════════
    // State Variables
    // ═══════════════════════════════════════════════════════════════════════════

    string public constant MARKET_NAME = "Uv4";
    IOracleHelper public immutable oracleHelper;
    address public coreHook;
    address public immutable marketVaultDeployer;
    ILiquidityHub public immutable liquidityHub;

    // Mapping from core pool ID to proxy pool ID
    mapping(PoolId => PoolId) public coreToProxy;

    bool private initialised;

    // Mapping from proxy pool ID to proxy hook address
    mapping(PoolId => address) private _proxyToHook;

    // Mapping from proxy hook address to currencies it manages
    mapping(address => address[2]) private _proxyHookToCurrencyPair;

    mapping(PoolId => address[2]) private _corePoolToCurrencyPair;

    constructor(
        address _poolManager,
        address _liquidityHub,
        address _oracleHelper,
        address _vtsOrchestrator,
        address _initialOwner
    ) Ownable(_initialOwner) ImmutableState(IPoolManager(_poolManager)) ImmutableVTSState(_vtsOrchestrator) {
        if (_poolManager == address(0)) revert Errors.InvalidAddress(_poolManager);
        if (_liquidityHub == address(0)) revert Errors.InvalidAddress(_liquidityHub);
        if (_oracleHelper == address(0)) revert Errors.InvalidAddress(_oracleHelper);

        liquidityHub = ILiquidityHub(_liquidityHub);
        oracleHelper = IOracleHelper(_oracleHelper);

        // Deploy MarketVaultDeployer which would be used to deploy proxy hooks on behalf of the factory
        marketVaultDeployer = address(new MarketVaultDeployer());
    }

    modifier onlyLiquidityHub() {
        _onlyLiquidityHub();
        _;
    }

    function _onlyLiquidityHub() internal view {
        if (msg.sender != address(liquidityHub)) {
            revert Errors.InvalidSender();
        }
    }

    /// @notice Requires PoolManager to be unlocked (within an active batch)
    modifier onlyIfPoolManagerUnlocked() {
        _onlyIfPoolManagerUnlocked();
        _;
    }

    function _onlyIfPoolManagerUnlocked() internal view {
        if (!poolManager.isUnlocked()) revert Errors.PoolManagerMustBeUnlocked();
    }

    function isInitialised() external view returns (bool) {
        return initialised;
    }

    function initialise(address _coreHook, address[] calldata initialBounds) external onlyOwner {
        if (initialised) return;

        if (_coreHook == address(0)) {
            revert Errors.InvalidAddress(_coreHook);
        }

        if (coreHook != address(0) && coreHook != _coreHook) {
            revert Errors.InvalidAddress(_coreHook);
        }

        coreHook = _coreHook;
        initialised = true;

        // Bucket-exempt endpoints.
        liquidityHub.setBoundLevel(address(poolManager), Bounds.BOUND_EXEMPT);
        // LiquidityHub is a bucket-exempt endpoint as it handles special case where processSettlementFor isForHub, and also derived from caller balance buckets during wrapWith.
        liquidityHub.setBoundLevel(address(liquidityHub), Bounds.BOUND_EXEMPT);

        // Transfer endpoints (bucket-tracked).
        // // LiquidityHub performs unwraps within wrapWith functions, and therefore must be BOUND_ENDPOINT to preserve bucket accounting from users.
        // liquidityHub.setBoundLevel(address(liquidityHub), Bounds.BOUND_ENDPOINT);
        liquidityHub.setBoundLevel(address(this), Bounds.BOUND_ENDPOINT);
        if (initialBounds.length > 0) {
            liquidityHub.setBoundLevels(initialBounds, Bounds.BOUND_ENDPOINT);
        }
    }

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
    ) external onlyOwner returns (PoolId corePoolId, PoolId proxyPoolId) {
        if (!initialised) revert Errors.InvalidAddress(coreHook);
        if (initialSqrtPriceX96 == 0) revert Errors.InvalidAmount(uint256(initialSqrtPriceX96), 0);

        MarketCreationContext memory ctx;
        // Build core creation context in helpers to avoid "stack too deep" when not compiling viaIR.
        (ctx.proxyHookAddress, ctx.marketRef, ctx.lccToken0, ctx.lccToken1) =
            _deployProxyAndCreateLCCPair(underlyingAsset0, underlyingAsset1, salt);

        // Validate oracles and determine currency ordering
        oracleHelper.validateMarketOracles(ctx.lccToken0, ctx.lccToken1);
        (ctx.underlyingCurr0, ctx.underlyingCurr1) = _sortCurrencies(underlyingAsset0, underlyingAsset1);
        (ctx.lccCurr0, ctx.lccCurr1) = _sortCurrencies(ctx.lccToken0, ctx.lccToken1);

        // Calculate proxy initial price
        uint160 proxyInitialPrice;
        {
            bool ordersMatch = (underlyingAsset0 == Currency.unwrap(ctx.underlyingCurr0))
                == (ctx.lccToken0 == Currency.unwrap(ctx.lccCurr0));
            proxyInitialPrice = ordersMatch ? initialSqrtPriceX96 : uint160((uint256(1) << 192) / initialSqrtPriceX96);
        }

        // Create pools and store mappings
        PoolKey memory corePoolKey;
        PoolKey memory proxyPoolKey;
        {
            corePoolKey =
                _createCorePool(ctx.lccToken0, ctx.lccToken1, corePoolFee, tickSpacing, initialSqrtPriceX96, coreHook);
            proxyPoolKey = _createProxyPool(
                underlyingAsset0, underlyingAsset1, tickSpacing, ctx.proxyHookAddress, proxyInitialPrice
            );
        }

        corePoolId = corePoolKey.toId();
        proxyPoolId = proxyPoolKey.toId();

        // Store pool relationships
        coreToProxy[corePoolId] = proxyPoolId;
        _proxyToHook[proxyPoolId] = ctx.proxyHookAddress;
        _proxyHookToCurrencyPair[ctx.proxyHookAddress] =
            [Currency.unwrap(proxyPoolKey.currency0), Currency.unwrap(proxyPoolKey.currency1)];
        _corePoolToCurrencyPair[corePoolId] =
            [Currency.unwrap(corePoolKey.currency0), Currency.unwrap(corePoolKey.currency1)];

        // For swap deficits overflow, and LCC transfer to recipient the proxy hook must be within protocol bounds.
        // Use BOUND_EXEMPT as LCCs are issued from ProxyHook, are never unwrapped/wrapped, and sent always as market-derived.
        liquidityHub.setBoundLevel(ctx.proxyHookAddress, Bounds.BOUND_EXEMPT);

        // Activate proxy hook and initialize
        {
            ProxyHook proxyHookInstance = ProxyHook(payable(ctx.proxyHookAddress));
            proxyHookInstance.setCorePoolKey(corePoolKey);
            proxyHookInstance.activate();
        }

        // Initialize liquidity hub and VTS
        liquidityHub.initialize(ctx.lccToken0, ctx.lccToken1, PoolId.unwrap(corePoolId), ctx.marketRef);
        vtsOrchestrator.initPool(corePoolKey, vtsConfiguration);

        emit MarketCreated(
            corePoolId,
            proxyPoolId,
            Currency.unwrap(ctx.underlyingCurr0),
            Currency.unwrap(ctx.underlyingCurr1),
            Currency.unwrap(ctx.lccCurr0),
            Currency.unwrap(ctx.lccCurr1),
            coreHook,
            ctx.proxyHookAddress
        );
    }

    /// @dev Deploys the proxy hook, constructs the market reference, and creates the LCC pair.
    ///      Split out of `createMarket` to avoid "stack too deep" when coverage disables viaIR/optimiser.
    function _deployProxyAndCreateLCCPair(address underlyingAsset0, address underlyingAsset1, bytes32 salt)
        internal
        returns (address proxyHookAddress, bytes memory marketRef, address lccToken0, address lccToken1)
    {
        proxyHookAddress = MarketVaultDeployer(marketVaultDeployer).deployProxyHook(address(poolManager), salt);
        marketRef = abi.encodePacked(proxyHookAddress);
        address[] memory initialIssuers = new address[](2);
        initialIssuers[0] = address(vtsOrchestrator);
        initialIssuers[1] = proxyHookAddress;
        (lccToken0, lccToken1) =
            liquidityHub.createLCCPair(marketRef, underlyingAsset0, underlyingAsset1, MARKET_NAME, initialIssuers);
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
            revert Errors.CorePoolAlreadyExists();
        }

        // Initialize the pool. Reverts on any failure.
        poolManager.initialize(poolKey, initialSqrtPriceX96);
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
        poolManager.initialize(poolKey, initialSqrtPriceX96); // Use provided initial price instead of 0
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
        liquidityHub.setBoundLevels(_bounds, Bounds.BOUND_ENDPOINT);
    }

    /**
     * @notice Removes protocol bounds from LCC tokens
     * @param _bounds Array of addresses to remove from bounds
     */
    function removeBounds(address[] calldata _bounds) external onlyOwner {
        liquidityHub.setBoundLevels(_bounds, Bounds.BOUND_NONE);
    }

    // ============ LIQUIDITY FUNCTIONS ============

    function useMarketLiquidity(address underlyingAsset, bytes32 marketId, uint256 amount)
        external
        onlyLiquidityHub
        returns (uint256 used)
    {
        PoolId pId = PoolId.wrap(marketId);
        address proxyHook = _proxyToHook[coreToProxy[pId]];
        address currency0 = _proxyHookToCurrencyPair[proxyHook][0];
        address currency1 = _proxyHookToCurrencyPair[proxyHook][1];
        uint256 amount0 = 0;
        uint256 amount1 = 0;
        if (currency0 == underlyingAsset) {
            amount0 = amount;
        } else if (currency1 == underlyingAsset) {
            amount1 = amount;
        } else {
            revert Errors.InvalidAddress(underlyingAsset);
        }
        BalanceDelta usedDelta = IMarketVault(proxyHook)
            .tryModifyLiquiditiesWithRecipient(
                LiquidityUtils.safeToBalanceDelta(amount0, amount1, false, false), address(liquidityHub)
            ); // positive delta indicating withdrawal from market
        vtsOrchestrator.incrementCoverage(
            pId,
            LiquidityUtils.safeInt128ToUint256(usedDelta.amount0()),
            LiquidityUtils.safeInt128ToUint256(usedDelta.amount1())
        );
        used = LiquidityUtils.safeInt128ToUint256(usedDelta.amount0() + usedDelta.amount1());
    }

    /// @notice Called after modifyLiquidity to settle CoreHook's PoolManager deltas
    /// @dev Triggers CoreHook to mint/burn ERC6909 claims to clear its hook deltas.
    ///      Must be called after poolManager.modifyLiquidity() returns (when hook deltas are applied).
    /// @param key The pool key for the currencies to settle
    function afterModifyLiquidity(PoolKey calldata key) external onlyIfPoolManagerUnlocked {
        if (!Bounds.isEndpoint(liquidityHub.boundLevel(address(this), msg.sender))) {
            revert Errors.InvalidSender();
        }
        ICoreHook(coreHook).settleHookDeltasToPot(key);
    }

    // ============ VIEW FUNCTIONS ============

    function bounds(address bound) external view returns (bool) {
        return Bounds.isEndpoint(liquidityHub.boundLevel(address(this), bound));
    }

    function marketLiquidity(address underlyingAsset, bytes32 marketId) external view returns (uint256) {
        return IMarketVault(_proxyToHook[coreToProxy[PoolId.wrap(marketId)]])
            .inMarketBalanceOf(Currency.wrap(underlyingAsset));
    }

    /**
     * @notice Gets the proxy hook address for a given core pool ID
     * @param corePoolId The core pool ID
     * @return The proxy hook address
     */
    function corePoolToProxyHook(PoolId corePoolId) external view returns (address) {
        return _proxyToHook[coreToProxy[corePoolId]];
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

    /**
     * @notice Gets the currency pair managed by a core pool
     * @param corePoolId The core pool ID
     * @return The currency pair
     */
    function corePoolToCurrencyPair(PoolId corePoolId) external view returns (address[2] memory) {
        return _corePoolToCurrencyPair[corePoolId];
    }
}
