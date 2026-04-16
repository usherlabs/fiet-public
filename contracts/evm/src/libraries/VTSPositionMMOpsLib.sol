// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {VTSStorage, PositionContext, TouchPositionParams, TouchPositionResult} from "../types/VTS.sol";
import {
    PositionId,
    PositionModificationHookData,
    PositionModificationHookDataLib,
    MMIncreaseHookExtraData
} from "../types/Position.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "./Errors.sol";
import {VTSCommitLib} from "./VTSCommitLib.sol";
import {CheckpointLibrary} from "./Checkpoint.sol";
import {OwnerCurrencyDelta} from "./OwnerCurrencyDelta.sol";
import {MarketCurrencyDelta} from "./MarketCurrencyDelta.sol";
import {VTSPositionLib} from "./VTSPositionLib.sol";
import {IMarketVault} from "../interfaces/IMarketVault.sol";
import {ICanonicalVault} from "../interfaces/ICanonicalVault.sol";

/// @title VTSPositionMMOpsLib
/// @notice Hot linked library: MM liquidity modify tail (LCC issue/cancel, protocol-credit, vault routing, RFS mark).
/// @dev Registration and core `touchPosition` accounting remain in `VTSPositionLib`.
/// @author Fiet Protocol
library VTSPositionMMOpsLib {
    using SafeCast for uint256;
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @dev Shared protocol-credit deposit inputs for MM add and explicit settle-from-deltas paths.
    struct ProtocolCreditSettlementParams {
        IMarketVault marketVault;
        PositionId positionId;
        address owner;
        Currency lccCurrency0;
        Currency lccCurrency1;
        uint256 intendedSettle0;
        uint256 intendedSettle1;
        BalanceDelta requiredSettlementDelta;
        BalanceDelta rfsDelta;
        bool clampToRequiredSettlement;
        bool isSeizing;
    }

    /// @dev Shared protocol-credit deposit result.
    struct ProtocolCreditSettlementResult {
        BalanceDelta settlementDelta;
        BalanceDelta remainingRequiredSettlementDelta;
    }

    /// @dev Single-lane protocol-credit settlement inputs to keep helper calls below stack limits.
    struct ProtocolCreditSettlementLaneParams {
        PositionId positionId;
        address owner;
        Currency underlyingCurrency;
        uint8 tokenIndex;
        int128 currentUnderlyingDelta;
        uint256 intendedSettle;
        int128 requiredSettlementDelta;
        int128 rfsDelta;
        bool clampToRequiredSettlement;
        bool isSeizing;
    }

    /// @notice MM liquidity-modify tail: LCC issue/cancel, protocol-credit, vault routing, RFS checkpoint.
    /// @dev Invoked from `VTSPositionLib.touchPosition` when hook data is an MM operation. `PoolManager.modifyLiquidity`
    ///      passes hook-time `callerDelta = poolPrincipalDelta + feesAccrued` into `afterModifyLiquidity`; the hook's
    ///      returned delta is applied only after the hook returns. LCC principal for issue/cancel and queue routing must
    ///      therefore be `callerDelta - feesAccrued` (pool principal only), not net of `feeAdj`. Fee slash/bonus is
    ///      reconciled when MMPM takes LCC and classifies fee vs non-fee (`PositionManagerImpl._handleLccBalanceIncrease`).
    /// @param requiredSettlementDelta Required settlement delta computed during the touch accounting phase.
    function processMMOperations(
        VTSStorage storage s,
        PositionContext memory ctx,
        TouchPositionParams calldata p,
        TouchPositionResult memory result,
        BalanceDelta requiredSettlementDelta
    ) external {
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(p.hookData);
        if (!PositionModificationHookDataLib.isMMOperation(mmData)) return;

        // True principal liquidity change (maps to LCC mint/burn for the position delta). `feesAccrued` is informational
        // fee collection in this modify; it is not part of principal. Do not subtract `feeAdj` here — that would double-
        // count hook settlement relative to the post-hook transfer amount the router uses for custodian forwarding.
        BalanceDelta principalDelta = p.callerDelta - p.feesAccrued;

        // NOTE: LCC fee credits are handled at the MMPM level via balance sync pattern.
        // After MMPM takes from PoolManager, it syncs the LCC balance as credit to locker.
        // This allows direct _take calls for LCC without a separate collectFees function.

        // Handle LCC issuance/cancellation based on liquidity direction
        if (p.params.liquidityDelta > 0) {
            // Adding liquidity: settle any hook-carried protocol credit before backing validation/LCC issuance.
            requiredSettlementDelta = _applyInHookProtocolSettlementForMmIncrease(
                s, ctx, p.owner, result.id, p.poolKey, p.hookData, requiredSettlementDelta
            );
            _handleLiquidityIncrease(
                s,
                ctx,
                p.poolKey,
                p.params,
                VTSPositionLib.LiquidityIncreaseParams({
                    owner: p.owner, commitId: mmData.commitId, positionId: result.id, principalDelta: principalDelta
                })
            );
        } else if (p.params.liquidityDelta < 0) {
            // Re-decode hookData to get locker - scoped to free memory
            //
            // Intended beneficiary / queue recipient model (always hook-data `locker`, not a separate owner lookup):
            // - Normal liquidity decrease: locker is the party executing the batch (NFT owner or approved operator on MMPM).
            // - Seizure decrease: locker is the seizer (guarantor). Same encoding path; `isSeizing` only changes principal/settlement deltas.
            //
            // queueRecipient == MM batch locker == LiquidityHub settleQueue recipient for this decrease/seizure.
            // MMQueueCustodian records the same address as the beneficiary so COLLECT_AVAILABLE_LIQUIDITY can only
            // release LCC from the slice matching the caller's queue.
            address queueRecipient;
            {
                queueRecipient = PositionModificationHookDataLib.getLocker(mmData);
            }

            // Snapshot routing: `_handleLiquidityDecrease` splits vault-immediate vs Hub queue. Only the sum of
            // those two leaves live `settled` here; any shortfall that cannot be queued stays in `pa.settled`
            // until later liquidity. Booking that remainder on `DynamicCurrencyDelta` would create batch uncleared
            // positive underlying delta (DELTA-01) while the vault cannot pay it in the same unlock.
            BalanceDelta underlyingDeltaSettlement;
            BalanceDelta exportedForSettlementClamp;
            if (mmData.seizure.isSeizing) {
                // @note: For Seizures,
                // - LCCs are received directly by locker simiarly to fees.
                // - Unwrapping these LCCs draws from the MM settled amounts, either immediately or via settlement queue - allowing protocol coverage to be maintained.
                // - For any excess, this can also be settled immediately via MM operations.

                // Only cancel excess settled received.
                (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                    ctx, p.owner, p.poolKey, requiredSettlementDelta, requiredSettlementDelta, queueRecipient
                );
            } else {
                // Removing liquidity: Cancel LCCs without seizing.

                // @note We cannot cancel directly at this point in the flow,
                // The LCC's are not yet deposited into the MMPM by the poolManager - as we're during modification of liquidity.
                // Therefore, we plan to cancel the LCC's and queue the settlement once this settlement occurs.
                // This relies on the current MM path immediately performing the matching PoolManager -> MMPM take
                // once modifyLiquidity(...) returns, before any same-key planned cancel can be restaged.
                (underlyingDeltaSettlement, exportedForSettlementClamp) = _handleLiquidityDecrease(
                    ctx, p.owner, p.poolKey, principalDelta, requiredSettlementDelta, queueRecipient
                );
            }
            VTSPositionLib._applySettlementClampFromExcess(
                s,
                result.id,
                LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount0()),
                LiquidityUtils.safeInt128ToUint256(exportedForSettlementClamp.amount1())
            );

            requiredSettlementDelta = underlyingDeltaSettlement;
        }

        if (!LiquidityUtils.isZeroDelta(requiredSettlementDelta)) {
            // Account underlying currency settlement obligations to MMPositionManager
            // Split model: Underlying settlement deltas on MMPM represent market liquidity claims (settle-only)
            // Balance syncs from wrap/unwrap target locker (msgSender) for takeable credits
            //
            // Accumulate per-batch: `accountUnderlyingSettlementDelta` is setter-style (targets absolute pair), so
            // multiple MM ops in the same unlock for the same owner/currency lane must add onto the current pair.
            BalanceDelta currentUnderlying =
                OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.poolKey.currency0, p.poolKey.currency1);
            OwnerCurrencyDelta.accountUnderlyingSettlementDelta(
                p.owner,
                LiquidityUtils.safeToBalanceDelta(
                    int256(currentUnderlying.amount0()) + int256(requiredSettlementDelta.amount0()),
                    int256(currentUnderlying.amount1()) + int256(requiredSettlementDelta.amount1())
                ),
                p.poolKey.currency0,
                p.poolKey.currency1
            );

            if (requiredSettlementDelta.amount0() > 0) {
                Currency underlyingCurrency0 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency0);
                ctx.marketVault
                    .decreaseLiquidityReserve(
                        underlyingCurrency0, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                    );
                MarketCurrencyDelta.addProduced(
                    ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                    underlyingCurrency0,
                    LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount0())
                );
            }
            if (requiredSettlementDelta.amount1() > 0) {
                Currency underlyingCurrency1 = OwnerCurrencyDelta.lccToUnderlyingCurrency(p.poolKey.currency1);
                ctx.marketVault
                    .decreaseLiquidityReserve(
                        underlyingCurrency1, LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                    );
                MarketCurrencyDelta.addProduced(
                    ICanonicalVault(ctx.marketVault.canonicalVault()).marketFactory(),
                    underlyingCurrency1,
                    LiquidityUtils.safeInt128ToUint256(requiredSettlementDelta.amount1())
                );
            }
        }

        // Mark RFS checkpoint
        (, BalanceDelta rfsDelta) = VTSPositionLib.getRFS(s, result.id);
        CheckpointLibrary.markCheckpoint(s, result.id, VTSPositionLib._rfsOpenMask(rfsDelta));
    }

    /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
    function settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
        external
        returns (ProtocolCreditSettlementResult memory result)
    {
        result = _settleFromPositiveUnderlyingDelta(s, p);
    }

    /// @dev Applies one protocol-credit deposit lane by consuming live positive underlying delta.
    function _consumePositiveUnderlyingDeltaForSettlementLane(
        VTSStorage storage s,
        ProtocolCreditSettlementLaneParams memory p
    ) private returns (int128 settlementDelta, int128 remainingRequiredSettlementDelta, uint256 settledIncrease) {
        remainingRequiredSettlementDelta = p.requiredSettlementDelta;
        if (p.currentUnderlyingDelta <= 0 || p.intendedSettle == 0) {
            return (0, remainingRequiredSettlementDelta, 0);
        }
        if (p.clampToRequiredSettlement && p.requiredSettlementDelta >= 0) {
            return (0, remainingRequiredSettlementDelta, 0);
        }

        uint256 availableCredit = LiquidityUtils.safeInt128ToUint256(p.currentUnderlyingDelta);
        uint256 requestedAmount = p.intendedSettle;
        if (requestedAmount > availableCredit) requestedAmount = availableCredit;
        if (p.clampToRequiredSettlement) {
            uint256 requiredAmount = LiquidityUtils.safeInt128ToUint256(p.requiredSettlementDelta);
            if (requestedAmount > requiredAmount) requestedAmount = requiredAmount;
        }
        if (p.isSeizing) {
            if (p.rfsDelta <= 0) return (0, remainingRequiredSettlementDelta, 0);
            uint256 maxSeizingDeposit = LiquidityUtils.safeInt128ToUint256(p.rfsDelta);
            if (requestedAmount > maxSeizingDeposit) requestedAmount = maxSeizingDeposit;
        }
        if (requestedAmount == 0) return (0, remainingRequiredSettlementDelta, 0);

        (int256 totalApplied, int256 settledDeltaOnly) =
            VTSPositionLib._vUpdateSettlement(s, p.positionId, p.tokenIndex, requestedAmount.toInt256());
        if (totalApplied <= 0) return (0, remainingRequiredSettlementDelta, 0);

        uint256 creditConsumed = uint256(totalApplied);
        OwnerCurrencyDelta.accountDelta(p.underlyingCurrency, -creditConsumed.toInt128(), p.owner);
        settlementDelta = -creditConsumed.toInt128();
        if (settledDeltaOnly > 0) {
            settledIncrease = uint256(settledDeltaOnly);
        }
        if (p.clampToRequiredSettlement) {
            // MM in-hook backing: only the portion that increases `pa.settled` satisfies the deposit requirement.
            // Deficit / commitment-deficit cure consumes credit but must not over-clear `requiredSettlementDelta`.
            if (settledDeltaOnly > 0) {
                remainingRequiredSettlementDelta += uint256(settledDeltaOnly).toInt128();
            }
        }
    }

    /// @dev Shared protocol-credit deposit primitive reused by MM add and explicit settle-from-deltas paths.
    function _settleFromPositiveUnderlyingDelta(VTSStorage storage s, ProtocolCreditSettlementParams memory p)
        private
        returns (ProtocolCreditSettlementResult memory result)
    {
        BalanceDelta currentUnderlying =
            OwnerCurrencyDelta.getUnderlyingDeltaPair(p.owner, p.lccCurrency0, p.lccCurrency1);
        (int128 settle0, int128 remaining0, uint256 settledIncrease0) = _consumePositiveUnderlyingDeltaForSettlementLane(
            s,
            ProtocolCreditSettlementLaneParams({
                positionId: p.positionId,
                owner: p.owner,
                underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                tokenIndex: 0,
                currentUnderlyingDelta: currentUnderlying.amount0(),
                intendedSettle: p.intendedSettle0,
                requiredSettlementDelta: p.requiredSettlementDelta.amount0(),
                rfsDelta: p.rfsDelta.amount0(),
                clampToRequiredSettlement: p.clampToRequiredSettlement,
                isSeizing: p.isSeizing
            })
        );
        (int128 settle1, int128 remaining1, uint256 settledIncrease1) = _consumePositiveUnderlyingDeltaForSettlementLane(
            s,
            ProtocolCreditSettlementLaneParams({
                positionId: p.positionId,
                owner: p.owner,
                underlyingCurrency: OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                tokenIndex: 1,
                currentUnderlyingDelta: currentUnderlying.amount1(),
                intendedSettle: p.intendedSettle1,
                requiredSettlementDelta: p.requiredSettlementDelta.amount1(),
                rfsDelta: p.rfsDelta.amount1(),
                clampToRequiredSettlement: p.clampToRequiredSettlement,
                isSeizing: p.isSeizing
            })
        );

        result.settlementDelta = toBalanceDelta(settle0, settle1);
        result.remainingRequiredSettlementDelta = toBalanceDelta(remaining0, remaining1);

        if (settle0 < 0) {
            MarketCurrencyDelta.consumeProduced(
                ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0),
                LiquidityUtils.safeInt128ToUint256(settle0)
            );
        }
        if (settle1 < 0) {
            MarketCurrencyDelta.consumeProduced(
                ICanonicalVault(p.marketVault.canonicalVault()).marketFactory(),
                OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1),
                LiquidityUtils.safeInt128ToUint256(settle1)
            );
        }
        if (settledIncrease0 > 0) {
            p.marketVault
                .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency0), settledIncrease0);
        }
        if (settledIncrease1 > 0) {
            p.marketVault
                .increaseLiquidityReserve(OwnerCurrencyDelta.lccToUnderlyingCurrency(p.lccCurrency1), settledIncrease1);
        }
    }

    /// @dev Settles protocol credit inside the MM add-liquidity hook path before LCC issuance/backing validation.
    function _applyInHookProtocolSettlementForMmIncrease(
        VTSStorage storage s,
        PositionContext memory ctx,
        address owner,
        PositionId positionId,
        PoolKey memory poolKey,
        bytes memory hookData,
        BalanceDelta requiredSettlementDelta
    ) private returns (BalanceDelta remainingRequiredSettlementDelta) {
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decode(hookData);
        MMIncreaseHookExtraData memory extra = PositionModificationHookDataLib.decodeMMIncreaseHookExtraData(mmData);
        if (!extra.settleInHook) return requiredSettlementDelta;

        ProtocolCreditSettlementResult memory settled = _settleFromPositiveUnderlyingDelta(
            s,
            ProtocolCreditSettlementParams({
                marketVault: ctx.marketVault,
                positionId: positionId,
                owner: owner,
                lccCurrency0: poolKey.currency0,
                lccCurrency1: poolKey.currency1,
                intendedSettle0: extra.intendedSettle0,
                intendedSettle1: extra.intendedSettle1,
                requiredSettlementDelta: requiredSettlementDelta,
                rfsDelta: BalanceDelta.wrap(0),
                clampToRequiredSettlement: true,
                isSeizing: false
            })
        );

        remainingRequiredSettlementDelta = settled.remainingRequiredSettlementDelta;
    }

    // --------------------------------------------------
    // LCC Issuance/Cancellation Helpers
    // --------------------------------------------------

    /// @notice Handle liquidity increase (mint or add liquidity) - issues LCCs
    /// @param s The VTS storage
    /// @param ctx The position context
    /// @param poolKey The pool key
    /// @param params The modify liquidity params
    /// @param p The liquidity increase params (bundled for stack depth)
    function _handleLiquidityIncrease(
        VTSStorage storage s,
        PositionContext memory ctx,
        PoolKey memory poolKey,
        ModifyLiquidityParams memory params,
        VTSPositionLib.LiquidityIncreaseParams memory p
    ) private {
        // Calculate amounts in scoped block
        uint256 amount0;
        uint256 amount1;
        {
            // Negative delta means LP deposited tokens
            amount0 =
                p.principalDelta.amount0() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount0()) : 0;
            amount1 =
                p.principalDelta.amount1() < 0 ? LiquidityUtils.safeInt128ToUint256(p.principalDelta.amount1()) : 0;
            if (amount0 == 0 && amount1 == 0) return;
        }

        // Validate commitment backing in scoped block.
        // `touchPosition` updates `positions[positionId].liquidity` to post-modify liquidity before this MM tail runs,
        // so use that total for issued-value (COMMIT-01), not the incremental `params.liquidityDelta` alone.
        {
            (uint160 sqrtPriceX96, int24 currentTick,,) = ctx.poolManager.getSlot0(poolKey.toId());
            uint128 postAddLiquidity = s.positions[p.positionId].liquidity;
            VTSCommitLib.validateLiquidityDelta(
                s,
                ctx.oracleHelper,
                p.commitId,
                p.positionId,
                VTSCommitLib.LiquidityDeltaParams({
                    currency0: poolKey.currency0,
                    currency1: poolKey.currency1,
                    sqrtPriceX96: sqrtPriceX96,
                    currentTick: currentTick,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidityDelta: SafeCast.toInt256(postAddLiquidity)
                }),
                true
            );
        }

        // Issue LCC tokens in scoped block
        {
            if (amount0 > 0) {
                ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency0), p.owner, amount0);
            }
            if (amount1 > 0) {
                ctx.liquidityHub.issue(Currency.unwrap(poolKey.currency1), p.owner, amount1);
            }
        }
    }

    /// @dev Stack-isolated core for MM decrease vault vs queue split (used by `_handleLiquidityDecrease` and tests).
    // if shortfall <= principal, then yes: settleable + queued == excess
    // if shortfall > principal, then no: settleable + queued < excess
    // Therefore export != excess, and we must accomodate.
    function _computeLiquidityDecreaseRoutingSplit(
        PositionContext memory ctx,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta
    )
        internal
        view
        returns (
            uint256 retainedPrincipal0,
            uint256 retainedPrincipal1,
            BalanceDelta settleableDelta,
            BalanceDelta queuedDelta,
            BalanceDelta underlyingDeltaSettlement,
            BalanceDelta exportedForSettlementClamp
        )
    {
        uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
        uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
        int128 req0 = requiredSettlementDelta.amount0();
        int128 req1 = requiredSettlementDelta.amount1();

        {
            BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
            BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
            int128 shortfall0 = rawShortfall.amount0();
            int128 shortfall1 = rawShortfall.amount1();
            if (shortfall0 < 0) shortfall0 = 0;
            if (shortfall1 < 0) shortfall1 = 0;

            settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);

            uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
            uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
            retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
            retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
        }

        queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
        underlyingDeltaSettlement = settleableDelta;
        exportedForSettlementClamp = toBalanceDelta(
            SafeCast.toInt128(int256(settleableDelta.amount0()) + int256(queuedDelta.amount0())),
            SafeCast.toInt128(int256(settleableDelta.amount1()) + int256(queuedDelta.amount1()))
        );
    }

    /// @notice Handle liquidity decrease (remove liquidity or burn) - cancels LCCs
    /// @dev Stages path-keyed planned cancels for the subsequent PoolManager -> MMPM LCC transfer.
    ///      This helper is correct only because the surrounding MM decrease flow immediately
    ///      performs that transfer after `modifyLiquidity(...)` returns.
    /// @param ctx The position context
    /// @param owner The position owner
    /// @param poolKey The pool key
    /// @param principalDelta The principal delta after fee adjustments
    /// @param requiredSettlementDelta The required settlement delta from touchPosition
    /// @param queueRecipient The recipient for settlement queue (locker)
    /// @return underlyingDeltaSettlement Portion routed to `DynamicCurrencyDelta` (vault-immediate slice only).
    /// @return exportedForSettlementClamp Amount to remove from live `settled`: immediate slice plus queued principal.
    function _handleLiquidityDecrease(
        PositionContext memory ctx,
        address owner,
        PoolKey memory poolKey,
        BalanceDelta principalDelta,
        BalanceDelta requiredSettlementDelta,
        address queueRecipient
    ) internal returns (BalanceDelta underlyingDeltaSettlement, BalanceDelta exportedForSettlementClamp) {
        uint256 retainedPrincipal0;
        uint256 retainedPrincipal1;
        (retainedPrincipal0, retainedPrincipal1,,, underlyingDeltaSettlement, exportedForSettlementClamp) =
            _computeLiquidityDecreaseRoutingSplit(ctx, principalDelta, requiredSettlementDelta);

        if (LiquidityUtils.isZeroDelta(principalDelta)) {
            return (underlyingDeltaSettlement, exportedForSettlementClamp);
        }

        uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
        uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());

        // 3. Queue settlements via cancelWithQueue
        // Burns LCCs on transfer from PoolManager to owner (MMPM) and queues shortfall for queueRecipient (locker).
        // Only cancel LCCs for tokens that have non-zero principal delta (tokens actually removed from liquidity)
        // Process token0 cancellation
        {
            if (principalAmount0 > 0) {
                ctx.liquidityHub
                    .planCancelWithQueue(
                        Currency.unwrap(poolKey.currency0),
                        address(ctx.poolManager),
                        owner,
                        principalAmount0,
                        retainedPrincipal0,
                        queueRecipient
                    );
            }
        }

        // Process token1 cancellation
        {
            if (principalAmount1 > 0) {
                ctx.liquidityHub
                    .planCancelWithQueue(
                        Currency.unwrap(poolKey.currency1),
                        address(ctx.poolManager),
                        owner,
                        principalAmount1,
                        retainedPrincipal1,
                        queueRecipient
                    );
            }
        }

        // 4. Actual queued amounts are tracked in LiquidityHub as owed to queueRecipient.
        // When _collectAvailableLiquidity is called, underlying is transferred to the recipient.
        // If recipient is MMPM, the balance is synced to the locker's delta.
        // Any shortfall remainder beyond this call's cancellable principal stays in live `settled` (not transient delta).
    }
}
