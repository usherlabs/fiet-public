// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "openzeppelin-contracts/contracts/access/Ownable.sol";
import {IOracleHelper} from "./interfaces/IOracleHelper.sol";
import {IMarketFactory} from "./interfaces/IMarketFactory.sol";
import {LCCFactory} from "./modules/LCCFactory.sol";
import {CurrencyTransfer} from "./libraries/CurrencyTransfer.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Errors} from "./libraries/Errors.sol";
import {IMarketVault} from "./interfaces/IMarketVault.sol";

/**
 * @title LiquidityHub
 * @notice Factory contract for creating Fiet protocol markets with LCC tokens and pool management
 * @dev Manages LCC token creation, pool deployment, and protocol bounds administration
 */
contract LiquidityHub is Ownable, LCCFactory {
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

    // Pending shortfall for netting: backerLcc => mintedLcc => queued amount at Hub
    mapping(address => mapping(address => uint256)) public lccBackingLccShortfall;

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

    function wrapTo(address lcc, address to, uint256 amount) external payable {
        _wrap(lcc, _msgSender(), to, amount);
    }

    function wrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external payable {
        _wrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    function wrap(address lcc, uint256 amount) external payable {
        _wrap(lcc, _msgSender(), _msgSender(), amount);
    }

    function wrap(address underlying, bytes32 marketId, uint256 amount) external payable {
        _wrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    /**
     * @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
     * @dev Implements O(1) flattening: immediately unwraps withLCC into shared underlying reserves.
     *      First nets against reverse reserve (lccBackingReserve[lcc][withLCC]) if available.
     *      For remainder, calls _unwrap(withLCC, address(this), address(this), remainder) to flatten
     *      into directSupply and/or market liquidity, then mints lcc to recipient.
     *      This prevents recursive backing chains and ensures efficient gas usage.
     * @param lcc The LCC to mint
     * @param withLCC The LCC used as backing reserve (must share same underlying)
     * @param from The address providing withLCC
     * @param to The recipient of newly minted lcc
     * @param amount The amount of withLCC to use
     */
    function _wrapWith(address lcc, address withLCC, address from, address to, uint256 amount)
        internal
        onlyValidLcc(lcc)
    {
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
            revert Errors.LiquidityError(withLCC, amount);
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

        uint256 toMintForMarket = 0;

        // First: net queued shortfall in reverse direction to minimise market liquidity usage and Hub queue growth

        // `pairPending` gives shortfall where target lcc is backing the withLCC (now being used as a underlying)
        // ie. is the LCC-as-underlying already currently backed by the target LCC?
        uint256 pairPending = lccBackingLccShortfall[lcc][withLCC];
        uint256 hubQueueForWith = settleQueue[withLCC][address(this)];

        // nettable: give me the minimum of [settlement queue amount for LCC-as-underlying, OR the shortfall where target LCC is backing the now LCC-as-underlying]
        uint256 nettable = Math.min(amount, Math.min(pairPending, hubQueueForWith));
        if (nettable > 0) {
            // Decrement pair map and Hub queue for withLCC
            lccBackingLccShortfall[lcc][withLCC] = pairPending - nettable;
            settleQueue[withLCC][address(this)] = hubQueueForWith - nettable;
            totalQueued[withLCC] -= nettable;
            // Burn received withLCC against the netted amount (protocol-bound burn)
            _burn(withLCC, address(this), 0, nettable, true);
            // Mint lcc as market-derived for the netted portion
            // If nettable due to queued shortfalls, then amounts were originally market-derived.
            toMintForMarket = nettable;
        }

        uint256 remainderAmount = amount - nettable;
        if (remainderAmount > 0) {
            // Adjust original bucket-based view for the remainder after netting:
            // Prefer to net from market-derived first (since queued shortfalls represent market pending)
            uint256 usedFromMarketForNet = Math.min(fromMarketDerivedAmount, nettable);
            fromMarketDerivedAmount -= usedFromMarketForNet;
            uint256 remainingNet = nettable - usedFromMarketForNet;
            if (remainingNet > 0) {
                // Any leftover net comes from wrapped-origin tokens
                fromWrappedAmount = fromWrappedAmount > remainingNet ? (fromWrappedAmount - remainingNet) : 0;
            }

            // O(1) flattening: immediately unwrap withLCC into shared underlying reserves
            // This consumes directSupply[withLCC] and/or market liquidity, burns Hub-held withLCC,
            // and queues any shortfall to Hub's own settlement queue
            (uint256 directUnwrapped, uint256 marketUnwrapped) = _unwrapInternalLogic(
                withLCC, address(this), address(this), remainderAmount, fromWrappedAmount, fromMarketDerivedAmount
            );

            uint256 toBurn = directUnwrapped + marketUnwrapped;

            // If this unwrap is the Hub-flattening from wrapWith, track pairwise pending for future netting
            lccBackingLccShortfall[withLCC][lcc] += remainderAmount - toBurn;

            if (toBurn > 0) {
                // Burn Hub-held withLCC for the portion successfully unwrapped (protocol-bound burn)
                _burn(withLCC, address(this), directUnwrapped, marketUnwrapped, true);
            }

            // Mint lcc to recipient reflecting immediate direct flattening vs market-derived remainder
            // Note: We already minted 'nettable' as market-derived above, so here we mint for the remainder only
            toMintForMarket += remainderAmount - directUnwrapped;
        }

        _mint(lcc, to, directUnwrapped, toMintForMarket, false);

        emit LccWrappedWith(lcc, withLCC, from, to, amount);
    }

    function wrapWith(address lcc, address withLCC, uint256 amount) external {
        _wrapWith(lcc, withLCC, _msgSender(), _msgSender(), amount);
    }

    function wrapWithTo(address lcc, address withLCC, address to, uint256 amount) external {
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
     * @dev Unwraps LCC from the account's wallet.
     * @dev Accounts should only be able to unwrap if LCC in their wallet.
     * @dev Routes to Hub-specific path when recipient is address(this), otherwise uses standard unwrap flow.
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

        (uint256 directUnwrapped, uint256 marketUnwrapped,) =
            _unwrapInternalLogic(lcc, from, to, amount, wrappedBalance, marketDerivedBalance);

        // Burn the amount that was unwrapped
        // and transfer the underlying assets to the account
        if (directUnwrapped + marketUnwrapped > 0) {
            _pay(lcc, to, directUnwrapped, marketUnwrapped);
        }

        emit LccUnwrapped(lcc, from, to, amount);
    }

    function unwrap(address lcc, uint256 amount) external {
        _unwrap(lcc, _msgSender(), _msgSender(), amount);
    }

    function unwrap(address underlying, bytes32 marketId, uint256 amount) external {
        _unwrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), _msgSender(), amount);
    }

    function unwrapTo(address lcc, address to, uint256 amount) external {
        _unwrap(lcc, _msgSender(), to, amount);
    }

    function unwrapTo(address underlying, bytes32 marketId, address to, uint256 amount) external {
        _unwrap(marketUnderlyingToLCC[marketId][underlying], _msgSender(), to, amount);
    }

    // ============ LIQUIDITY FUNCTIONS ============

    function marketLiquidity(address lcc) public view returns (uint256) {
        return lccToMarket[lcc].id != bytes32(0)
            ? IMarketFactory(lccToMarket[lcc].factory).marketLiquidity(lccToUnderlying[lcc], lccToMarket[lcc].id)
            : 0;
    }

    /**
     * @dev Unwraps LCC from a specific market's liquidity reserves
     * @notice OOM vs IM Distinction: When acquiring LCCs from a market, it's underlying liquidity either in the market, or to be settled to the market.
     * @param lcc The LCC token address
     * @param to The recipient of underlying assets
     * @param amount The amount to unwrap from this market
     * @return The amount actually unwrapped from this market
     */
    function _useMarketLiquidity(address lcc, uint256 amount) internal returns (uint256 d) {
        bytes32 marketId = lccToMarket[lcc].id;
        return IMarketFactory(lccToMarket[lcc].factory).useMarketLiquidity(lccToUnderlying[lcc], marketId, amount);
    }

    // ============ ISSUER FUNCTIONS ============

    /**
     * @notice Issues LCC tokens (mints to issuer)
     * @param lcc The LCC token address to issue for
     * @param amount The amount to issue
     */
    function issue(address lcc, uint256 amount) external onlyIssuer(lcc) onlyValidLcc(lcc) {
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        address issuer = _msgSender();
        _mint(lcc, issuer, 0, amount, true);
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
     * @notice Called by MarketVault after taking underlying liquidity from the market to LCC
     * @param lcc The LCC token address
     * @param amount The amount of underlying liquidity taken
     * @param shouldEmit Whether to emit LiquidityAvailable event
     */
    function confirmTake(address lcc, uint256 amount, bool shouldEmit) external onlyIssuer(lcc) {
        // Track total underlying asset supply
        reserveOfUnderlying[lccToUnderlying[lcc]] += amount;

        // Best-effort: settle Hub queue up to the newly available amount
        uint256 hubQueue = settleQueue[lcc][address(this)];
        if (hubQueue > 0) {
            processSettlementFor(lcc, address(this), hubQueue);
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
    function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) {
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
    function processSettlementFor(address lcc, address recipient, uint256 maxAmount) external onlyValidLcc(lcc) {
        bool isForHub = recipient == address(this);
        uint256 queued = settleQueue[lcc][recipient];
        if (queued == 0) revert Errors.InvalidAmount(0, 0);

        address underlying = lccToUnderlying[lcc];
        uint256 available = reserveOfUnderlying[underlying];

        uint256 holderBal = 0;
        if (isForHub) {
            // Hub-specific path: burn Hub-held LCC against available reserves
            // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
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
            // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
            _burn(lcc, recipient, 0, toSettle, true);
        } else {
            _pay(lcc, recipient, 0, toSettle);
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

    // Pay an outstanding settlement to an account and burn their underlying tokens
    function _pay(address lcc, address to, uint256 fromDirect, uint256 fromMarket) internal {
        _burn(lcc, to, fromDirect, fromMarket, _isCallerIssuer(lcc));
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

    function sharedReserveOf(address lcc) external view onlyValidLcc(lcc) returns (uint256) {
        return reserveOfUnderlying[lccToUnderlying[lcc]];
    }

    // ============ INTERNAL FUNCTIONS ============

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
        // plain ETH transfer must come from a market vault.
        _assertValidEthSender();
    }
}
