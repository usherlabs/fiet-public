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
     * @param issued Whether this is an issuer-initiated mint
     */
    function mint(address lccToken, address to, uint256 directAmount, uint256 marketAmount, bool issued) internal {
        LCCFactoryLib.mint(lccToken, to, directAmount, marketAmount, issued);
    }

    /**
     * @notice Burns LCC tokens from an address
     * @dev Adapter function that delegates to LCCFactoryLib.burn.
     *      No storage access needed as it directly calls the ILCCAdmin interface.
     * @param lccToken The LCC token address
     * @param from The address to burn tokens from
     * @param directAmount The amount to burn from direct supply
     * @param marketAmount The amount to burn from market-derived supply
     * @param issued Whether this is an issuer-initiated burn
     */
    function burn(address lccToken, address from, uint256 directAmount, uint256 marketAmount, bool issued) internal {
        LCCFactoryLib.burn(lccToken, from, directAmount, marketAmount, issued);
    }

    // ============ CORE LOGIC FUNCTIONS ============

    /// @notice Wrap LCC using another LCC as backing, with O(1) flattening and netting
    /// @dev Strategy:
    ///      - Optimise direct: transfer directSupply from withLCC to target lcc (no unwrap)
    ///      - Net market-derived against Hub queue for withLCC using a lazy-claimed mapping to prevent over-netting
    ///      - For residual, unwrap withLCC (consuming directSupply then market liquidity), queue shortfall if any
    ///      - Mint target lcc reflecting direct vs market-derived components
    /// @param s The liquidity hub state
    /// @param lcc The target LCC token address
    /// @param withLCC The backing LCC token address
    /// @param from The address providing the backing LCC
    /// @param to The address receiving the target LCC
    /// @param amount The amount to wrap
    /// @return directToMint The amount to mint as direct supply
    /// @return marketToMint The amount to mint as market-derived supply
    function wrapWithLogic(
        LiquidityHubStorage storage s,
        address lcc,
        address withLCC,
        address from,
        address to,
        uint256 amount
    ) internal returns (uint256 directToMint, uint256 marketToMint) {
        uint256 originalRequestedAmount = amount;
        if (amount == 0) {
            revert Errors.InvalidAmount(0, 0);
        }

        // Validation using adapter - no callback needed!
        assertValidLcc(s, withLCC);
        if (lcc == withLCC) {
            revert Errors.InvalidAddress(withLCC);
        }
        // Enforce same underlying asset for both LCCs
        if (s.lccToUnderlying[lcc] != s.lccToUnderlying[withLCC]) {
            revert Errors.UnderlyingAssetMismatch(s.lccToUnderlying[lcc], s.lccToUnderlying[withLCC]);
        }

        // Get bucketed balances using adapter - no callback needed!
        (uint256 fromWrappedBalance, uint256 fromMarketDerivedBalance) = balancesOf(withLCC, from);
        uint256 fromBalance = fromWrappedBalance + fromMarketDerivedBalance;
        if (amount > fromBalance) {
            revert Errors.InvalidAmount(amount, fromBalance);
        }

        // Priority-based: use market-derived balance first, then direct (wrapped) as remainder
        uint256 fromMarketDerivedAmount = Math.min(amount, fromMarketDerivedBalance);
        uint256 fromWrappedAmount = amount - fromMarketDerivedAmount;

        // Pull backing LCC from user to Hub with Permit2 fallback
        Currency.wrap(withLCC).transferFrom(from, address(this), amount);

        uint256 targetToBurn = 0;
        uint256 backingToBurn = 0;

        // Step 0: Net against target LCC Hub queue
        uint256 targetQueue = s.settleQueue[lcc][address(this)];
        if (targetQueue > 0) {
            // Use adapter - no callback needed!
            uint256 hubHeldTarget = balanceOf(lcc, address(this));
            uint256 netTarget = Math.min(amount, Math.min(targetQueue, hubHeldTarget));
            if (netTarget > 0) {
                // Consume the user's provided withLCC across buckets to reflect origin
                uint256 consumeMarket = Math.min(fromMarketDerivedAmount, netTarget);
                fromMarketDerivedAmount -= consumeMarket;
                uint256 remainingTarget = netTarget - consumeMarket;
                if (remainingTarget > 0) {
                    uint256 consumeWrapped = Math.min(fromWrappedAmount, remainingTarget);
                    fromWrappedAmount -= consumeWrapped;
                }

                // Annul the target queue and track burn for target LCC
                s.settleQueue[lcc][address(this)] = targetQueue - netTarget;
                s.totalQueued[lcc] -= netTarget;
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
            uint256 directAvail = s.directSupply[withLCC];
            uint256 directConverted = Math.min(fromWrappedAmount, directAvail);
            if (directConverted > 0) {
                s.directSupply[withLCC] = directAvail - directConverted;
                s.directSupply[lcc] += directConverted;
                // Track burn for withLCC (direct)
                backingToBurn += directConverted;
                directToMint += directConverted;
            }
        }

        // Step 2: Net market-derived portion against Hub queue using lazy claimed mapping
        uint256 remainderAmount = amount - directToMint;
        if (remainderAmount > 0) {
            uint256 hubQueueForWith = s.settleQueue[withLCC][address(this)];
            uint256 claimed = s.nettedLCCsAsUnderlying[withLCC];
            uint256 effectiveQueue = hubQueueForWith > claimed ? (hubQueueForWith - claimed) : 0;
            uint256 nettable = Math.min(remainderAmount, Math.min(fromMarketDerivedAmount, effectiveQueue));
            if (nettable > 0) {
                s.nettedLCCsAsUnderlying[withLCC] = claimed + nettable; // lazy claim
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
                (uint256 directUnwrapped, uint256 marketUnwrapped) = unwrapInternalLogic(
                    s, withLCC, address(this), remainingAfterNet, residualWrappedForUnwrap, fromMarketDerivedAmount
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
        uint256 targetHeld = balanceOf(lcc, address(this));
        if (targetToBurn > targetHeld) {
            targetToBurn = targetHeld;
        }
        uint256 backingHeld = balanceOf(withLCC, address(this));
        if (backingToBurn > backingHeld) {
            backingToBurn = backingHeld;
        }

        // Consolidate burns: single burn call per LCC
        // Use adapter - no callback needed!
        if (targetToBurn > 0) {
            burn(lcc, address(this), 0, targetToBurn, true);
        }
        if (backingToBurn > 0) {
            burn(withLCC, address(this), 0, backingToBurn, true);
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
            uint256 currentQueueWith = s.settleQueue[withLCC][address(this)];
            uint256 claimedWith = s.nettedLCCsAsUnderlying[withLCC];
            if (claimedWith > currentQueueWith) {
                s.nettedLCCsAsUnderlying[withLCC] = currentQueueWith;
            }
        }

        // Use adapter - no callback needed!
        mint(lcc, to, directToMint, marketToMint, false);
    }

    /**
     * @notice Core unwrap logic without external transfer
     * @dev Handles the unwrapping of LCC tokens by consuming direct supply first, then market liquidity.
     *      Any shortfall is queued for settlement. This function does not transfer underlying assets;
     *      that is handled by the calling contract.
     * @param s The liquidity hub storage
     * @param lcc The LCC token address
     * @param to The recipient of the underlying asset (used for queueing shortfall)
     * @param amount The amount to unwrap
     * @param wrappedBalance The wrapped balance of the account
     * @param marketDerivedBalance The market-derived balance of the account
     * @return directUnwrapped The amount unwrapped from direct supply
     * @return marketUnwrapped The amount unwrapped from market liquidity
     */
    function unwrapInternalLogic(
        LiquidityHubStorage storage s,
        address lcc,
        address to,
        uint256 amount,
        uint256 wrappedBalance,
        uint256 marketDerivedBalance
    ) internal returns (uint256 directUnwrapped, uint256 marketUnwrapped) {
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

        // 3) Queue any shortfall to Hub itself for later processing
        if (remainingToUnwrap > 0) {
            queueSettlement(s, lcc, to, remainingToUnwrap);
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
        return IMarketFactory(market.factory).useMarketLiquidity(s.lccToUnderlying[lcc], market.id, amount);
    }

    /**
     * @notice Queues a settlement request for later processing
     * @dev Adds a settlement amount to the queue for a specific recipient.
     *      The settlement will be processed when liquidity becomes available.
     *      Note: Events are emitted by the calling contract, not this library.
     * @param s The liquidity hub storage
     * @param lcc The LCC token address
     * @param recipient The recipient address for the settlement
     * @param amount The amount to queue for settlement
     */
    function queueSettlement(LiquidityHubStorage storage s, address lcc, address recipient, uint256 amount) internal {
        s.settleQueue[lcc][recipient] += amount;
        s.totalQueued[lcc] += amount;
        // Event will be emitted by the calling contract
    }

    /// @notice Process settlement for a specific recipient using reserveOfUnderlying
    /// @dev Permissionless function that allows anyone to process settlements when liquidity is available.
    ///      Unified interface: branches behaviour based on whether recipient is address(this) (Hub) or external address.
    ///      For Hub: burns Hub-held LCC without transferring underlying or decrementing reserves.
    ///      For external: checks holder balance, burns user tokens, transfers underlying, and decrements reserves.
    /// @param s The liquidity hub storage
    /// @param lcc The LCC token address
    /// @param recipient The recipient address to settle for (address(this) for Hub's own queue)
    /// @param maxAmount The maximum amount to settle (caller can limit to avoid large gas costs)
    /// @param caller The address of the caller (for issuer check)
    function processSettlementLogic(
        LiquidityHubStorage storage s,
        address lcc,
        address recipient,
        uint256 maxAmount,
        address caller
    ) internal {
        bool isForHub = recipient == address(this);
        uint256 queued = s.settleQueue[lcc][recipient];
        if (queued == 0) revert Errors.InvalidAmount(0, 0);

        address underlying = s.lccToUnderlying[lcc];
        uint256 available = s.reserveOfUnderlying[underlying];

        uint256 holderBal = 0;
        if (isForHub) {
            // Hub-specific path: burn Hub-held LCC against available reserves
            // Does NOT transfer underlying or decrement reserveOfUnderlying (underlying stays in shared pool)
            // Note: This path should only really occur when LCCs back LCCs (via _wrapWith).
            holderBal = balanceOf(lcc, recipient);
        } else {
            // Standard path for external recipients
            // market-derived holder balance
            (, holderBal) = balancesOf(lcc, recipient);
        }

        uint256 toSettle = Math.min(Math.min(queued, available), Math.min(maxAmount, holderBal));
        if (toSettle == 0) {
            if (!isForHub) {
                revert Errors.LiquidityError(lcc, toSettle);
            }
            return;
        }

        s.settleQueue[lcc][recipient] -= toSettle;
        s.totalQueued[lcc] -= toSettle;

        if (isForHub) {
            // Reconcile lazy netted claims first, then burn only unclaimed portion
            uint256 claimed = s.nettedLCCsAsUnderlying[lcc];
            uint256 decrement = Math.min(claimed, toSettle);
            if (decrement > 0) {
                s.nettedLCCsAsUnderlying[lcc] = claimed - decrement;
            }
            // Burn the remaining amount after _wrapWith lazy netting (burning) has been accounted for.
            uint256 effectiveToBurn = toSettle - decrement;

            if (effectiveToBurn > 0) {
                // Burn Hub-held LCC; protocol-bound burn, skip bucket maps
                burn(lcc, recipient, 0, effectiveToBurn, true);
            }
        } else {
            pay(s, lcc, recipient, recipient, 0, toSettle, caller);
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
    /// @param caller The caller address (for issuer check)
    function pay(
        LiquidityHubStorage storage s,
        address lcc,
        address owner,
        address to,
        uint256 fromDirect,
        uint256 fromMarket,
        address caller
    ) internal {
        bool isIssuer = LCCFactoryLib.isCallerIssuer(s, lcc, caller);
        burn(lcc, owner, fromDirect, fromMarket, isIssuer);
        transferUnderlying(s, s.lccToUnderlying[lcc], to, fromDirect + fromMarket);
    }
}

