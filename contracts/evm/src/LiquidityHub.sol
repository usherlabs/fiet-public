// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LCCFactory} from "./modules/LCCFactory.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ReentrancyGuardTransient} from "openzeppelin-contracts/contracts/utils/ReentrancyGuardTransient.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";
import {console} from "forge-std/console.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is Ownable, LCCFactory, ReentrancyGuardTransient {
    using CurrencyTransfer for Currency;
    using SafeERC20 for ERC20;

    IOracleHelper public immutable oracleHelper;

    event FactorySet(address indexed factory, bool enabled);
    event LiquidityAvailable(address indexed lcc, uint256 amount);
    event SettlementQueued(address indexed lcc, address indexed recipient, uint256 amount);
    event LccWrappedWith(address indexed lcc, address indexed withLCC, address from, address to, uint256 amount);
    event LccWrapped(address indexed lcc, address from, address to, uint256 amount);
    event LccUnwrapped(address indexed lcc, address from, address to, uint256 amount);

    // IMPORTANT NOTE: The LiquidityHub is agnostic/unaware of the end account.
    // Similarly to how PoolManager leverages periphery contracts to manage end-account balances, the LiquidityHub aggregates balances, and uses LCCs to track account balances in a hub-and-spoke model.

    // Map of market factories
    mapping(address => bool) public isFactory;
    // Mapping from underlying token to OOM (Out-of-Market) balance of the account
    mapping(address => uint256) public directSupply;
    mapping(address => uint256) public reserveOfUnderlying; // reserve of the underlying token

    // Settlement queue mappings (no arrays to avoid clogging)
    mapping(address => mapping(address => uint256)) public settleQueue; // lcc => recipient => amount owed
    mapping(address => uint256) public totalQueued; // lcc => total amount queued
    // Lazily claimed netting against Hub queue for an LCC used as underlying during wrapWith
    // Prevents over-netting across concurrent wrapWith calls.
    mapping(address => uint256) public nettedLCCsAsUnderlying; // withLCC => claimed amount

    constructor(
        address _oracleHelper,
        string memory _nativeAssetName,
        string memory _nativeAssetSymbol,
        uint8 _nativeAssetDecimals
    ) Ownable(msg.sender) LCCFactory(_nativeAssetName, _nativeAssetSymbol, _nativeAssetDecimals) {
        oracleHelper = IOracleHelper(_oracleHelper);
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
        lccToken0 = _createLCC(_msgSender(), marketRef, underlyingPair, 0, marketName, initialIssuers);
        lccToken1 = _createLCC(_msgSender(), marketRef, underlyingPair, 1, marketName, initialIssuers);
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
        _initialize(lccToken0, lccToken1, marketId, marketRef, refIsValidIssuer, _msgSender());
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
        address underlying = lccToUnderlying[lcc];
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

        directSupply[lcc] += amount;
        reserveOfUnderlying[underlying] += amount;

        // mint some tokens
        _mint(lcc, to, amount, 0, _isCallerIssuer(lcc));

        emit LccWrapped(lcc, from, to, amount);
    }

    function wrapTo(address lcc, address to, uint256 amount) external payable nonReentrant {
        _wrap(lcc, _msgSender(), to, amount);
    }

    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable nonReentrant {
        _wrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    function wrap(address lcc, uint256 amount) external payable nonReentrant {
        _wrap(lcc, _msgSender(), _msgSender(), amount);
    }

    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable nonReentrant {
        _wrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    /**
     * @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     * @dev Strategy:
     *      - Optimise direct: transfer directSupply from withLCC to target lcc (no unwrap)
     *      - Net market-derived against Hub queue for withLCC using a lazy-claimed mapping to prevent over-netting
     *      - For residual, unwrap withLCC (consuming directSupply then market liquidity), queue shortfall if any
     *      - Mint target lcc reflecting direct vs market-derived components
     */
    function _wrapWith(address lcc, address withLCC, address from, address to, uint256 amount)
        internal
        onlyValidLcc(lcc)
    {
        uint256 originalRequestedAmount = amount;
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        // Ensure withLCC is a valid LCC and not the same token
        _assertValidLcc(withLCC);
        if (lcc == withLCC) {
            revert Errors.InvalidAddress(withLCC);
        }
        // Enforce same underlying asset for both LCCs
        if (lccToUnderlying[lcc] != lccToUnderlying[withLCC]) {
            revert Errors.UnderlyingAssetMismatch(lccToUnderlying[lcc], lccToUnderlying[withLCC]);
        }

        // Get bucketed balances of the owner to validate amount and determine unwrap priority
        (uint256 fromWrappedBalance, uint256 fromMarketDerivedBalance) = _balancesOf(withLCC, from);
        uint256 fromBalance = fromWrappedBalance + fromMarketDerivedBalance;
        if (amount > fromBalance) {
            revert Errors.InvalidAmount(amount, fromBalance);
        }
        // Priority-based: use market-derived balance first, then direct (wrapped) as remainder (mirrors LCC.sol transfer behavior)
        uint256 fromMarketDerivedAmount = Math.min(amount, fromMarketDerivedBalance);
        uint256 fromWrappedAmount = amount - fromMarketDerivedAmount;

        // Pull backing LCC from user to Hub
        // Will annul any settlement queue for the withLCC
        ERC20(withLCC).safeTransferFrom(from, address(this), amount);

        uint256 marketToMint = 0;
        uint256 directToMint = 0;

        // Track burns for consolidation (single burn call per LCC at end)
        uint256 targetToBurn = 0;
        uint256 backingToBurn = 0;

        // Step 0: Net against target LCC Hub queue (annul queue and utilise Hub-held target)
        // Instead of waiting for settlement to clear the queue (adding underlying to reserves, allowing future unwraps),
        // we annul it now and use held lcc directly. Burning withLCC ensures no net supply increase, mirroring how ProxyHook cancels LCCs during output
        // (e.g., cancelLCCWithDeficit burns LCC after taking from PoolManager).
        uint256 targetQueue = settleQueue[lcc][address(this)];
        if (targetQueue > 0) {
            uint256 hubHeldTarget = _balanceOf(lcc, address(this));
            uint256 netTarget = Math.min(amount, Math.min(targetQueue, hubHeldTarget));
            if (netTarget > 0) {
                // Consume the user's provided withLCC across buckets to reflect origin
                uint256 consumeMarket = Math.min(fromMarketDerivedAmount, netTarget);
                fromMarketDerivedAmount -= consumeMarket;
                uint256 remainingTarget = netTarget - consumeMarket;
                if (remainingTarget > 0) {
                    uint256 consumeWrapped = Math.min(fromWrappedAmount, remainingTarget);
                    fromWrappedAmount -= consumeWrapped;
                    remainingTarget -= consumeWrapped;
                }

                // Annul the target queue and track burn for target LCC
                settleQueue[lcc][address(this)] = targetQueue - netTarget;
                totalQueued[lcc] -= netTarget;
                targetToBurn = netTarget;

                // Track burn for withLCC (market-derived)
                backingToBurn += netTarget;

                // Mint target to recipient as market-derived to reflect queue origin
                marketToMint += netTarget;

                // Reduce remaining amount to process downstream
                amount -= netTarget;
            }
        }

        // Step 1: Optimise direct conversion by transferring directSupply between LCCs (no unwrap)
        if (fromWrappedAmount > 0) {
            uint256 directAvail = directSupply[withLCC];
            uint256 directConverted = Math.min(fromWrappedAmount, directAvail);
            if (directConverted > 0) {
                directSupply[withLCC] = directAvail - directConverted;
                directSupply[lcc] += directConverted;
                // Track burn for withLCC (direct)
                backingToBurn += directConverted;
                directToMint += directConverted;
            }
        }

        // Step 2: Net market-derived portion against Hub queue using lazy claimed mapping
        uint256 remainderAmount = amount - directToMint;
        if (remainderAmount > 0) {
            uint256 hubQueueForWith = settleQueue[withLCC][address(this)];
            uint256 claimed = nettedLCCsAsUnderlying[withLCC];
            uint256 effectiveQueue = hubQueueForWith > claimed ? (hubQueueForWith - claimed) : 0;
            uint256 nettable = Math.min(remainderAmount, Math.min(fromMarketDerivedAmount, effectiveQueue));
            if (nettable > 0) {
                nettedLCCsAsUnderlying[withLCC] = claimed + nettable; // lazy claim
                // Track burn for withLCC (market-derived)
                backingToBurn += nettable;
                marketToMint += nettable;
                fromMarketDerivedAmount -= nettable;
            }

            // Step 3: Unwrap residual using withLCC balances (directSupply then market liquidity)
            uint256 remainingAfterNet = remainderAmount - marketToMint;
            if (remainingAfterNet > 0) {
                // fromWrappedAmount may still include amounts not converted via direct transfer
                uint256 residualWrappedForUnwrap = fromWrappedAmount;
                if (directToMint > 0) {
                    // directToMint consumed from wrapped-origin
                    residualWrappedForUnwrap =
                        residualWrappedForUnwrap > directToMint ? (residualWrappedForUnwrap - directToMint) : 0;
                }
                (uint256 directUnwrapped, uint256 marketUnwrapped) = _unwrapInternalLogic(
                    withLCC,
                    address(this),
                    address(this),
                    remainingAfterNet,
                    residualWrappedForUnwrap,
                    fromMarketDerivedAmount
                );
                // Track burns for withLCC
                backingToBurn += directUnwrapped;
                backingToBurn += marketUnwrapped;
                // direct portion minted as direct; market and shortfall minted as market-derived
                directToMint += directUnwrapped;
                marketToMint += (remainingAfterNet - directUnwrapped);
            }
        }

        // Clamp final burns to current Hub-held balances to avoid over-burns due to external effects
        // TODO: we need to test these invariants/clamps heavily.
        uint256 targetHeld = _balanceOf(lcc, address(this));
        if (targetToBurn > targetHeld) {
            targetToBurn = targetHeld;
        }
        uint256 backingHeld = _balanceOf(withLCC, address(this));
        if (backingToBurn > backingHeld) {
            backingToBurn = backingHeld;
        }

        // Consolidate burns: single burn call per LCC
        // Passing issuer = true to skip bucket accounting.
        if (targetToBurn > 0) {
            _burn(lcc, address(this), 0, targetToBurn, true);
        }
        if (backingToBurn > 0) {
            _burn(withLCC, address(this), 0, backingToBurn, true);
        }

        // Defensive invariant clamps
        // Ensure we never mint more than originally requested
        if (directToMint + marketToMint > originalRequestedAmount) {
            // Clamp marketToMint to ensure total does not exceed request
            uint256 excess = (directToMint + marketToMint) - originalRequestedAmount;
            marketToMint = marketToMint > excess ? (marketToMint - excess) : 0;
        }
        // Ensure lazy-claimed never exceeds current queue
        {
            uint256 currentQueueWith = settleQueue[withLCC][address(this)];
            uint256 claimedWith = nettedLCCsAsUnderlying[withLCC];
            if (claimedWith > currentQueueWith) {
                nettedLCCsAsUnderlying[withLCC] = currentQueueWith;
            }
        }

        _mint(lcc, to, directToMint, marketToMint, false);

        emit LccWrappedWith(lcc, withLCC, from, to, amount);
    }

    function wrapWith(address lcc, address withLCC, uint256 amount) external nonReentrant {
        _wrapWith(lcc, withLCC, _msgSender(), _msgSender(), amount);
    }

    function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external nonReentrant {
        _wrapWith(lcc, withLCC, _msgSender(), to, amount);
    }

    /**
     * @dev Internal logic for unwrapping LCC
     * @param lcc The LCC token address
     * @param from The account to unwrap from
     * @param to The recipient of the underlying asset
     * @param amount The amount to unwrap
     * @param wrappedBalance The wrapped balance of the account
     * @param marketDerivedBalance The market-derived balance of the account
     * @return directUnwrapped The amount unwrapped from direct supply
     * @return marketUnwrapped The amount unwrapped from market liquidity
     */
    function _unwrapInternalLogic(
        address lcc,
        address from,
        address to,
        uint256 amount,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance
    ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped) {
        // 1) Consume directSupply[lcc] if available
        if (wrappedBalance > 0) {
            uint256 directAvail = directSupply[lcc];
            directUnwrapped = Math.min(Math.min(amount, wrappedBalance), directAvail);
            if (directUnwrapped > 0) {
                // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                directSupply[lcc] = directAvail - directUnwrapped;
            }
        }

        // 2) Pull from market liquidity; increases reserves later via confirmTake callbacks
        uint256 remainingToUnwrap = amount - directUnwrapped;
        if (remainingToUnwrap > 0 && marketDerivedBalance > 0) {
            // Get the max amount that can be unwrapped from this market
            uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);

            // Unwrap from this market's liquidity
            marketUnwrapped = _useMarketLiquidity(lcc, requestFromMarket);

            remainingToUnwrap -= marketUnwrapped;
        }

        // 3) Queue any shortfall to Hub itself for later processing
        if (remainingToUnwrap > 0) {
            // When we unwrap, we first use whatever liquidity is directly wrapped.
            // Then, we turn to liquidity either directly in the market or pending settlement to the market in the future.
            // If there's deficit between the amount to unwrap from market and the amount available, then we're in an insufficient liquidity situation and we queue a settlement
            _queueSettlement(lcc, to, remainingToUnwrap);
        }
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
            _unwrapInternalLogic(lcc, from, to, amount, wrappedBalance, marketDerivedBalance);

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
        _unwrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    function unwrapTo(address lcc, address to, uint256 amount) external nonReentrant {
        _unwrap(lcc, _msgSender(), to, amount);
    }

    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external nonReentrant {
        _unwrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    // ============ LIQUIDITY FUNCTIONS ============

    /**
     * @notice Returns the available liquidity in the market for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of liquidity available in the market (0 if market doesn't exist)
     */
    function marketLiquidity(address lcc) public view returns (uint256) {
        return lccToMarket[lcc].id != bytes32(0)
            ? IMarketFactory(lccToMarket[lcc].factory).marketLiquidity(lccToUnderlying[lcc], lccToMarket[lcc].id)
            : 0;
    }

    /**
     * @dev Requests liquidity from a specific market's reserves via the MarketFactory
     * @notice OOM vs IM Distinction: When acquiring LCCs from a market, it's underlying liquidity either in the market, or to be settled to the market.
     * @param lcc The LCC token address
     * @param amount The amount of liquidity to request from the market
     * @return The amount actually provided by the market
     */
    function _useMarketLiquidity(address lcc, uint256 amount) internal returns (uint256) {
        bytes32 marketId = lccToMarket[lcc].id;
        return IMarketFactory(lccToMarket[lcc].factory).useMarketLiquidity(lccToUnderlying[lcc], marketId, amount);
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
     * @notice Cancels LCC tokens (burns from issuer)
     * @param lcc The LCC token address to cancel for
     * @param amount The amount to cancel
     */
    function cancel(address lcc, uint256 amount) external onlyIssuer(lcc) onlyValidLcc(lcc) {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        address issuer = _msgSender();
        _burn(lcc, issuer, 0, amount, true);
    }

    /**
     * @notice Cancels LCC tokens and queues a settlement for the shortfall
     * @dev Simulates unwrap-with-queue without touching direct supply or market liquidity
     * @param lcc The LCC token address to cancel for
     * @param cancelAmount The amount to cancel (burn)
     * @param queueAmount The amount to queue for settlement (must be <= cancelAmount)
     * @param recipient The recipient address for the queued settlement
     */
    function cancelWithQueue(address lcc, uint256 cancelAmount, uint256 queueAmount, address recipient)
        external
        onlyIssuer(lcc)
        onlyValidLcc(lcc)
    {
        if (cancelAmount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }
        if (queueAmount > cancelAmount) {
            revert Errors.InvalidAmount(queueAmount, cancelAmount);
        }

        address issuer = _msgSender();
        // Burn the cancelled amount (issuer burn path, skip bucket accounting)
        _burn(lcc, issuer, 0, cancelAmount, true);

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
        reserveOfUnderlying[lccToUnderlying[lcc]] += amount;

        // Best-effort: settle Hub queue up to the newly available amount
        uint256 hubQueue = settleQueue[lcc][address(this)];
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

        address underlying = lccToUnderlying[lcc];
        if (reserveOfUnderlying[underlying] < amount) {
            revert Errors.InvalidAmount(amount, reserveOfUnderlying[underlying]);
        }

        reserveOfUnderlying[underlying] -= amount;

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
        bool isForHub = recipient == address(this);
        uint256 queued = settleQueue[lcc][recipient];
        if (queued == 0) revert Errors.InvalidAmount(0, 0);

        address underlying = lccToUnderlying[lcc];
        uint256 available = reserveOfUnderlying[underlying];

        uint256 holderBal = 0;
        if (isForHub) {
            // Hub-specific path: burn Hub-held LCC against available reserves
            // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
            // Note: This path should only really occur when LCCs back LCCs (via _wrapWith).
            holderBal = _balanceOf(lcc, recipient);
        } else {
            // Standard path for external recipients
            // market-derived holder balance
            (, holderBal) = _balancesOf(lcc, recipient);
        }

        uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
        if (toSettle == 0) {
            if (!isForHub) {
                revert Errors.LiquidityError(lcc, toSettle);
            }
            return;
        }

        settleQueue[lcc][recipient] -= toSettle;
        totalQueued[lcc] -= toSettle;

        if (isForHub) {
            // Reconcile lazy netted claims first, then burn only unclaimed portion
            uint256 claimed = nettedLCCsAsUnderlying[lcc];
            uint256 decrement = Math.min(claimed, toSettle);
            if (decrement > 0) {
                nettedLCCsAsUnderlying[lcc] = claimed - decrement;
            }
            // Burn the remaining amount after _wrapWith lazy netting (burning) has been accounted for.
            uint256 effectiveToBurn = toSettle - decrement;

            if (effectiveToBurn > 0) {
                // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
                _burn(lcc, recipient, 0, effectiveToBurn, true);
            }
        } else {
            _pay(lcc, recipient, recipient, 0, toSettle);
        }
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

        uint256 queued = settleQueue[lcc][from];
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
                settleQueue[lcc][from] -= toAnnul;
                totalQueued[lcc] -= toAnnul;
            }
        }
    }

    // ============ SETTLEMENT FUNCTIONS ============

    /**
     * @dev Transfers underlying assets to an account
     * @param underlying The underlying asset address
     * @param account The account to transfer the underlying assets to
     * @param amount The amount of underlying assets to transfer
     */
    function _transferUnderlying(address underlying, address account, uint256 amount) internal {
        // confirm the amount is valid and not greater than the uaSupply
        if (amount == 0 || amount > reserveOfUnderlying[underlying]) {
            revert Errors.InvalidAmount(amount, reserveOfUnderlying[underlying]);
        }
        reserveOfUnderlying[underlying] -= amount;

        Currency.wrap(underlying).transfer(account, amount);
    }

    /**
     * @dev Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
     * @param lcc The LCC token address
     * @param to The recipient of the underlying assets
     * @param fromDirect The amount of LCC to burn from direct supply
     * @param fromMarket The amount of LCC to burn from market-derived supply
     */
    function _pay(address lcc, address owner, address to, uint256 fromDirect, uint256 fromMarket) internal {
        _burn(lcc, owner, fromDirect, fromMarket, _isCallerIssuer(lcc));
        _transferUnderlying(lccToUnderlying[lcc], to, fromDirect + fromMarket);
    }

    /**
     * @dev Adds a settlement request to the queue
     * @param lcc The LCC token address
     * @param recipient The address with pending settlements
     * @param amount The amount to eventually settle
     */
    function _queueSettlement(address lcc, address recipient, uint256 amount) internal {
        settleQueue[lcc][recipient] += amount;
        totalQueued[lcc] += amount;
        emit SettlementQueued(lcc, recipient, amount);
    }

    // ============ VIEW FUNCTIONS ============

    /**
     * @notice Returns the shared reserve of underlying assets for a given LCC token
     * @param lcc The LCC token address
     * @return The amount of underlying assets held in reserve for this LCC
     */
    function sharedReserveOf(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
        return reserveOfUnderlying[lccToUnderlying[lcc]];
    }

    // ============ INTERNAL FUNCTIONS ============

    /**
     * @dev Validates that the sender is a valid MarketVault with at least one native asset LCC
     * @dev Reverts if the sender is not a MarketVault or if neither LCC uses native ETH as underlying
     */
    function _assertValidEthSender() internal view {
        address sender = _msgSender();
        (address l0, address l1) = IMarketVault(sender).lccs();
        bool valid0 = _isValidLcc(l0);
        bool valid1 = _isValidLcc(l1);
        if (!(valid0 && valid1 && (lccToUnderlying[l0] == address(0) || lccToUnderlying[l1] == address(0)))) {
            revert Errors.InvalidEthSender();
        }
    }

    // Best practice: be explicit about intent
    // Plain transactions are performed by the market vault in native asset routes.
    // ie. Only be executed if the msg.sender is the market vault in route: PM -> MV -> LH
    receive() external payable {
        // TODO: enable filter back and include check for pm and mmpm contracts
        // plain ETH transfer must come from a market vault.
        // _assertValidEthSender();
    }
}
