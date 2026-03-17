// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {LiquidityHubStorage, Market} from "../types/Liquidity.sol";
import {LCCFactoryLib} from "./LCCFactoryLib.sol";
import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Errors} from "./Errors.sol";
import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {CurrencyTransfer} from "./CurrencyTransfer.sol";

/// @title LiquidityHubLib
/// @notice Library for heavy LiquidityHub operations
/// @dev Integrates with LCCFactoryLib to reuse functions without callbacks
///      Uses adapter pattern to bridge LiquidityHubStorage to LCCFactoryLib functions
library LiquidityHubLib {
    using CurrencyTransfer for Currency;

    // ============ INTERNAL STRUCTS ============

    /// @dev Internal struct to reduce stack depth in wrapWithLogic
    /// @notice Groups intermediate state for the wrap-with operation to avoid stack-too-deep errors
    struct WrapWithContext {
        /// The original amount requested to wrap
        uint256 originalAmount;
        /// Remaining amount from user's wrapped (direct) balance
        uint256 fromWrappedAmount;
        /// Remaining amount from user's market-derived balance
        uint256 fromMarketDerivedAmount;
        /// Accumulated amount to mint as direct supply
        uint256 directToMint;
        /// Accumulated amount to mint as market-derived supply
        uint256 marketToMint;
        /// Amount of target LCC to burn from Hub
        uint256 targetToBurn;
        /// Amount of backing LCC to burn from Hub
        uint256 backingToBurn;
        /// Remaining amount to process after netting
        uint256 remainingAmount;
        /// Amount queued as settlement shortfall during residual unwrap
        uint256 queuedShortfall;
    }

    // ============ ADAPTER FUNCTIONS ============

    /**
     * @notice Validates that an address is a valid LCC token
     * @dev Adapter function that accesses storage fields directly to validate LCC.
     *      Checks that the LCC has a valid market ID, market ref, and factory address.
     * @param s The liquidity hub storage
     * @param lcc The LCC token address to validate
     * @custom:reverts InvalidLcc if the address is not a valid LCC token
     */
    function assertValidLcc(LiquidityHubStorage storage s, address lcc) internal view {
        if (
            s.lccToMarket[lcc].id == bytes32(0) || s.lccToMarket[lcc].ref.length == 0
                || s.lccToMarket[lcc].factory == address(0)
        ) {
            revert Errors.InvalidLcc(lcc);
        }
    }

    /**
     * @notice Gets the total balance (wrapped + market-derived) of an account for an LCC token
     * @dev Adapter function that delegates to LCCFactoryLib.balanceOf.
     *      No storage access needed as it directly calls the ILCC interface.
     * @param lccToken The LCC token address
     * @param account The account address
     * @return The total balance
     */
    function balanceOf(address lccToken, address account) internal view returns (uint256) {
        return LCCFactoryLib.balanceOf(lccToken, account);
    }

    /**
     * @notice Gets the bucketed balances (wrapped and market-derived) of an account for an LCC token
     * @dev Adapter function that delegates to LCCFactoryLib.balancesOf.
     *      No storage access needed as it directly calls the ILCC interface.
     * @param lccToken The LCC token address
     * @param account The account address
     * @return wrapped The wrapped (direct) balance
     * @return marketDerived The market-derived balance
     */
    function balancesOf(address lccToken, address account)
        internal
        view
        returns (uint256 wrapped, uint256 marketDerived)
    {
        return LCCFactoryLib.balancesOf(lccToken, account);
    }

    /**
     * @notice Mints LCC tokens to an address
     * @dev Adapter function that delegates to LCCFactoryLib.mint.
     *      No storage access needed as it directly calls the ILCCAdmin interface.
     * @param lccToken The LCC token address
     * @param to The address to mint tokens to
     * @param directAmount The amount to mint as direct supply
     * @param marketAmount The amount to mint as market-derived supply
     */
    function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount) internal {
        LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount);
    }

    /**
     * @notice Burns LCC tokens from an address
     * @dev Adapter function that delegates to LCCFactoryLib.burn.
     *      No storage access needed as it directly calls the ILCCAdmin interface.
     * @param lccToken The LCC token address
     * @param from The address to burn tokens from
     * @param directAmount The amount to burn from direct supply
     * @param marketAmount The amount to burn from market-derived supply
     */
    function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount) internal {
        LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount);
    }

    // ============ WRAP-WITH HELPER FUNCTIONS (Stack Depth Optimisation) ============

    /// @notice Step 0: Net against target LCC Hub queue
    /// @dev Reduces amount to process by netting against existing Hub queue for target LCC.
    ///      If Hub has a queue for the target LCC and holds target LCC tokens, we can net them:
    ///      - Burn target LCC from Hub's queue (satisfies Hub's obligation)
    ///      - Burn backing LCC that would have been used to create target LCC
    ///      - Mint target LCC as market-derived (since it came from backing LCC)
    ///      This avoids unnecessary unwrapping and reduces gas costs.
    /// @param s The liquidity hub storage
    /// @param lcc The target LCC token address
    /// @param ctx The wrap context (modified in place via return)
    /// @return Updated wrap context
    function _netAgainstTargetQueue(LiquidityHubStorage storage s, address lcc, WrapWithContext memory ctx)
        private
        returns (WrapWithContext memory)
    {
        uint256 targetQueue = s.settleQueue[lcc][address(this)];
        if (targetQueue == 0) return ctx;

        uint256 hubHeldTarget = balanceOf(lcc, address(this));
        uint256 netTarget = Math.min(ctx.originalAmount, Math.min(targetQueue, hubHeldTarget));
        if (netTarget == 0) return ctx;

        // Consume from market-derived first, then wrapped (priority-based consumption)
        {
            uint256 consumeMarket = Math.min(ctx.fromMarketDerivedAmount, netTarget);
            ctx.fromMarketDerivedAmount -= consumeMarket;
            uint256 remaining = netTarget - consumeMarket;
            if (remaining > 0) {
                uint256 consumeWrapped = Math.min(ctx.fromWrappedAmount, remaining);
                ctx.fromWrappedAmount -= consumeWrapped;
            }
        }

        // Update storage and context.
        // Netting: burn target LCC from queue, burn backing LCC, mint target LCC as market-derived.
        // Keep both per-LCC and per-underlying queue aggregates in sync.
        s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
        s.totalQueued[lcc] -= netTarget;
        s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= netTarget;
        ctx.targetToBurn = netTarget;
        ctx.backingToBurn += netTarget;
        ctx.marketToMint += netTarget;

        return ctx;
    }

    /// @notice Step 1: Optimise direct conversion by transferring directSupply between LCCs
    /// @dev Transfers directSupply from withLCC to target lcc without unwrapping.
    ///      This is the most gas-efficient path: we simply move directSupply between LCCs
    ///      since they share the same underlying asset. No unwrapping/underlying transfer needed.
    ///      The backing LCC's directSupply becomes the target LCC's directSupply.
    /// @param s The liquidity hub storage
    /// @param lcc The target LCC token address
    /// @param withLCC The backing LCC token address
    /// @param ctx The wrap context (modified in place via return)
    /// @return Updated wrap context
    function _optimiseDirectConversion(
        LiquidityHubStorage storage s,
        address lcc,
        address withLCC,
        WrapWithContext memory ctx
    ) private returns (WrapWithContext memory) {
        if (ctx.fromWrappedAmount == 0) return ctx;

        uint256 directAvail = s.directSupply[withLCC];
        uint256 directConverted = Math.min(ctx.fromWrappedAmount, directAvail);
        if (directConverted > 0) {
            // Transfer directSupply: withLCC -> lcc (no unwrap needed, same underlying)
            s.directSupply[withLCC] = directAvail - directConverted;
            s.directSupply[lcc] += directConverted;
            ctx.backingToBurn += directConverted;
            ctx.directToMint += directConverted;
        }
        return ctx;
    }

    /// @notice Step 2: Net market-derived portion against Hub queue using lazy claimed mapping
    /// @dev Uses lazy-claimed mapping (`nettedLCCsAsUnderlying`) to prevent over-netting.
    ///      The lazy-claimed mapping tracks how much of the Hub's queue for withLCC has already
    ///      been netted in previous wrap-with operations. This prevents double-counting when
    ///      multiple wrap-with operations occur before settlement processing.
    ///      Effective queue = total queue - already netted (lazy-claimed)
    /// @param s The liquidity hub storage
    /// @param withLCC The backing LCC token address
    /// @param ctx The wrap context (modified in place via return)
    /// @return Updated wrap context
    function _netMarketDerived(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
        private
        returns (WrapWithContext memory)
    {
        // Calculate remainder after Step 0 (target queue netting) and Step 1 (direct conversion).
        // IMPORTANT: remainingAmount may legitimately be 0 after Step 0; using `> 0` as a sentinel causes
        // double-counting and can lead to over-minting.
        uint256 remainderAmount = ctx.originalAmount;
        remainderAmount = remainderAmount > ctx.targetToBurn ? (remainderAmount - ctx.targetToBurn) : 0;
        remainderAmount = remainderAmount > ctx.directToMint ? (remainderAmount - ctx.directToMint) : 0;

        if (remainderAmount == 0) return ctx;

        uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
        uint256 claimed = s.nettedLCCsAsUnderlying[withLCC];
        // Effective queue = total queue minus what's already been lazy-claimed in previous operations
        uint256 effectiveQueue = hubQueueForWith > claimed ? (hubQueueForWith - claimed) : 0;
        uint256 nettable = Math.min(remainderAmount, Math.min(ctx.fromMarketDerivedAmount, effectiveQueue));

        if (nettable > 0) {
            // Lazy claim: mark this portion as netted (will be reconciled during settlement processing)
            s.nettedLCCsAsUnderlying[withLCC] = claimed + nettable;
            ctx.backingToBurn += nettable;
            ctx.marketToMint += nettable;
            ctx.fromMarketDerivedAmount -= nettable;
        }

        // Store remainder for Step 3 (unwrapping residual)
        ctx.remainingAmount = remainderAmount;
        return ctx;
    }

    /// @notice Step 3: Unwrap residual using withLCC balances
    /// @dev Unwraps remaining amount using directSupply then market liquidity.
    ///      After Steps 0-2 have netted what they can, any remaining amount must be unwrapped
    ///      from the backing LCC. This consumes directSupply first (most efficient), then pulls
    ///      from market liquidity. Any shortfall is queued for settlement.
    /// @param s The liquidity hub storage
    /// @param withLCC The backing LCC token address
    /// @param ctx The wrap context (modified in place via return)
    /// @return Updated wrap context
    function _unwrapResidual(LiquidityHubStorage storage s, address withLCC, WrapWithContext memory ctx)
        private
        returns (WrapWithContext memory)
    {
        // Calculate remaining after netting (marketToMint includes Step 0 + Step 2, minus Step 0's targetToBurn)
        uint256 marketFromNetting = ctx.marketToMint - ctx.targetToBurn;
        uint256 remainingAfterNet =
            ctx.remainingAmount > marketFromNetting ? ctx.remainingAmount - marketFromNetting : 0;

        if (remainingAfterNet == 0) return ctx;

        // Calculate residual wrapped for unwrap (wrapped minus what was used for direct conversion in Step 1)
        uint256 residualWrappedForUnwrap = ctx.fromWrappedAmount;
        if (ctx.directToMint > 0) {
            residualWrappedForUnwrap =
                residualWrappedForUnwrap > ctx.directToMint ? (residualWrappedForUnwrap - ctx.directToMint) : 0;
        }

        // Unwrap: consumes directSupply first, then market liquidity, queues shortfall if any
        (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) = unwrapInternalLogic(
            s, withLCC, address(this), remainingAfterNet, residualWrappedForUnwrap, ctx.fromMarketDerivedAmount
        );

        // Track burns and mints
        ctx.backingToBurn += directUnwrapped + marketUnwrapped;
        ctx.directToMint += directUnwrapped;
        // Market-derived mint = the portion of the requested conversion that is NOT backed by directSupply.
        //
        // IMPORTANT DESIGN NOTE:
        // - We mint the target LCC 1:1 against the input `withLCC` amount (see `wrapWithPrepare` + caller transfer),
        //   even if the backing cannot be fully redeemed (unwrapped) in this transaction.
        // - `unwrapInternalLogic(...)` may redeem less market liquidity than requested; any shortfall is queued to the
        //   Hub (`queueSettlement(..., address(this), ...)`) for later reconciliation when liquidity becomes available.
        // - Therefore, `ctx.marketToMint` intentionally includes the queued/unredeemed remainder (i.e. it is "market-derived
        //   exposure", not "market liquidity actually redeemed now"). By contrast, `ctx.backingToBurn` only burns what was
        //   actually redeemed now (direct + market), and the queued portion is burned lazily during settlement processing.
        ctx.marketToMint += (remainingAfterNet - directUnwrapped);
        ctx.queuedShortfall += queuedShortfall;

        return ctx;
    }

    /// @notice Finalise burns and invariant checks for wrap-with operation
    /// @dev Clamps burns to current balances and ensures lazy-claimed never exceeds queue.
    ///      This is a safety check: if queue was processed between netting and finalisation,
    ///      we ensure lazy-claimed doesn't exceed the new (smaller) queue size.
    /// @param s The liquidity hub storage
    /// @param lcc The target LCC token address
    /// @param withLCC The backing LCC token address
    /// @param ctx The wrap context
    function _finaliseBurns(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
        private
    {
        // Clamp burns to current Hub-held balances (defensive check)
        uint256 targetToBurn = Math.min(ctx.targetToBurn, balanceOf(lcc, address(this)));
        uint256 backingToBurn = Math.min(ctx.backingToBurn, balanceOf(withLCC, address(this)));

        // Execute burns (protocol-bound burns, skip bucket maps)
        if (targetToBurn > 0) {
            burn(lcc, address(this), 0, targetToBurn);
        }
        if (backingToBurn > 0) {
            burn(withLCC, address(this), 0, backingToBurn);
        }

        // Ensure lazy-claimed never exceeds current queue (invariant check)
        // This can happen if queue was processed between netting and finalisation
        // @note: Based on the logical call flow, this should never happen.
        uint256 currentQueueWith = s.settleQueue[withLCC][address(this)];
        if (s.nettedLCCsAsUnderlying[withLCC] > currentQueueWith) {
            s.nettedLCCsAsUnderlying[withLCC] = currentQueueWith;
        }
    }

    // ============ MAIN WRAP-WITH FUNCTION ============

    /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
    /// @dev Multi-step strategy to efficiently convert one LCC to another sharing the same underlying:
    ///      Step 0: Net against target LCC Hub queue (if Hub has queue for target, net backing LCC against it)
    ///      Step 1: Optimise direct conversion (transfer directSupply from withLCC to target, no unwrap needed)
    ///      Step 2: Net market-derived against Hub queue for withLCC (using lazy-claimed mapping to prevent over-netting)
    ///      Step 3: Unwrap residual (consume directSupply then market liquidity, queue shortfall if any)
    ///      Final: Mint target LCC reflecting direct vs market-derived components
    ///
    ///      Priority-based balance consumption: market-derived balance is consumed first, then wrapped (direct).
    ///      This optimises gas by preferring market-derived (no directSupply manipulation) over wrapped.
    ///
    ///      Refactored into helper functions to avoid stack-too-deep in legacy pipeline (via_ir = false).
    /// @param s The liquidity hub state
    /// @param lcc The target LCC token address
    /// @param withLCC The backing LCC token address
    /// @param from The address providing the backing LCC
    /// @param amount The amount to wrap
    //#olympix-ignore-reentrancy
    function wrapWithPrepare(LiquidityHubStorage storage s, address lcc, address withLCC, address from, uint256 amount)
        internal
        view
        returns (WrapWithContext memory)
    {
        if (amount == 0) revert Errors.InvalidAmount(0, 0);

        // Validation: ensure withLCC is valid, not same as target, and shares underlying
        assertValidLcc(s, withLCC);
        if (lcc == withLCC) revert Errors.InvalidAddress(withLCC);
        if (s.lccToUnderlying[lcc] != s.lccToUnderlying[withLCC]) {
            revert Errors.UnderlyingAssetMismatch(s.lccToUnderlying[lcc], s.lccToUnderlying[withLCC]);
        }

        // Initialise context with balance checks in scoped block
        WrapWithContext memory ctx;
        ctx.originalAmount = amount;
        {
            (uint256 wrapped, uint256 marketDerived) = balancesOf(withLCC, from);
            uint256 total = wrapped + marketDerived;
            if (amount > total) revert Errors.InvalidAmount(amount, total);
            // Priority-based: use market-derived balance first, then direct (wrapped) as remainder
            // This optimises gas by preferring market-derived (no directSupply manipulation)
            ctx.fromMarketDerivedAmount = Math.min(amount, marketDerived);
            ctx.fromWrappedAmount = Math.min(wrapped, amount - ctx.fromMarketDerivedAmount); // similar pattern as LCC onTransfer bucket accounting
        }

        // Expects caller to securely transfer funds from (the caller) to (this) Hub
        return ctx;
    }

    /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
    /// @dev Executes the wrap-with operation using the provided context
    /// @param s The liquidity hub state
    /// @param lcc The target LCC token address
    /// @param withLCC The backing LCC token address
    /// @param ctx The wrap context
    //#olympix-ignore-reentrancy
    function wrapWithContext(LiquidityHubStorage storage s, address lcc, address withLCC, WrapWithContext memory ctx)
        internal
    {
        // Execute steps via helper functions (each keeps stack depth minimal)
        ctx = _netAgainstTargetQueue(s, lcc, ctx); // Step 0: Net against target queue
        ctx = _optimiseDirectConversion(s, lcc, withLCC, ctx); // Step 1: Direct conversion
        ctx = _netMarketDerived(s, withLCC, ctx); // Step 2: Net market-derived
        ctx = _unwrapResidual(s, withLCC, ctx); // Step 3: Unwrap residual

        // Finalise burns and invariant checks
        _finaliseBurns(s, lcc, withLCC, ctx);
    }

    // ============ CORE LOGIC FUNCTIONS ============

    /**
     * @notice Core unwrap logic without external transfer
     * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
     *      Any shortfall is queued for settlement. This function does not transfer underlying assets;
     *      that is handled by the calling contract.
     * @param s The liquidity hub storage
     * @param lcc The LCC token address
     * @param queueTo The recipient of the underlying asset (used for queueing shortfall)
     * @param amount The amount to unwrap
     * @param wrappedBalance The wrapped balance of the account
     * @param marketDerivedBalance The market-derived balance of the account
     * @return directUnwrapped The amount unwrapped from direct supply
     * @return marketUnwrapped The amount unwrapped from market liquidity
     * @return queuedShortfall The amount queued due to insufficient immediate liquidity
     */
    //#olympix-ignore-reentrancy
    function unwrapInternalLogic(
        LiquidityHubStorage storage s,
        address lcc,
        address queueTo,
        uint256 amount,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance
    ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped, uint256 queuedShortfall) {
        // 1) Consume directSupply[lcc] if available
        if (wrappedBalance > 0) {
            uint256 directAvail = s.directSupply[lcc];
            directUnwrapped = Math.min(Math.min(amount, wrappedBalance), directAvail);
            if (directUnwrapped > 0) {
                // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                s.directSupply[lcc] = directAvail - directUnwrapped;
            }
        }

        // 2) Pull from market liquidity; increases reserves later via confirmTake callbacks
        uint256 remainingToUnwrap = amount - directUnwrapped;
        if (remainingToUnwrap > 0 && marketDerivedBalance > 0) {
            // Get the max amount that can be unwrapped from this market
            uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);

            // Unwrap from this market's liquidity - call IMarketFactory directly
            marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);

            remainingToUnwrap -= marketUnwrapped;
        }

        // 3) Queue any shortfall for later processing
        if (remainingToUnwrap > 0) {
            queueSettlement(s, lcc, queueTo, remainingToUnwrap);
            queuedShortfall = remainingToUnwrap;
        }
    }

    /**
     * @notice Uses market liquidity to unwrap LCC tokens
     * @dev Calls the MarketFactory to use market liquidity for unwrapping.
     *      This pulls liquidity from the market pool and increases reserves via confirmTake callbacks.
     * @param s The liquidity hub storage
     * @param lcc The LCC token address
     * @param amount The amount of market liquidity to use
     * @return The actual amount of market liquidity used (may be less than requested)
     */
    function useMarketLiquidity(LiquidityHubStorage storage s, address lcc, uint256 amount) internal returns (uint256) {
        Market memory market = s.lccToMarket[lcc];
        return IMarketFactory(market.factory).useMarketLiquidity(lcc, market.id, amount);
    }

    /**
     * @notice Queues a settlement request for later processing
     * @dev Pure queue accounting helper: this function intentionally only mutates queue state.
     *      It does not assert immediate recipient serviceability, because queue ownership can be
     *      decoupled from current LCC custody in protocol flows (for example MM custody release).
     *      Runtime settleability is enforced by processSettlementLogic at redemption time.
     *      Updates both per-LCC queue totals and shared-underlying queue totals.
     *      Note: events are emitted by the calling contract, not this library.
     * @param s The liquidity hub storage
     * @param lcc The LCC token address
     * @param recipient The recipient address for the settlement
     * @param amount The amount to queue for settlement
     */
    function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) internal {
        s.settleQueue[lcc][recipient] += amount;
        s.totalQueued[lcc] += amount;
        s.queueOfUnderlying[s.lccToUnderlying[lcc]] += amount;
        // Event will be emitted by the calling contract
    }

    /// @notice Process settlement for a specific recipient using reserveOfUnderlying
    /// @dev Permissionless function that allows anyone to process settlements when liquidity is available.
    ///      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
    ///
    ///      Hub path (recipient == address(this)):
    ///      - Used when LCCs back LCCs (via wrapWithLogic)
    ///      - Burns Hub-held LCC without transferring underlying or decrementing reserves
    ///      - Reconciles lazy-claimed netting from wrapWithLogic operations
    ///      - Underlying stays in shared pool (no transfer needed)
    ///
    ///      External path (standard users):
    ///      - Checks market-derived holder balance
    ///      - Burns user's LCC tokens (market-derived supply)
    ///      - Transfers underlying assets to recipient
    ///      - Decrements reserveOfUnderlying
    ///
    ///      Important: this is the canonical runtime enforcement point for settleability.
    ///      Queue creation may be valid even when claims are not executable yet. In those cases
    ///      this function can revert (or no-op for Hub path) until reserves/custody reconcile.
    ///
    /// @param s The liquidity hub storage
    /// @param lcc The LCC token address
    /// @param recipient The recipient address to settle for (address(this) for Hub's own queue)
    /// @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
    function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount)
        internal
    {
        bool isForHub = recipient == address(this);
        uint256 queued = s.settleQueue[lcc][recipient];
        if (queued == 0) revert Errors.InvalidAmount(0, 0);

        address underlying = s.lccToUnderlying[lcc];
        uint256 available = s.reserveOfUnderlying[underlying];

        uint256 holderBal = 0;
        if (isForHub) {
            // Hub-specific path: burn Hub-held LCC against available reserves
            // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
            // Note: This path should only really occur when LCCs back LCCs (via wrapWithLogic)
            holderBal = balanceOf(lcc, recipient);
        } else {
            // Standard path for external recipients
            // Only check market-derived balance (wrapped balance doesn't need settlement)
            (, holderBal) = balancesOf(lcc, recipient);
        }

        // Calculate settlement amount: min of queued, available reserves, maxAmount, and holder balance
        uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
        if (toSettle == 0) {
            if (!isForHub) {
                revert Errors.LiquidityError(lcc, toSettle);
            }
            return;
        }

        // Update queue state at both LCC and shared-underlying scopes.
        s.settleQueue[lcc][recipient] -= toSettle;
        s.totalQueued[lcc] -= toSettle;
        s.queueOfUnderlying[underlying] -= toSettle;

        if (isForHub) {
            // Reconcile lazy netting from wrapWith Step 2.
            //
            // `nettedLCCsAsUnderlying[lcc]` tracks how much of the Hub's own queued settlement for `lcc` was
            // already "netted" earlier during wrapWith (market-derived netting) WITHOUT reducing `settleQueue`
            // at that time. In other words: the queue still exists on-chain, but some of it has already been
            // economically satisfied via netting. (ie. transferred to a recipient, so we don't need to burn Hub-held LCC for that same portion)
            //
            // When we later process the Hub's queue, we still decrement `settleQueue`/`totalQueued` by `toSettle`,
            // but we must avoid double-accounting by NOT burning Hub-held LCC for the already-netted portion.
            // So we consume `claimed` first, and only burn the remaining `effectiveToBurn`.
            //
            // (The external-recipient path below uses `pay(...)`, which burns the user's LCC and transfers
            // underlying, decrementing reserves.)
            uint256 claimed = s.nettedLCCsAsUnderlying[lcc];
            uint256 decrement = Math.min(claimed, toSettle);
            if (decrement > 0) {
                s.nettedLCCsAsUnderlying[lcc] = claimed - decrement;
            }
            // Burn the remaining amount after wrapWithLogic lazy netting has been accounted for
            uint256 effectiveToBurn = toSettle - decrement;

            if (effectiveToBurn > 0) {
                // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
                burn(lcc, recipient, 0, effectiveToBurn);
            }
        } else {
            // Standard path: burn user's LCC and transfer underlying
            pay(s, lcc, recipient, recipient, 0, toSettle);
        }
    }

    /// @notice Transfers underlying assets to an account
    /// @param s The liquidity hub storage
    /// @param underlying The underlying asset address
    /// @param account The account to transfer the underlying assets to
    /// @param amount The amount of underlying assets to transfer
    function transferUnderlying(LiquidityHubStorage storage s, address underlying, address account, uint256 amount)
        internal
    {
        // confirm the amount is valid and not greater than the uaSupply
        if (amount == 0 || amount > s.reserveOfUnderlying[underlying]) {
            revert Errors.InvalidAmount(amount, s.reserveOfUnderlying[underlying]);
        }
        s.reserveOfUnderlying[underlying] -= amount;

        Currency.wrap(underlying).transfer(account, amount);
    }

    /// @notice Pays an outstanding settlement to an account by burning LCC tokens and transferring underlying assets
    /// @param s The liquidity hub storage
    /// @param lcc The LCC token address
    /// @param owner The owner of the LCC tokens to burn
    /// @param to The recipient of the underlying assets
    /// @param fromDirect The amount of LCC to burn from direct supply
    /// @param fromMarket The amount of LCC to burn from market-derived supply
    function pay(
        LiquidityHubStorage storage s,
        address lcc,
        address owner,
        address to,
        uint256 fromDirect,
        uint256 fromMarket
    ) internal {
        burn(lcc, owner, fromDirect, fromMarket);
        transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect + fromMarket);
    }
}

