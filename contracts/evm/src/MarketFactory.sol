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

    // Mapping of addresses that found protocol-bounds
    mapping(address => bool) public bounds;

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
        address[] memory _bounds,
        address _initialOwner
    ) Ownable(_initialOwner) ImmutableState(IPoolManager(_poolManager)) ImmutableVTSState(_vtsOrchestrator) {
        liquidityHub = ILiquidityHub(_liquidityHub);
        oracleHelper = IOracleHelper(_oracleHelper);

        // Set Protocol bounds addresses
        bounds[address(this)] = true;
        bounds[_poolManager] = true; // All uniswap liquidity goes to/from the poolManager.
        bounds[_liquidityHub] = true; // All LCCs are created and managed by the liquidityHub.
        for (uint256 i = 0; i < _bounds.length; i++) {
            bounds[_bounds[i]] = true;
        }
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

    function setHooks(address _coreHook) external onlyOwner {
        // These variables are immutable. Can only be set once
        // Tie this factory to these hooks as LCCs/markets/hooks are tied to the factory.
        if (coreHook == address(0)) {
            if (_coreHook == address(0)) {
                revert Errors.InvalidAddress(_coreHook);
            }
            coreHook = _coreHook;
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
     * @param issuers Additional issuer addresses to add to the LCC tokens (vtsOrchestrator and proxyHook are always included)
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
        MarketVTSConfiguration calldata vtsConfiguration,
        address[] calldata issuers
    ) external onlyOwner returns (PoolId corePoolId, PoolId proxyPoolId) {
        MarketCreationContext memory ctx;
        // Build core creation context in helpers to avoid "stack too deep" when not compiling viaIR.
        (ctx.proxyHookAddress, ctx.marketRef, ctx.lccToken0, ctx.lccToken1) =
            _deployProxyAndCreateLCCPair(underlyingAsset0, underlyingAsset1, salt, issuers);

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
            if (PoolId.unwrap(coreToProxy[corePoolKey.toId()]) != bytes32(0)) {
                revert Errors.ProxyPoolAlreadyExists();
            }
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
        bounds[ctx.proxyHookAddress] = true;

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
    function _deployProxyAndCreateLCCPair(
        address underlyingAsset0,
        address underlyingAsset1,
        bytes32 salt,
        address[] calldata issuers
    ) internal returns (address proxyHookAddress, bytes memory marketRef, address lccToken0, address lccToken1) {
        proxyHookAddress = MarketVaultDeployer(marketVaultDeployer).deployProxyHook(address(poolManager), salt);
        marketRef = abi.encodePacked(proxyHookAddress);
        address[] memory initialIssuers = _buildInitialIssuers(proxyHookAddress, issuers);
        (lccToken0, lccToken1) =
            liquidityHub.createLCCPair(marketRef, underlyingAsset0, underlyingAsset1, MARKET_NAME, initialIssuers);
    }

    /// @dev Always includes `vtsOrchestrator` and the proxy hook, then appends any additional issuers.
    function _buildInitialIssuers(address proxyHookAddress, address[] calldata issuers)
        internal
        view
        returns (address[] memory initialIssuers)
    {
        uint256 totalIssuers = 2 + issuers.length;
        initialIssuers = new address[](totalIssuers);
        initialIssuers[0] = address(vtsOrchestrator);
        initialIssuers[1] = proxyHookAddress;
        for (uint256 i = 0; i < issuers.length; i++) {
            initialIssuers[2 + i] = issuers[i];
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

    // ============ LIQUIDITY FUNCTIONS ============

    function useMarketLiquidity(address underlyingAsset, bytes32 marketId, uint256 amount)
        external
        onlyLiquidityHub
        returns (uint256 used)
    {
        PoolId pId = PoolId.wrap(marketId);
        address[2] memory currencies = _proxyHookToCurrencyPair[_proxyToHook[coreToProxy[pId]]];
        uint256 amount0 = 0;
        uint256 amount1 = 0;
        if (currencies[0] == underlyingAsset) {
            amount0 = amount;
        } else if (currencies[1] == underlyingAsset) {
            amount1 = amount;
        } else {
            revert Errors.InvalidAddress(underlyingAsset);
        }
        BalanceDelta usedDelta = IMarketVault(_proxyToHook[coreToProxy[pId]])
            .tryModifyLiquidities(LiquidityUtils.safeToBalanceDelta(amount0, amount1, false, false)); // positive delta indicating withdrawal from market
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
        if (!bounds[msg.sender]) {
            revert Errors.InvalidSender();
        }
        ICoreHook(coreHook).settleHookDeltasToPot(key);
    }

    // ============ VIEW FUNCTIONS ============

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
