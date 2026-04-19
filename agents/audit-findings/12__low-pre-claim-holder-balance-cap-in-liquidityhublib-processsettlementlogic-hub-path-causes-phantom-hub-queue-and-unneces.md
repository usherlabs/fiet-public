[Low] Pre-claim holder-balance cap in LiquidityHubLib.processSettlementLogic (Hub path) causes phantom Hub queue and unnecessary intra-protocol reserve shifts

# Description

In the Hub self-settlement path, settlement is [pre-capped by the Hub’s current LCC balance](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L534-L556) before [consuming already-netted (claimed) amounts](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L561-L571). This blocks clearing the claimed slice (which needs no burn), leaving phantom queue and potentially causing CanonicalVault to overfund the Hub.

LiquidityHubLib.processSettlementLogic handles settlement for queued claims. In the Hub path (recipient == address(this)), it [computes toSettle = min(queued, available, maxAmount, holderBal)](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L534-L556) where holderBal = balanceOf(lcc, address(this)). Only after that cap does it [subtract the already-netted (lazy-claimed) amount from s.nettedLCCsAsUnderlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L561-L571) to determine effective burn. Because claimed portions are already economically satisfied and require no additional Hub-held LCC burn, pre-capping by holderBal can prevent any settlement progress when holderBal is low or zero. This leaves phantom debt in settleQueue, totalQueued, and [queueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L496-L501). When CanonicalVault later uses [unfundedQueueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LiquidityHub.sol#L304-L308) (which ignores claimed) to decide settlement flows, it may transfer underlying to the Hub unnecessarily via [confirmTake](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/CanonicalVault.sol#L438-L441), while the Hub’s queue remains uncleared due to the same pre-cap. The effect is persistent accounting distortion and potential misallocation of underlying from CanonicalVault to the Hub; no funds are stolen or created, and core balance-backed invariants remain intact.

# Severity

**Impact Explanation:** [Low] The issue causes intra-protocol misallocation of principal (from CanonicalVault to Hub) and persistent accounting distortion, but no theft, no unbacked minting, and no broken core invariants.

**Likelihood Explanation:** [Low] It relies on the presence of Hub self-queues, Step 2-only wrapWith (no Step 3), and CanonicalVault settlement timing. There is no direct attacker profit, making this primarily a griefing-style condition.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Overfunding from CanonicalVault to Hub: A Hub queue exists for LCC A. A user performs wrapWith that fully nets via Step 2 (no Step 3), [increasing s.nettedLCCsAsUnderlying[A]](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L231-L235) and burning Hub-held A in finalize, leaving holderBal(A) ≈ 0. Later, CanonicalVault uses [unfundedQueueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LiquidityHub.sol#L304-L308) to push underlying to the Hub via [confirmTake](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/CanonicalVault.sol#L438-L441), but [processSettlementLogic (Hub path) settles nothing due to holderBal=0](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L534-L556). CanonicalVault repeats until unfunded≈0, effectively transferring underlying to the Hub against a phantom queue slice.
#### Preconditions / Assumptions
- (a). There is a nonzero Hub self-queue for an LCC A: s.settleQueue[A][address(this)] > 0
- (b). A wrapWith(A_target, A) occurs where Step 2 netting fully covers the remainder (Step 3 not invoked)
- (c). Finalization burns Hub-held A, leaving holderBal(A) low/zero
- (d). CanonicalVault later calls settleObligationsForLCC based on unfundedQueueOfUnderlying

### Scenario 2.
Persistent phantom Hub queue and distorted metrics: With a claimed portion recorded and low/zero Hub-held A balance, later settlement attempts no-op due to the pre-cap. settleQueue, totalQueued, and [queueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol#L496-L501) remain overstated. Observability and automated policies relying on these metrics are misled, even though the claimed portion should have been clearable without burn.
#### Preconditions / Assumptions
- (a). There is a nonzero Hub self-queue for an LCC A: s.settleQueue[A][address(this)] > 0
- (b). A wrapWith using Step 2-only netting records s.nettedLCCsAsUnderlying[A] > 0
- (c). Hub-held A balance is low/zero at settlement time
- (d). processSettlementLogic for the Hub is invoked with available > 0 but holderBal≈0

### Scenario 3.
Cross-market overfunding across same-underlying LCCs: Multiple LCCs share the same underlying and accumulate phantom Hub queues via Step 2-only wrapWith. CanonicalVault (using aggregate [unfundedQueueOfUnderlying](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/LiquidityHub.sol#L304-L308)) transfers underlying to the Hub to cover these phantom debts. confirmTake does not reduce queues (holderBal≈0), so the Hub’s marketDerived reserve grows while CanonicalVault’s per-market reserves are unnecessarily drained.
#### Preconditions / Assumptions
- (a). Multiple LCCs share the same underlying; each has nonzero Hub self-queues
- (b). Step 2-only wrapWith operations record claimed portions for these LCCs
- (c). Hub-held balances for these LCCs are low/zero when CanonicalVault settles
- (d). CanonicalVault uses aggregate unfundedQueueOfUnderlying to transfer underlying to the Hub

# Proposed fix

## LiquidityHubLib.sol

File: `contracts/evm/src/libraries/LiquidityHubLib.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/8cefc80d0a77f70260d5024395fd7d64d8747a8f/contracts/evm/src/libraries/LiquidityHubLib.sol)

```diff
 // SPDX-License-Identifier: BUSL-1.1
 pragma solidity ^0.8.26;
 
 import {LiquidityHubStorage, Market, UnderlyingReserve} from "../types/Liquidity.sol";
 import {LCCFactoryLib} from "./LCCFactoryLib.sol";
 import {Math} from "openzeppelin-contracts/contracts/utils/math/Math.sol";
 import {Errors} from "./Errors.sol";
 import {IMarketFactory} from "../interfaces/IMarketFactory.sol";
 import {IQueueCustodian} from "../interfaces/IQueueCustodian.sol";
 import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
 import {CurrencyTransfer} from "./CurrencyTransfer.sol";
 import {IWETH9} from "v4-periphery/src/interfaces/external/IWETH9.sol";
 
 interface ILiquidityHubWeth9 {
     function weth9() external view returns (address);
 }
 
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
         returns (WrapWithContext memory)
     {
         // Execute steps via helper functions (each keeps stack depth minimal)
         ctx = _netAgainstTargetQueue(s, lcc, ctx); // Step 0: Net against target queue
         ctx = _optimiseDirectConversion(s, lcc, withLCC, ctx); // Step 1: Direct conversion
         ctx = _netMarketDerived(s, withLCC, ctx); // Step 2: Net market-derived
         ctx = _unwrapResidual(s, withLCC, ctx); // Step 3: Unwrap residual
 
         // Finalise burns and invariant checks
         _finaliseBurns(s, lcc, withLCC, ctx);
         return ctx;
     }
 
     // ============ CORE LOGIC FUNCTIONS ============
 
     /**
      * @notice Core unwrap logic without external transfer
      * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
      *      External settlement queues are market-derived claims only (`processSettlementLogic` burns market-derived LCC).
      *      The wrapped / direct-backed slice must redeem fully against `directSupply` in this transaction or revert;
      *      it must not degrade into a queued external settlement. Only the market-derived slice may queue shortfall
      *      when `useMarketLiquidity` returns less than requested.
      *      This function does not transfer underlying assets; that is handled by the calling contract.
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
         // 1) Wrapped / direct-backed slice: must fully satisfy `min(amount, wrappedBalance)` against directSupply or revert.
         uint256 wrappedNeed = Math.min(amount, wrappedBalance);
         if (wrappedNeed > 0) {
             uint256 directAvail = s.directSupply[lcc];
             directUnwrapped = Math.min(wrappedNeed, directAvail);
             if (wrappedNeed > directUnwrapped) {
                 // This should never happen - as directAvail is the sum of all wrapped balances
                 revert Errors.InvalidAmount(wrappedNeed, directUnwrapped);
             }
             if (directUnwrapped > 0) {
                 // Underlying already accounted in reserveOfUnderlying (shared pool), no transfer needed
                 s.directSupply[lcc] = directAvail - directUnwrapped;
             }
         }
 
         uint256 remainingToUnwrap = amount - directUnwrapped;
 
         // 2) Market-derived slice: pull from market liquidity; queue only market shortfall (never wrapped/direct shortfall).
         if (remainingToUnwrap == 0) {
             return (directUnwrapped, 0, 0);
         }
 
         if (marketDerivedBalance == 0) {
             // This should not happen, unless unwrap is for amount > balance.
             revert Errors.InvalidAmount(remainingToUnwrap, 0);
         }
 
         uint256 requestFromMarket = Math.min(remainingToUnwrap, marketDerivedBalance);
         marketUnwrapped = useMarketLiquidity(s, lcc, requestFromMarket);
 
         remainingToUnwrap -= marketUnwrapped;
 
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
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
 
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
 
-        // Calculate settlement amount: min of queued, available reserves, maxAmount, and holder balance
-        uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
+        // Calculate settlement amount
+        uint256 toSettle;
+        if (isForHub) {
+            // Hub path: allow clearing already-netted (claimed) portion regardless of holderBal/available,
+            // and require both for any remainder beyond claimed.
+            uint256 claimed = s.nettedLCCsAsUnderlying[lcc];
+            if (claimed > queued) claimed = queued;
+            uint256 headroom = claimed + Math.min(available, holderBal);
+            toSettle = Math.min(Math.min(queued, maxAmount), headroom);
+        } else {
+            // External path: unchanged gating
+            toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
+        }
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
     /// @param directAmount The direct reserve amount to transfer
     /// @param marketDerivedAmount The market-derived reserve amount to transfer
     function transferUnderlying(
         LiquidityHubStorage storage s,
         address underlying,
         address account,
         uint256 directAmount,
         uint256 marketDerivedAmount
     ) internal {
         uint256 amount = directAmount + marketDerivedAmount;
         UnderlyingReserve storage reserve = s.reserveOfUnderlying[underlying];
         if (amount == 0 || directAmount > reserve.direct || marketDerivedAmount > reserve.marketDerived) {
             uint256 totalReserve = reserve.direct + reserve.marketDerived;
             revert Errors.InvalidAmount(amount, totalReserve);
         }
         reserve.direct -= directAmount;
         reserve.marketDerived -= marketDerivedAmount;
 
         if (underlying == address(0)) {
             // Attempt native push first for backwards-compatible payout behaviour.
             (bool nativeOk,) = account.call{value: amount}("");
             if (nativeOk) return;
 
             address wrappedNative = ILiquidityHubWeth9(address(this)).weth9();
             if (wrappedNative == address(0)) {
                 revert Errors.InvalidAddress(wrappedNative);
             }
 
             IWETH9(wrappedNative).deposit{value: amount}();
             Currency.wrap(wrappedNative).transfer(account, amount);
             return;
         }
 
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
         transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect, fromMarket);
     }
 
     // ============ ISSUER / CUSTODIAN HELPERS (called via LiquidityHubLinkedLib) ============
 
     /// @dev Snapshot for `confirmTake`: reserve bump and whether `LiquidityAvailable` should emit (before Hub settlement).
     struct ConfirmTakeContext {
         uint256 hubQueueBeforeSettlement;
         address underlying;
         bytes32 marketId;
         bool emitLiquidityAvailable;
     }
 
     function confirmTakePrepare(LiquidityHubStorage storage s, address lcc, uint256 amount, bool shouldEmit)
         internal
         returns (ConfirmTakeContext memory ctx)
     {
         ctx.underlying = s.lccToUnderlying[lcc];
         s.reserveOfUnderlying[ctx.underlying].marketDerived += amount;
         ctx.hubQueueBeforeSettlement = s.settleQueue[lcc][address(this)];
         ctx.marketId = s.lccToMarket[lcc].id;
         ctx.emitLiquidityAvailable = shouldEmit && ctx.hubQueueBeforeSettlement < amount;
     }
 
     function confirmTakeBalanceInvariant(LiquidityHubStorage storage s, address underlying) internal view {
         UnderlyingReserve storage reserveTuple = s.reserveOfUnderlying[underlying];
         uint256 reserve = reserveTuple.direct + reserveTuple.marketDerived;
         uint256 actualBalance =
             underlying == address(0) ? address(this).balance : Currency.wrap(underlying).balanceOf(address(this));
         if (reserve > actualBalance) revert Errors.InsufficientBalance(actualBalance, reserve);
     }
 
     function prepareSettle(LiquidityHubStorage storage s, address lcc, uint256 amount, address issuer) internal {
         if (amount == 0) revert Errors.InvalidAmount(0, 0);
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 reserveDirect = s.reserveOfUnderlying[underlying].direct;
         uint256 directAvail = s.directSupply[lcc];
         uint256 maxSettleableDirect = Math.min(reserveDirect, directAvail);
         if (maxSettleableDirect < amount) {
             revert Errors.InvalidAmount(amount, maxSettleableDirect);
         }
 
         s.reserveOfUnderlying[underlying].direct = reserveDirect - amount;
         s.directSupply[lcc] = directAvail - amount;
 
         Currency underlyingCurrency = Currency.wrap(underlying);
         if (underlyingCurrency.isAddressZero()) {
             underlyingCurrency.transfer(issuer, amount);
         } else {
             underlyingCurrency.approve(issuer, amount);
         }
     }
 
     /// @dev `custodian` must implement `IQueueCustodian`. `tokenId` is the custodian bucket id (commitment id or utility sentinel).
     function settleFromCustodian(
         LiquidityHubStorage storage s,
         address lcc,
         address custodian,
         uint256 tokenId,
         address recipient,
         uint256 maxAmount
     ) internal returns (uint256 settled) {
         if (recipient == address(0) || custodian == address(0) || maxAmount == 0) {
             return 0;
         }
         if (custodian.code.length == 0) {
             return 0;
         }
 
         IQueueCustodian queueCustodian = IQueueCustodian(custodian);
         uint256 queued = s.settleQueue[lcc][recipient];
         if (queued == 0) return 0;
 
         address underlying = s.lccToUnderlying[lcc];
         uint256 available = s.reserveOfUnderlying[underlying].marketDerived;
         uint256 custodied;
         try queueCustodian.queued(tokenId, lcc, recipient) returns (uint256 q) {
             custodied = q;
         } catch {
             return 0;
         }
 
         settled = Math.min(Math.min(queued, available), Math.min(maxAmount, custodied));
         if (settled == 0) return 0;
 
         try queueCustodian.release(tokenId, lcc, recipient, settled) returns (uint256 released) {
             settled = released;
         } catch {
             return 0;
         }
         if (settled == 0) return 0;
     }
 
     function annulSettlementBeforeTransfer(
         LiquidityHubStorage storage s,
         address lcc,
         address from,
         uint256 wrappedBalance,
         uint256 marketDerivedBalance,
         uint256 amountToTransfer
     ) internal returns (uint256 toAnnul) {
         uint256 queued = s.settleQueue[lcc][from];
         uint256 liquidBalance = wrappedBalance + marketDerivedBalance;
         uint256 transferableWithoutQueue = liquidBalance > queued ? (liquidBalance - queued) : 0;
         if (amountToTransfer > transferableWithoutQueue) {
             uint256 bleedIntoQueue = amountToTransfer - transferableWithoutQueue;
             toAnnul = Math.min(bleedIntoQueue, queued);
             if (toAnnul > 0) {
                 s.settleQueue[lcc][from] -= toAnnul;
                 s.totalQueued[lcc] -= toAnnul;
                 s.queueOfUnderlying[s.lccToUnderlying[lcc]] -= toAnnul;
             }
         }
     }
 }
```
