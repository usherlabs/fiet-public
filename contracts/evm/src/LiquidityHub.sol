// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is Ownable, ReentrancyGuardTransient {
    using CurrencyTransfer for Currency;
    using SafeERC20 for ERC20;

    // ============ UNIFIED STATE ============
    LiquidityHubStorage internal s;

    IOracleHelper public immutable oracleHelper;

    event FactorySet(address indexed factory, bool enabled);
    event LCCCreated(address indexed underlyingAsset, address indexed lccToken);
    event LiquidityAvailable(address indexed lcc, uint256 amount);
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
    event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
    event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
    event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);

    // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
    // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.

    // Map of market factories
    mapping(address => bool) public isFactory;

    constructor(
        address _oracleHelper,
        string memory _nativeAssetName,
        string memory _nativeAssetSymbol,
        uint8 _nativeAssetDecimals
    ) Ownable(msg.sender) {
        oracleHelper = IOracleHelper(_oracleHelper);
        LCCFactoryLib.initNativeAsset(s, _nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals);
    }

    modifier onlyFactory() {
        if (!isFactory[_msgSender()]) {
            revert Errors.InvalidSender();
        }
        _;
    }

    modifier onlyFactoryOrOwner() {
        if (!isFactory[_msgSender()] && _msgSender() != owner()) {
            revert Errors.InvalidSender();
        }
        _;
    }

    modifier onlyValidLcc(address lcc) {
        LiquidityHubLib.assertValidLcc(s, lcc);
        _;
    }

    modifier onlyIssuer(address lcc) {
        if (!LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender)) {
            revert Errors.NotApproved(msg.sender);
        }
        _;
    }

    // ============ PUBLIC ACCESSORS ============

    function marketUnderlyingToLCC(bytes32 marketId, address underlying) external view returns (address) {
        return s.marketUnderlyingToLCC[marketId][underlying];
    }

    function lccToUnderlying(address lcc) public view returns (address) {
        return s.lccToUnderlying[lcc];
    }

    function lccToMarket(address lcc) external view returns (Market memory) {
        return s.lccToMarket[lcc];
    }

    function issuers(address lcc, address issuer) external view returns (bool) {
        return s.issuers[lcc][issuer];
    }

    function getLCC(bytes32 marketId, address underlying) external view returns (address) {
        return LCCFactoryLib.getLCC(s, marketId, underlying);
    }

    function getUnderlying(address lccToken) external view returns (address) {
        return LCCFactoryLib.getUnderlying(s, lccToken);
    }

    function isLCC(address lcc) external view returns (bool) {
        return LCCFactoryLib.isValidLcc(s, lcc);
    }

    function directSupply(address lcc) external view returns (uint256) {
        return s.directSupply[lcc];
    }

    function reserveOfUnderlying(address underlying) external view returns (uint256) {
        return s.reserveOfUnderlying[underlying];
    }

    function settleQueue(address lcc, address recipient) external view returns (uint256) {
        return s.settleQueue[lcc][recipient];
    }

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
        address[2] memory underlyingPair = [underlyingAsset0, underlyingAsset1];
        lccToken0 =
            LCCFactoryLinkedLib.createLCC(s, _msgSender(), marketRef, underlyingPair, 0, marketName, initialIssuers);
        lccToken1 =
            LCCFactoryLinkedLib.createLCC(s, _msgSender(), marketRef, underlyingPair, 1, marketName, initialIssuers);

        // Emit events for LCC creation
        emit LCCCreated(underlyingAsset0, lccToken0);
        emit LCCCreated(underlyingAsset1, lccToken1);
    }

    /**
     * @notice Initializes the mapping from LCC tokens to Market (with ID and Ref)
     * @param lccToken0 The first LCC token address
     * @param lccToken1 The second LCC token address
     * @param marketId The market ID (corePoolKey -> PoolID -> unwrap() to bytes32)
     * @param marketRef The market reference (bytes from proxyHookAddress)
     * @param refIsValidIssuer Whether the market ref address is a valid issuer
     */
    function initialize(
        address lccToken0,
        address lccToken1,
        bytes32 marketId,
        bytes memory marketRef,
        bool refIsValidIssuer
    ) external onlyFactory {
        LCCFactoryLib.initialize(s, lccToken0, lccToken1, marketId, marketRef, refIsValidIssuer, _msgSender());
    }

    // ============ INTERNAL HELPERS (delegate to library) ============

    function _isCallerIssuer(address lcc) internal view returns (bool) {
        return LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender);
    }

    function _isValidLcc(address lcc) internal view returns (bool) {
        return LCCFactoryLib.isValidLcc(s, lcc);
    }

    function _assertValidLcc(address lcc) internal view {
        LiquidityHubLib.assertValidLcc(s, lcc);
    }

    function _mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount, bool issued) internal {
        LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount, issued);
    }

    function _burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount, bool issued) internal {
        LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount, issued);
    }

    function _balanceOf(address lccToken, address account) internal view returns (uint256) {
        return LCCFactoryLib.balanceOf(lccToken, account);
    }

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
     * @param from The address providing the underlying assets
     * @param to The address receiving the LCC tokens
     * @param amount The amount of underlying assets to wrap
     */
    function _wrap(address lcc, address from, address to, uint256 amount) internal onlyValidLcc(lcc) {
        address underlying = s.lccToUnderlying[lcc];
        bool isNativeAsset = underlying == address(0);
        // throw error if the native ETH is insufficient and it is a native ETH backed LCC
        if (isNativeAsset) {
            if (msg.value != amount) {
                revert Errors.InvalidAmount(0, 0);
            }
        } else {
            // safe to make ERC20 call here since we have verified that from address is not a native asset
            ERC20(underlying).safeTransferFrom(from, address(this), amount);
        }

        s.directSupply[lcc] += amount;
        s.reserveOfUnderlying[underlying] += amount;

        // mint some tokens
        _mint(lcc, to, amount, 0, LCCFactoryLib.isCallerIssuer(s, lcc, msg.sender));

        emit LccWrapped(lcc, from, to, amount);
    }

    function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
        _wrap(lcc, _msgSender(), to, amount);
    }

    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
        _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    function wrap(address lcc, uint256 amount) external payable nonReentrant {
        _wrap(lcc, _msgSender(), _msgSender(), amount);
    }

    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
        _wrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    /**
     * @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     * @dev Delegates to LiquidityHubLib.wrapWithLogic - heavy logic moved to library
     */
    function _wrapWith(address lcc, address withLCC, address from, address to, uint256 amount)
        internal
        onlyValidLcc(lcc)
    {
        (uint256 directToMint, uint256 marketToMint) = LiquidityHubLib.wrapWithLogic(s, lcc, withLCC, from, to, amount);
        emit LccWrappedWith(lcc, withLCC, from, to, amount);
    }

    function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
        _wrapWith(lcc, withLCC, _msgSender(), _msgSender(), amount);
    }

    function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
        _wrapWith(lcc, withLCC, _msgSender(), to, amount);
    }

    /**
     * @dev Unwraps LCC from the account's wallet and transfers underlying assets to recipient
     * @dev Accounts should only be able to unwrap if they have LCC in their wallet
     * @param lcc The LCC token address to unwrap
     * @param from The account to unwrap from
     * @param to The recipient of the underlying asset
     * @param amount The amount to unwrap
     */
    function _unwrap(address lcc, address from, address to, uint256 amount) internal onlyValidLcc(lcc) {
        (uint256 wrappedBalance, uint256 marketDerivedBalance) = _balancesOf(lcc, from);
        uint256 fromBalance = wrappedBalance + marketDerivedBalance;

        if (amount == 0 || amount > fromBalance) {
            revert Errors.InvalidAmount(amount, fromBalance);
        }

        (uint256 directUnwrapped, uint256 marketUnwrapped) =
            LiquidityHubLib.unwrapInternalLogic(s, lcc, to, amount, wrappedBalance, marketDerivedBalance);

        // Burn the amount that was unwrapped
        // and transfer the underlying assets to the account
        if (directUnwrapped + marketUnwrapped > 0) {
            _pay(lcc, from, to, directUnwrapped, marketUnwrapped);
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

    function unwrap(address underlying, bytes32 marketId, uint256 amount) external nonReentrant {
        _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
        _unwrap(lcc, _msgSender(), to, amount);
    }

    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
        _unwrap(s.marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
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
    function issue(address lcc, address to, uint256 amount) external onlyIssuer(lcc) onlyValidLcc(lcc) {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        _mint(lcc, to, 0, amount, true);
    }

    /**
     * @notice Cancels LCC tokens (burns from specified address)
     * @param lcc The LCC token address to cancel for
     * @param from The address to cancel tokens from
     * @param amount The amount to cancel
     */
    function cancel(address lcc, address from, uint256 amount) external onlyIssuer(lcc) onlyValidLcc(lcc) {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        _burn(lcc, from, 0, amount, true);
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
    ) external onlyIssuer(lcc) onlyValidLcc(lcc) {
        if (principalAmount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        if (queueAmount > principalAmount) {
            revert Errors.InvalidAmount(queueAmount, principalAmount);
        }
        uint256 cancelAmount = principalAmount - queueAmount;

        // Burn the cancelled amount (issuer burn path, skip bucket accounting)
        _burn(lcc, from, 0, cancelAmount, true);

        // Queue the settlement for future processing
        if (queueAmount > 0) {
            _queueSettlement(lcc, recipient, queueAmount);
        }
    }

    /**
     * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
     * @param lcc The LCC token address
     * @param amount The amount of underlying liquidity taken
     * @param shouldEmit Whether to emit LiquidityAvailable event
     */
    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) nonReentrant {
        // Track total underlying asset supply
        s.reserveOfUnderlying[s.lccToUnderlying[lcc]] += amount;

        // Best-effort: settle Hub queue up to the newly available amount
        uint256 hubQueue = s.settleQueue[lcc][address(this)];
        if (hubQueue > 0) {
            _processSettlementFor(lcc, address(this), amount);
        }

        if (shouldEmit && hubQueue < amount) {
            // Only emit if there is new liquidity available and not consumed greedily by the Hub
            emit LiquidityAvailable(lcc, amount);
        }
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

    function _processSettlementFor(address lcc, address recipient, uint256 maxAmount) internal {
        LiquidityHubLib.processSettlementLogic(s, lcc, recipient, maxAmount, msg.sender);
    }

    /**
     * @notice Annul a user's queued settlement prior to a protocol-bound transfer
     * @dev If the transfer amount exceeds the user's current liquid balance (wrapped + marketDerived),
     *      the excess "bleed" will be removed from their queued settlement up to the queued amount.
     * @param lcc The LCC token address
     * @param from The user initiating the transfer
     * @param amountToTransfer The amount intended to be transferred
     */
    function annulSettlementBeforeTransfer(
        address lcc,
        address from,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance,
        uint256 amountToTransfer
    ) external onlyValidLcc(lcc) {
        if (_msgSender() != lcc) {
            revert Errors.InvalidSender();
        }

        uint256 queued = s.settleQueue[lcc][from];
        if (queued == 0 || amountToTransfer == 0) {
            return;
        }

        uint256 liquidBalance = wrappedBalance + marketDerivedBalance;

        // Otherwise, if amountToTransfer > (liquidBalance - queued), it bleeds into queue
        // Compute max transferable without touching queue
        uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
        if (amountToTransfer > transferableWithoutQueue) {
            uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
            uint256 toAnnul = Math.min(bleedIntoQueue, queued);
            if (toAnnul > 0) {
                s.settleQueue[lcc][from] -= toAnnul;
                s.totalQueued[lcc] -= toAnnul;
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
        LiquidityHubLib.pay(s, lcc, owner, to, fromDirect, fromMarket, msg.sender);
    }

    /**
     * @dev Adds a settlement request to the queue
     * @param lcc The LCC token address
     * @param recipient The address with pending settlements
     * @param amount The amount to eventually settle
     */
    function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
        LiquidityHubLib.queueSettlement(s, lcc, recipient, amount);
        emit SettlementQueued(lcc, recipient, amount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Returns the shared reserve of underlying assets for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of underlying assets held in reserve for this LCC
     */
    function sharedReserveOf(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
        return s.reserveOfUnderlying[s.lccToUnderlying[lcc]];
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Validates that the sender is a valid MarketVault with at least one native asset LCC
     * @dev Reverts if the sender is not a MarketVault or if neither LCC uses native ETH as underlying
     */
    function _assertValidEthSender() internal view {
        address sender = _msgSender();
        (address l0, address l1) = IMarketVault(sender).lccs();
        bool valid0 = LCCFactoryLib.isValidLcc(s, l0);
        bool valid1 = LCCFactoryLib.isValidLcc(s, l1);
        // Revert if either asset is not an LCC OR at least one of the underlying assets is NOT native ETH
        if (!valid0 || !valid1 || (s.lccToUnderlying[l0] != address(0) && s.lccToUnderlying[l1] != address(0))) {
            revert Errors.InvalidEthSender();
        }
    }

    // Best practice: be explicit about intent
    // Plain transactions are performed by the market vault in native asset routes.
    // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
    receive() external payable {
        // plain ETH transfer must come from a market vault.
        _assertValidEthSender();
    }
}
