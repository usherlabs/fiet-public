// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LCCFactoryLib, LCCFactoryLinkedLib} from "./libraries/LCCFactoryLib.sol";
import {LiquidityHubLib} from "./libraries/LiquidityHubLib.sol";
import {LiquidityHubStorage, Market} from "./types/Liquidity.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {Errors} from "./libraries/Errors.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {TransientSlots} from "./libraries/TransientSlots.sol";
import {ILiquidityHub} from "./interfaces/ILiquidityHub.sol";
import {ILCC} from "./interfaces/ILCC.sol";
import {BoundRegistry} from "./modules/BoundRegistry.sol";
import {Bounds} from "./libraries/Bounds.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is BoundRegistry, Ownable, ReentrancyGuardTransient {
    using CurrencyTransfer for Currency;

    // ============ UNIFIED STATE ============
    LiquidityHubStorage internal s;

    IOracleHelper public immutable oracleHelper;

    event FactorySet(address indexed factory, bool enabled);
    event LCCCreated(address indexed underlyingAsset, address indexed lccToken, bytes32 marketId);
    event LiquidityAvailable(address indexed lcc, address underlyingAsset, uint256 amount, bytes32 marketId);
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
    event SettlementAnnulled(address indexed lcc, address indexed recipient, uint256 amount);
    event SettlementProcessed(address indexed lcc, address indexed recipient, uint256 amount);
    event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
    event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
    event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);

    // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
    // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.

    // Map of market factories
    mapping(address => bool) public isFactory;

    /**
     * @notice Constructs the LiquidityHub contract
     * @param _oracleHelper The oracle helper contract address
     * @param _nativeAssetName The name of the native asset (e.g., "Ether")
     * @param _nativeAssetSymbol The symbol of the native asset (e.g., "ETH")
     * @param _nativeAssetDecimals The decimals of the native asset (typically 18)
     * @param _initialOwner The initial owner of the contract
     */
    constructor(
        address _oracleHelper,
        string memory _nativeAssetName,
        string memory _nativeAssetSymbol,
        uint8 _nativeAssetDecimals,
        address _initialOwner
    ) Ownable(_initialOwner) {
        oracleHelper = IOracleHelper(_oracleHelper);
        LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
    }

    /**
     * @notice Modifier to restrict access to registered factory contracts only
     */
    modifier onlyFactory() {
        _onlyFactory();
        _;
    }

    function _onlyFactory() internal view {
        if (!isFactory[_msgSender()]) {
            revert Errors.InvalidSender();
        }
    }

    /// Override from BoundRegistry
    function _lccMarket(address lcc) internal view override returns (bytes32 id, address factory) {
        Market memory market = s.lccToMarket[lcc];
        return (market.id, market.factory);
    }

    /// Override from BoundRegistry
    function setBoundLevel(address who, uint8 level) external override onlyFactory {
        _setBoundLevel(msg.sender, who, level);
    }

    /// Override from BoundRegistry
    function setBoundLevels(address[] calldata who, uint8 level) external override onlyFactory {
        for (uint256 i = 0; i < who.length; i++) {
            _setBoundLevel(msg.sender, who[i], level);
        }
    }

    /**
     * @notice Modifier to ensure the provided LCC address is valid
     * @param lcc The LCC token address to validate
     */
    modifier onlyValidLcc(address lcc) {
        LiquidityHubLib.assertValidLcc(s, lcc);
        _;
    }

    /**
     * @notice Modifier to restrict access to issuers of a specific LCC token
     * @param lcc The LCC token address to check issuer status for
     */
    modifier onlyIssuer(address lcc) {
        _onlyIssuer(lcc);
        _;
    }

    function _onlyIssuer(address lcc) internal view {
        // Strict invariant: issuer-gated paths must never operate on invalid/uninitialised LCCs.
        LiquidityHubLib.assertValidLcc(s, lcc);
        if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
            revert Errors.NotApproved(msg.sender);
        }
    }

    // ============ PUBLIC ACCESSORS ============

    /**
     * @notice Returns the LCC token address for a given market and underlying asset
     * @param marketId The market ID
     * @param underlying The underlying asset address
     * @return The LCC token address, or address(0) if not found
     */
    function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
        return s.marketUnderlyingToLCC[marketId][underlying];
    }

    /**
     * @notice Returns the underlying asset address for a given LCC token
     * @param lcc The LCC token address
     * @return The underlying asset address (address(0) for native ETH)
     */
    function lccToUnderlying(address lcc) public view returns (address) {
        return s.lccToUnderlying[lcc];
    }

    /**
     * @notice Returns the Market struct for a given LCC token
     * @param lcc The LCC token address
     * @return The Market struct containing factory, id, ref, and refIsValidIssuer
     */
    function lccToMarket(address lcc) external view returns (bytes32, address) {
        return _lccMarket(lcc);
    }

    /**
     * @notice
     * @param lcc The LCC token address
     * @return The Market struct containing factory, id, ref, and refIsValidIssuer
     */
    function getFactory(address lcc0, address lcc1) external view returns (IMarketFactory) {
        address factory0 = s.lccToMarket[lcc0].factory;
        address factory1 = s.lccToMarket[lcc1].factory;
        if (factory0 != factory1) {
            revert Errors.InvariantViolated("LCCs are not from the same market");
        }
        return IMarketFactory(factory0);
    }

    /**
     * @notice Checks if an address is an issuer for a given LCC token
     * @param lcc The LCC token address
     * @param issuer The address to check
     * @return True if the address is an issuer, false otherwise
     */
    function issuers(address lcc, address issuer) external view returns (bool) {
        return s.issuers[lcc][issuer];
    }

    /**
     * @notice Gets the LCC token address for a given market and underlying asset
     * @param marketId The market ID
     * @param underlying The underlying asset address
     * @return The LCC token address
     */
    function getLCC(bytes32 marketId, address underlying) external view returns (address) {
        return LCCFactoryLib.getLCC(s, marketId, underlying);
    }

    /**
     * @notice Gets the underlying asset address for a given LCC token
     * @param lccToken The LCC token address
     * @return The underlying asset address
     */
    function getUnderlying(address lccToken) external view returns (address) {
        return LCCFactoryLib.getUnderlying(s, lccToken);
    }

    /**
     * @notice Checks if an address is a valid LCC token
     * @param lcc The address to check
     * @return True if the address is a valid LCC token, false otherwise
     */
    function isLCC(address lcc) external view returns (bool) {
        return LCCFactoryLib.isValidLcc(s, lcc);
    }

    /**
     * @notice Returns the direct supply (wrapped underlying) for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of direct supply
     */
    function directSupply(address lcc) external view returns (uint256) {
        return s.directSupply[lcc];
    }

    /**
     * @notice Returns the shared reserve of underlying assets for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of underlying assets held in reserve for this LCC
     */
    function reserveOfUnderlying(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
        return s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
    }

    /**
     * @notice Returns the queued settlement amount for a specific LCC and recipient
     * @param lcc The LCC token address
     * @param recipient The recipient address
     * @return The amount queued for settlement
     */
    function settleQueue(address lcc, address recipient) external view returns (uint256) {
        return s.settleQueue[lcc][recipient];
    }

    /**
     * @notice Returns the total queued settlement amount for a given LCC token
     * @param lcc The LCC token address
     * @return The total amount queued across all recipients
     */
    function totalQueued(address lcc) external view returns (uint256) {
        return s.totalQueued[lcc];
    }

    // ============ ADMIN FUNCTIONS ============

    /**
     * @notice Sets or removes a factory address from the allowed factories list
     * @param factory The factory address to enable or disable
     * @param enabled Whether the factory should be enabled (true) or disabled (false)
     */
    function setFactory(address factory, bool enabled) external onlyOwner {
        isFactory[factory] = enabled;
        emit FactorySet(factory, enabled);
    }

    /**
     * @notice Creates LCC token pair for a market
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param underlyingAsset0 The first underlying asset address
     * @param underlyingAsset1 The second underlying asset address
     * @param marketName The market name
     * @param initialIssuers Array of addresses to set as issuers for both LCC tokens
     * @return lccToken0 The first LCC token address
     * @return lccToken1 The second LCC token address
     */
    function createLCCPair(
        bytes memory marketRef,
        address underlyingAsset0,
        address underlyingAsset1,
        string memory marketName,
        address[] memory initialIssuers
    ) external onlyFactory returns (address lccToken0, address lccToken1) {
        address resilientOracleAddress = oracleHelper.oracle();
        address factory = _msgSender();
        address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
        lccToken0 = LCCFactoryLinkedLib.createLCC(
            s, marketRef, underlyingPair, 0, marketName, initialIssuers, address(this), factory, resilientOracleAddress
        );
        lccToken1 = LCCFactoryLinkedLib.createLCC(
            s, marketRef, underlyingPair, 1, marketName, initialIssuers, address(this), factory, resilientOracleAddress
        );

        // Emit events for LCC creation
        emit LCCCreated(underlyingAsset0, lccToken0, s.lccToMarket[lccToken0].id);
        emit LCCCreated(underlyingAsset1, lccToken1, s.lccToMarket[lccToken1].id);
    }

    /**
     * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
     * @dev Order-insensitive: `lccToken0` and `lccToken1` are treated independently; no `(0,1)` lane semantics exist here.
     *      Canonical market ordering (for pair lanes) is defined by the core pool key in `MarketFactory`, not by argument order.
     * @param lccToken0 The first LCC token address
     * @param lccToken1 The second LCC token address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param marketRef The market reference (bytes from proxyHookAddress)
     */
    function initialize(address lccToken0, address lccToken1, bytes32 marketId, bytes memory marketRef)
        external
        onlyFactory
    {
        LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, _msgSender());
    }

    // ============ INTERNAL HELPERS (delegate to library) ============

    /**
     * @notice Checks if the current caller is an issuer for a given LCC token
     * @param lcc The LCC token address
     * @return True if the caller is an issuer, false otherwise
     */
    function _isCallerIssuer(address lcc) internal view returns (bool) {
        return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
    }

    /**
     * @notice Checks if an address is a valid LCC token
     * @param lcc The address to check
     * @return True if the address is a valid LCC token, false otherwise
     */
    function _isValidLcc(address lcc) internal view returns (bool) {
        return LCCFactoryLib.isValidLcc(s, lcc);
    }

    /**
     * @notice Mints LCC tokens to an address
     * @param lccToken The LCC token address
     * @param to The address to mint tokens to
     * @param directAmount The amount to mint as direct supply
     * @param marketAmount The amount to mint as market-derived supply
     */
    function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
        LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
    }

    /**
     * @notice Burns LCC tokens from an address
     * @param lccToken The LCC token address
     * @param from The address to burn tokens from
     * @param directAmount The amount to burn from direct supply
     * @param marketAmount The amount to burn from market-derived supply
     */
    function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
        LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
    }

    /**
     * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
     * @param lccToken The LCC token address
     * @param account The account address
     * @return The total balance
     */
    function _balanceOf(address lccToken, address account) internal view returns (uint256) {
        return LCCFactoryLib.balanceOf(lccToken, account);
    }

    /**
     * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
     * @param lccToken The LCC token address
     * @param account The account address
     * @return wrapped The wrapped (direct) balance
     * @return marketDerived The market-derived balance
     */
    function _balancesOf(address lccToken, address account)
        internal
        view
        returns (uint256 wrapped, uint256 marketDerived)
    {
        return LCCFactoryLib.balancesOf(lccToken, account);
    }

    // ============ TRADER FUNCTIONS ============

    // DirectLPs and Traders engaging the CorePool directly will need LCC. LCC is 1:1 with the underlying asset.
    /**
     * @dev Internal function to wrap underlying assets into LCC tokens
     * @param lcc The LCC token address to wrap into
     * @param to The address receiving the LCC tokens
     * @param amount The amount of underlying assets to wrap
     */
    function _wrap(address lcc, address to, uint256 amount) internal onlyValidLcc(lcc) {
        address from = _msgSender();
        address underlying = s.lccToUnderlying[lcc];
        bool isNativeAsset = underlying == address(0);
        // throw error if the native ETH is insufficient and it is a native ETH backed LCC
        if (isNativeAsset) {
            if (msg.value != amount) {
                revert Errors.InvalidAmount(0, 0);
            }
        } else {
            // Use CurrencyTransfer which has Permit2 fallback for ERC20 transfers
            Currency.wrap(underlying).transferFrom(from, address(this), amount);
        }

        s.directSupply[lcc] += amount;
        s.reserveOfUnderlying[underlying] += amount;

        // mint some tokens
        _mint(lcc, to, amount, 0);

        emit LccWrapped(lcc, from, to, amount);
    }

    function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
        _wrap(lcc, to, amount);
    }

    /**
     * @notice Wraps underlying assets into LCC tokens and sends them to a specified recipient
     * @param underlying The underlying asset address
     * @param marketId The market ID
     * @param to The recipient address
     * @param amount The amount of underlying assets to wrap
     */
    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
        _wrap(s.marketUnderlyingToLCC[marketId][underlying], to, amount);
    }

    /**
     * @notice Wraps underlying assets into LCC tokens for the caller
     * @param lcc The LCC token address
     * @param amount The amount of underlying assets to wrap
     */
    function wrap(address lcc, uint256 amount) external payable nonReentrant {
        _wrap(lcc, _msgSender(), amount);
    }

    /**
     * @notice Wraps underlying assets into LCC tokens for the caller (overloaded with underlying and marketId)
     * @param underlying The underlying asset address
     * @param marketId The market ID
     * @param amount The amount of underlying assets to wrap
     */
    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
        _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), amount);
    }

    /**
     * @notice Internal function to wrap LCC using another LCC as backing, with O(1) flattening and netting
     * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
     * @param lcc The target LCC token address
     * @param withLCC The backing LCC token address
     * @param to The address receiving the target LCC
     * @param amount The amount to wrap
     */
    function _wrapWith(address lcc, address withLCC, address to, uint256 amount) internal onlyValidLcc(lcc) {
        address from = _msgSender();

        // Performs all necessary validation and preparation
        LiquidityHubLib.WrapWithContext memory ctx = LiquidityHubLib.wrapWithPrepare(s, lcc, withLCC, from, amount);
        // Pull backing LCC from caller into the Hub first.
        Currency.wrap(withLCC).transferFrom(from, address(this), ctx.originalAmount);
        // Executes the full wrap-with operation using the provided context
        LiquidityHubLib.wrapWithContext(s, lcc, withLCC, ctx);
        // Extract return values.
        // Note: wrapWithContext is designed to conserve amounts. Any mismatch is a logic bug in the library.
        uint256 directToMint = ctx.directToMint;
        uint256 marketToMint = ctx.marketToMint;

        // Final mint: mint target LCC with appropriate direct/market-derived split
        LCCFactoryLib.mint(lcc, to, directToMint, marketToMint);

        if (ctx.queuedShortfall > 0) {
            // Ensure the queued settlement event is emitted
            emit SettlementQueued(withLCC, address(this), ctx.queuedShortfall);
        }

        emit LccWrappedWith(lcc, withLCC, from, to, amount);
    }

    /**
     * @notice Wraps LCC using another LCC as backing for the caller
     * @param lcc The target LCC token address
     * @param withLCC The backing LCC token address
     * @param amount The amount to wrap
     */
    function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
        _wrapWith(lcc, withLCC, _msgSender(), amount);
    }

    /**
     * @notice Wraps LCC using another LCC as backing and sends to a specified recipient
     * @param lcc The target LCC token address
     * @param withLCC The backing LCC token address
     * @param to The recipient address
     * @param amount The amount to wrap
     */
    function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
        _wrapWith(lcc, withLCC, to, amount);
    }

    /**
     * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
     * @dev Accounts should only be able to unwrap if they have LCC in their wallet
     * @param lcc The LCC token address to unwrap
     * @param to The recipient of the underlying asset
     * @param queueTo The address to queue shortfall to
     * @param amount The amount to unwrap
     */
    function _unwrap(address lcc, address to, address queueTo, uint256 amount) internal onlyValidLcc(lcc) {
        address from = _msgSender();
        (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
        uint256 fromBalance = wrappedBalance + marketDerivedBalance;

        if (amount == 0 || amount > fromBalance) {
            revert Errors.InvalidAmount(amount, fromBalance);
        }

        (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) =
            LiquidityHubLib.unwrapInternalLogic(s, lcc, queueTo, amount, wrappedBalance, marketDerivedBalance);

        // `unwrapInternalLogic` updates queue state directly in library storage.
        // Validate queue recipient here so invalid recipients revert atomically and roll back queue writes.
        if (queuedShortfall > 0) {
            _assertQueueRecipientServiceable(lcc, queueTo, queuedShortfall, true);
        }

        // Burn the amount that was unwrapped
        // and transfer the underlying assets to the account
        if (directUnwrapped + marketUnwrapped > 0) {
            _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
        }
        if (queuedShortfall > 0) {
            emit SettlementQueued(lcc, queueTo, queuedShortfall);
        }

        emit LccUnwrapped(lcc, from, to, amount);
    }

    /**
     * @notice Unwraps LCC tokens back to underlying assets for the caller
     * @param lcc The LCC token address to unwrap
     * @param amount The amount of LCC tokens to unwrap
     */
    function unwrap(address lcc, uint256 amount) external nonReentrant {
        _unwrap(lcc, _msgSender(), _msgSender(), amount);
    }

    /**
     * @notice Unwraps LCC tokens back to underlying assets for the caller (overloaded with underlying and marketId)
     * @param underlying The underlying asset address
     * @param marketId The market ID
     * @param amount The amount of LCC tokens to unwrap
     */
    function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
        _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    /**
     * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient
     * @param lcc The LCC token address to unwrap
     * @param to The recipient address
     * @param amount The amount of LCC tokens to unwrap
     */
    function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
        // Backwards-compatible: queue shortfalls to the same address receiving the underlying.
        _unwrap(lcc, to, to, amount);
    }

    /**
     * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient, while queueing any
     *         unfulfilled portion to a separate queue owner.
     * @dev This exists for protocol flows (e.g. MMPM) where "who receives underlying now" differs from "who owns the
     *      settlement queue claim".
     * @param lcc The LCC token address to unwrap
     * @param to The recipient address for underlying
     * @param queueTo The address to attribute any queued settlement to
     * @param amount The amount of LCC tokens to unwrap
     */
    function unwrapTo(address lcc, address to, address queueTo, uint256 amount) external nonReentrant {
        _unwrap(lcc, to, queueTo, amount);
    }

    /**
     * @notice Unwraps LCC tokens back to underlying assets and sends them to a specified recipient (overloaded)
     * @param underlying The underlying asset address
     * @param marketId The market ID
     * @param to The recipient address
     * @param amount The amount of LCC tokens to unwrap
     */
    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
        _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, to, amount);
    }

    /**
     * @notice Unwraps LCC tokens (resolved by underlying+marketId) to underlying assets, while queueing any unfulfilled
     *         portion to a separate queue owner.
     * @param underlying The underlying asset address
     * @param marketId The market ID
     * @param to The recipient address for underlying
     * @param queueTo The address to attribute any queued settlement to
     * @param amount The amount of LCC tokens to unwrap
     */
    function unwrapTo(address underlying, bytes32 marketId, address to, address queueTo, uint256 amount)
        external
        nonReentrant
    {
        _unwrap(s.marketUnderlyingToLCC[marketId][underlying], to, queueTo, amount);
    }

    // ============ LIQUIDITY FUNCTIONS ============

    /**
     * @notice Returns the available liquidity in the market for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of liquidity available in the market (0 if market doesn't exist)
     */
    function marketLiquidity(address lcc) public view returns (uint256) {
        Market memory market = s.lccToMarket[lcc];
        return
            market.id != bytes32(0)
                ? IMarketFactory(market.factory).marketLiquidity(s.lccToUnderlying[lcc], market.id)
                : 0;
    }

    // ============ ISSUER FUNCTIONS ============

    /**
     * @notice Issues LCC tokens (mints to issuer)
     * @param lcc The LCC token address to issue for
     * @param amount The amount to issue
     */
    function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) nonReentrant {
        // Note: LCC mint path reverts on zero (direct+market) amount.
        _mint(lcc, to, 0, amount);
    }

    /**
     * @notice Cancels LCC tokens (burns from specified address)
     * @param lcc The LCC token address to cancel for
     * @param from The address to cancel tokens from
     * @param amount The amount to cancel
     */
    function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) nonReentrant {
        // Note: LCC burn path reverts on zero (direct+market) amount.
        _burn(lcc, from, 0, amount);
    }

    /**
     * @notice Cancels LCC tokens and queues a settlement for the shortfall
     * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity
     * @param lcc The LCC token address to cancel for
     * @param from The address to cancel tokens from
     * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
     * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
     * @param recipient The recipient address for the queued settlement
     */
    function cancelWithQueue(
        address lcc,
        address from,
        uint256 principalAmount,
        uint256 queueAmount,
        address recipient
    ) public onlyIssuer(lcc) nonReentrant {
        if (principalAmount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        if (queueAmount > principalAmount) {
            revert Errors.InvalidAmount(queueAmount, principalAmount);
        }
        _cancelWithQueue(lcc, from, principalAmount, queueAmount, recipient);
    }

    /**
     * @notice Queues settlement for a recipient after issuer-side deficit transfer.
     * @dev Security checks:
     *      - recipient must be non-zero
     *      - recipient must not be bucket-exempt (external settlement path requires market-derived balance accounting)
     *      - recipient must hold sufficient market-derived LCC to back the queued amount
     */
    function queueForTransferRecipient(address lcc, address recipient, uint256 amount)
        external
        onlyIssuer(lcc)
        nonReentrant
    {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        // Deficit queues must target a serviceable external recipient (Hub queueing is not allowed on this path).
        _assertQueueRecipientServiceable(lcc, recipient, amount, false);
        _queueSettlement(lcc, recipient, amount);
    }

    /**
     * @dev Internal implementation of cancelWithQueue without access control
     * @param lcc The LCC token address
     * @param from The address to cancel tokens from
     * @param principalAmount The total principal amount being cancelled (cancellable amount is burned from `from`)
     * @param queueAmount The amount to queue for settlement (portion of principalAmount queued for `recipient`)
     * @param recipient The recipient of the queued settlement
     */
    function _cancelWithQueue(
        address lcc,
        address from,
        uint256 principalAmount,
        uint256 queueAmount,
        address recipient
    ) internal {
        uint256 cancelAmount = principalAmount - queueAmount;

        // Burn the cancellable portion of the principal amount from the sender.
        // Burn against the sender's actual bucket split (market-derived first, then wrapped).
        // Note: allow cancelAmount == 0 (principal fully queued) without reverting.
        if (cancelAmount > 0) {
            _safeBurn(lcc, from, cancelAmount);
        }

        // Queue a portion for settlement to the specified recipient (no-op for queueAmount == 0)
        _queueSettlement(lcc, recipient, queueAmount);
    }

    /**
     * @dev Burns against a holder's bucket split (market-derived first, then wrapped).
     * - Bucket-exempt recipients can burn without bucket accounting.
     * - If `balancesOf` is unavailable (e.g. reentrancy tests that stub LCC), fall back to a full burn.
     */
    function _safeBurn(address lcc, address from, uint256 amount) internal {
        if (amount == 0) return;

        if (Bounds.isExempt(boundLevelOfLcc(lcc, from))) {
            _burn(lcc, from, 0, amount);
            return;
        }

        // IMPORTANT: Some reentrancy-hardening tests replace the LCC code (vm.etch) with a minimal stub that
        // does not implement balancesOf; in that case we must still proceed to the burn to exercise the guard.
        uint256 wrappedBal;
        uint256 marketBal;
        bool hasBuckets = true;
        try ILCC(lcc).balancesOf(from) returns (uint256 wrapped, uint256 market) {
            wrappedBal = wrapped;
            marketBal = market;
        } catch {
            hasBuckets = false;
        }

        if (!hasBuckets) {
            _burn(lcc, from, 0, amount);
            return;
        }

        uint256 burnMarket = Math.min(marketBal, amount);
        uint256 remaining = amount - burnMarket;
        uint256 burnDirect = Math.min(wrappedBal, remaining);
        _burn(lcc, from, burnDirect, burnMarket);
    }

    /**
     * @notice Plans a cancel operation to be executed on a specific transfer path
     * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to)
     * @param lcc The LCC token address
     * @param sender The expected sender of the transfer (e.g., poolManager)
     * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
     * @param amount The amount to cancel
     */
    function planCancel(address lcc, address sender, address cancelFromRecipient, uint256 amount)
        external
        onlyIssuer(lcc)
        nonReentrant
    {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        // Store the planned cancel in transient storage
        TransientSlots.setPlanCancel(lcc, sender, cancelFromRecipient, amount);
    }

    /**
     * @notice Plans a cancel with queue operation to be executed on a specific transfer path
     * @dev Stores cancellation parameters in transient storage, keyed by transfer path (lcc, from, to)
     * @param lcc The LCC token address
     * @param sender The expected sender of the transfer (e.g., poolManager)
     * @param cancelFromRecipient The expected recipient of the transfer (e.g., MMPM owner)
     * @param principalAmount Total amount to cancel (burn now) or queue (burn later)
     * @param queueAmount The amount to queue for settlement (must be <= principalAmount)
     * @param recipient The recipient address for the queued settlement
     */
    function planCancelWithQueue(
        address lcc,
        address sender,
        address cancelFromRecipient,
        uint256 principalAmount,
        uint256 queueAmount,
        address recipient
    ) external onlyIssuer(lcc) nonReentrant {
        if (principalAmount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        if (queueAmount > principalAmount) {
            revert Errors.InvalidAmount(queueAmount, principalAmount);
        }

        // Store the planned cancel with queue in transient storage
        TransientSlots.setPlanCancelWithQueue(lcc, sender, cancelFromRecipient, principalAmount, queueAmount, recipient);
    }

    /**
     * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
     * @param lcc The LCC token address
     * @param amount The amount of underlying liquidity taken
     * @param shouldEmit Whether to emit LiquidityAvailable event
     */
    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
        // INTENT:
        // `confirmTake()` must be callable from within higher-level flows that themselves may be `nonReentrant`
        // (e.g. `useMarketLiquidity()` eventually triggering a vault -> hub callback).
        // We therefore DO NOT apply `nonReentrant` here; instead, we enforce a strict balance-backed invariant
        // so callers cannot "fabricate" reserves via re-entrancy.

        address underlying = s.lccToUnderlying[lcc];

        // Track total underlying asset supply (must remain <= actual underlying balance held by this hub).
        s.reserveOfUnderlying[underlying] += amount;

        // Best-effort: settle Hub queue up to the newly available amount
        uint256 hubQueue = s.settleQueue[lcc][address(this)];
        if (hubQueue > 0) {
            _processSettlementFor(lcc, address(this), amount);
        }

        if (shouldEmit && hubQueue < amount) {
            // Only emit if there is new liquidity available and not consumed greedily by the Hub
            emit LiquidityAvailable(lcc, underlying, amount, s.lccToMarket[lcc].id);
        }

        // Balance-backed invariant: reserve accounting must never exceed actual hub holdings.
        // This protects against re-entrancy and any accidental/malicious unbacked `confirmTake` calls.
        uint256 reserve = s.reserveOfUnderlying[underlying];
        uint256 actualBalance =
            underlying == address(0) ? address(this).balance : Currency.wrap(underlying).balanceOf(address(this));
        if (reserve > actualBalance) revert Errors.InsufficientBalance(actualBalance, reserve);
    }

    /**
     * @notice Prepare settlement of underlying from Hub to MarketVault
     * @dev For ERC20, approve the caller (expected MarketVault) to pull tokens; for native, transfer ETH to caller.
     *      Decrements Hub reserve immediately; intended to be called just before settlement in the same tx.
     */
    function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
        if (amount == 0) revert Errors.InvalidAmount(0, 0);

        address underlying = s.lccToUnderlying[lcc];
        if (s.reserveOfUnderlying[underlying] < amount) {
            revert Errors.InvalidAmount(amount, s.reserveOfUnderlying[underlying]);
        }

        s.reserveOfUnderlying[underlying] -= amount;

        Currency underlyingCurrency = Currency.wrap(underlying);
        if (underlyingCurrency.isAddressZero()) {
            // For native, transfer ETH to MarketVault so it can settle to PoolManager
            underlyingCurrency.transfer(_msgSender(), amount);
        } else {
            // Approve MarketVault to pull the ERC20 from the Hub and settle to PoolManager
            underlyingCurrency.approve(_msgSender(), amount);
        }
    }

    /**
     * @notice Process settlement for a specific recipient using reserveOfUnderlying
     * @dev Permissionless function that allows anyone to process settlements when liquidity is available.
     *      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
     *      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
     *      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
     * @param lcc The LCC token address
     * @param recipient The recipient address to settle for (address(this) for Hub's own queue)
     * @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
     */
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount)
        external
        onlyValidLcc(lcc)
        nonReentrant
    {
        _processSettlementFor(lcc, recipient, maxAmount);
    }

    /**
     * @notice Internal function to process settlement for a specific recipient
     * @dev Delegates to LiquidityHubLib.processSettlementLogic
     * @param lcc The LCC token address
     * @param recipient The recipient address to settle for
     * @param maxAmount The maximum amount to settle
     */
    function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
        uint256 queuedBefore = s.settleQueue[lcc][recipient];
        LiquidityHubLib.processSettlementLogic(s, lcc, recipient, maxAmount);
        uint256 queuedAfter = s.settleQueue[lcc][recipient];
        uint256 settled = queuedBefore > queuedAfter ? queuedBefore - queuedAfter : 0;
        if (settled > 0) {
            emit SettlementProcessed(lcc, recipient, settled);
        }
    }

    // -----------------------------------
    // LCC triggered functions
    // -----------------------------------

    /// @notice Called by LCC on transfer to execute any planned cancellations
    function executePlannedCancel(address sender, address cancelFromRecipient) external onlyValidLcc(_msgSender()) {
        address lcc = _msgSender();

        // Check for planned cancel with queue first (more specific)
        (uint256 principalAmount, uint256 queueAmount, address queueRecipient) =
            TransientSlots.consumePlanCancelWithQueue(lcc, sender, cancelFromRecipient);

        if (principalAmount > 0) {
            // _cancelWithQueue handles principal == queue (burn 0, queue all) and principal > queue.
            // Use internal function to bypass onlyIssuer check (LCC is the caller, not an issuer).
            _cancelWithQueue(lcc, cancelFromRecipient, principalAmount, queueAmount, queueRecipient);
            return;
        }

        // Check for simple planned cancel
        uint256 amount = TransientSlots.consumePlanCancel(lcc, sender, cancelFromRecipient);
        if (amount > 0) {
            _safeBurn(lcc, cancelFromRecipient, amount);
        }
    }

    /// @notice Annuls queued settlement before a protocol-bound transfer
    function annulSettlementBeforeTransfer(
        address from,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance,
        uint256 amountToTransfer
    ) external onlyValidLcc(_msgSender()) {
        address lcc = _msgSender();

        uint256 queued = s.settleQueue[lcc][from];
        // Even if queued == 0 or amountToTransfer == 0, the logic below is a no-op.
        // We intentionally avoid an early return here to keep the control flow simpler and more auditable.

        uint256 liquidBalance = wrappedBalance + marketDerivedBalance;

        // Otherwise, if amountToTransfer > (liquidBalance - queued), it bleeds into queue
        // Compute max transferable without touching queue
        uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
        if (amountToTransfer > transferableWithoutQueue) {
            uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
            uint256 toAnnul = Math.min(bleedIntoQueue, queued);
            // Safe: toAnnul <= queued and subtracting 0 is a no-op.
            s.settleQueue[lcc][from] -= toAnnul;
            s.totalQueued[lcc] -= toAnnul;
            if (toAnnul > 0) {
                emit SettlementAnnulled(lcc, from, toAnnul);
            }
        }
    }

    // ============ SETTLEMENT FUNCTIONS ============

    /**
     * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
     * @param lcc The LCC token address
     * @param owner The owner of the LCC tokens to burn
     * @param to The recipient of the underlying assets
     * @param fromDirect The amount of LCC to burn from direct supply
     * @param fromMarket The amount of LCC to burn from market-derived supply
     */
    function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
        LiquidityHubLib.pay(s, lcc, owner, to, fromDirect, fromMarket);
    }

    /**
     * @dev Adds a settlement request to the queue
     * @param lcc The LCC token address
     * @param recipient The address with pending settlements
     * @param amount The amount to eventually settle
     */
    function _assertQueueRecipientServiceable(address lcc, address recipient, uint256 amount, bool allowHub)
        internal
        view
    {
        if (recipient == address(0)) {
            revert Errors.InvalidAddress(recipient);
        }

        if (recipient == address(this)) {
            if (!allowHub) revert Errors.NotApproved(recipient);
            return;
        }

        // External settlement queues are only serviceable for bucket-tracked recipients.
        if (Bounds.isExempt(boundLevelOfLcc(lcc, recipient))) {
            revert Errors.NotApproved(recipient);
        }

        (, uint256 marketDerivedBalance) = ILCC(lcc).balancesOf(recipient);
        if (marketDerivedBalance < amount) {
            revert Errors.InsufficientBalance(marketDerivedBalance, amount);
        }
    }

    function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
        if (amount == 0) return;
        // Shared guard for all queue creation paths (cancel-with-queue, planned cancel execution, unwrap shortfalls).
        _assertQueueRecipientServiceable(lcc, recipient, amount, true);
        LiquidityHubLib.queueSettlement(s, lcc, recipient, amount);
        emit SettlementQueued(lcc, recipient, amount);
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Validates that the sender is the canonical vault for a native-backed market
     * @dev Reverts if sender identity is not canonical for the market derived from returned LCCs
     */
    function _assertValidEthSender() internal view {
        address sender = _msgSender();
        if (sender.code.length == 0) revert Errors.InvalidEthSender();

        address l0;
        address l1;
        // Prefer a typed call + try/catch over low-level staticcall probing.
        try IMarketVault(sender).lccs() returns (address _l0, address _l1) {
            l0 = _l0;
            l1 = _l1;
        } catch {
            revert Errors.InvalidEthSender();
        }

        bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
        bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
        if (!valid0 || !valid1) {
            revert Errors.InvalidEthSender();
        }

        Market memory m0 = s.lccToMarket[l0];
        Market memory m1 = s.lccToMarket[l1];
        if (m0.id == bytes32(0) || m1.id == bytes32(0) || m0.id != m1.id || m0.factory != m1.factory) {
            revert Errors.InvalidEthSender();
        }
        if (!isFactory[m0.factory]) {
            revert Errors.InvalidEthSender();
        }
        if (!IMarketFactory(m0.factory).isCanonicalVault(m0.id, sender)) {
            revert Errors.InvalidEthSender();
        }

        // Require a native-backed market.
        if (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0)) {
            revert Errors.InvalidEthSender();
        }
    }

    /**
     * @notice Receives native ETH transfers from MarketVault contracts
     * @dev Only accepts transfers from valid MarketVault contracts with at least one native ETH LCC.
     *      This enables the route: PoolManager -> MarketVault -> LiquidityHub for native asset settlements.
     *      Reverts if the sender is not a valid MarketVault or if neither LCC uses native ETH as underlying.
     */
    receive() external payable {
        // plain ETH transfer must come from a market vault.
        _assertValidEthSender();
    }
}
