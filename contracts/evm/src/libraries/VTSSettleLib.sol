// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {
    BalanceDelta,
    toBalanceDelta
} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    IPoolManager
} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

import {
    VTSStorage,
    PositionAccounting,
    MarketVTSConfiguration
} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {Pool} from "../types/Pool.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {
    VTSPoolAndPositionAccountingLib
} from "./VTSPoolAndPositionAccountingLib.sol";

/// @title VTSSettleLib
/// @notice Settlement and RFS logic for VTS, operating on VTSStorage
/// @dev All helper functions are external/public for linked-library usage. Functions that are conceptually internal are prefixed with `_`.
/// @author Fiet Protocol
library VTSSettleLib {
    using SafeCast for uint256;
    using SafeCast for int256;
    using SafeCast for int128;

    // Maximum positive magnitude representable in int128
    uint256 internal constant INT128_MAX_U = uint256(type(uint128).max) >> 1;
    /// @notice Core settlement entrypoint for MM-managed positions
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position id
    /// @param lccCurrency0 The pool currency of the LCC token for token0
    /// @param lccCurrency1 The pool currency of the LCC token for token1
    /// @param delta The balance delta of the settlement
    /// @param isSeizing Whether the position is being seized
    /// @param positionRequiredSettlementDelta The required settlement delta from position modifications (from transient storage)
    /// @return settlementDelta The delta actually applied to underlying
    /// @return rfsOpen Whether the RFS is open for the position
    /// @return seizedLiquidityUnits The amount of liquidity units seized (non-zero only when seizing)
    function onMMSettle(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing,
        BalanceDelta positionRequiredSettlementDelta // TODO: To replace with currencyDelta0/1
    )
        public
        returns (
            BalanceDelta settlementDelta,
            bool rfsOpen,
            uint256 seizedLiquidityUnits
        )
    {
        Position memory pos = s.positions[positionId];
        PoolId poolId = pos.poolId;

        // Validate position exists (commitmentMax > 0 for active positions)
        PositionAccounting storage pa = s.positionAccounting[positionId];
        if (pos.owner == address(0)) {
            revert("VTSSettleLib: Invalid position");
        }

        // During withdrawals, delta is positive as per caller context. During deposits, delta is negative.
        // However, _updateSettlement accepts the inverse as a delta of the settled amount.
        // Ie. positive increases, and negative decreases the metric.
        int256 amount0 = int256(delta.amount0());
        int256 amount1 = int256(delta.amount1());

        // Settle growths and get RFS state
        BalanceDelta rfsDelta;
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(
            s,
            poolManager,
            positionId
        );
        (rfsOpen, rfsDelta) = _getRFS(s, positionId);

        // Handle settlement based on position state
        if (!pos.isActive) {
            // Inactive: unrestricted deposits/settlements
            if (amount0 != 0) {
                amount0 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    0,
                    -amount0
                );
            }
            if (amount1 != 0) {
                amount1 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    1,
                    -amount1
                );
            }
        } else if (isSeizing) {
            // Seizing: clamp deposits (negative settlementDelta) by positive rfsDelta
            int128 rfs0 = rfsDelta.amount0();
            int128 rfs1 = rfsDelta.amount1();

            // Read the required settlement delta from position modifications
            // Signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
            int128 posRequiredSettlement0 = positionRequiredSettlementDelta
                .amount0();
            int128 posRequiredSettlement1 = positionRequiredSettlementDelta
                .amount1();

            if (amount0 < 0) {
                // deposit: clamp by positive rfsDelta
                // If rfs0 > 0, we can deposit up to rfs0 (clamp amount0 to -rfs0 minimum)
                if (rfs0 > 0) {
                    int128 maxDeposit0 = -rfs0; // negative because deposits are negative
                    if (amount0 < maxDeposit0) {
                        amount0 = maxDeposit0;
                    }
                }
                amount0 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    0,
                    -amount0
                );
            } else if (amount0 > 0) {
                // withdrawal: clamp by positionRequiredSettlementDelta
                // If positionRequiredSettlementDelta > 0, clamp to min(amount0, positionRequiredSettlementDelta)
                // If positionRequiredSettlementDelta <= 0, clamp to 0
                if (posRequiredSettlement0 > 0) {
                    if (amount0 > posRequiredSettlement0) {
                        amount0 = posRequiredSettlement0;
                    }
                } else {
                    amount0 = 0;
                }
                amount0 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    0,
                    -amount0
                );
            }

            if (amount1 < 0) {
                // deposit: clamp by positive rfsDelta
                // If rfs1 > 0, we can deposit up to rfs1 (clamp amount1 to -rfs1 minimum)
                if (rfs1 > 0) {
                    int128 maxDeposit1 = -rfs1; // negative because deposits are negative
                    if (amount1 < maxDeposit1) {
                        amount1 = maxDeposit1;
                    }
                }
                amount1 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    1,
                    -amount1
                );
            } else if (amount1 > 0) {
                // withdrawal: clamp by positionRequiredSettlementDelta
                // If positionRequiredSettlementDelta > 0, clamp to min(amount1, positionRequiredSettlementDelta)
                // If positionRequiredSettlementDelta <= 0, clamp to 0
                if (posRequiredSettlement1 > 0) {
                    if (amount1 > posRequiredSettlement1) {
                        amount1 = posRequiredSettlement1;
                    }
                } else {
                    amount1 = 0;
                }
                amount1 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    1,
                    -amount1
                );
            }
        } else {
            // Active and not seizing: validate and apply RFS clamps
            if (pa.commitmentMax.token0 == 0 || pa.commitmentMax.token1 == 0) {
                revert("VTSSettleLib: Invalid position");
            }
            // For withdrawals, validate RFS closure
            bool isWithdrawal = amount0 > 0 || amount1 > 0;
            if (isWithdrawal && rfsOpen) {
                revert("VTSSettleLib: RFS open");
            }

            // Apply RFS clamps for withdrawals
            if (amount0 > 0) {
                // withdraw
                // Clamp by rfsDelta: if rfsDelta < 0, then -rfsDelta is withdrawable
                int128 rfs0 = rfsDelta.amount0();
                if (rfs0 < 0) {
                    uint256 withdrawable0 = LiquidityUtils.safeInt128ToUint256(
                        rfs0
                    );
                    if (uint256(amount0) > withdrawable0) {
                        amount0 = withdrawable0.toInt256();
                    }
                    amount0 = VTSPoolAndPositionAccountingLib._updateSettlement(
                        s,
                        positionId,
                        0,
                        -amount0
                    );
                } else {
                    // rfsDelta >= 0 means cannot withdraw
                    amount0 = 0;
                }
            } else if (amount0 < 0) {
                // deposit
                amount0 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    0,
                    -amount0
                );
            }
            if (amount1 > 0) {
                // withdraw
                // Clamp by rfsDelta: if rfsDelta < 0, then -rfsDelta is withdrawable
                int128 rfs1 = rfsDelta.amount1();
                if (rfs1 < 0) {
                    uint256 withdrawable1 = LiquidityUtils.safeInt128ToUint256(
                        rfs1
                    );
                    if (uint256(amount1) > withdrawable1) {
                        amount1 = withdrawable1.toInt256();
                    }
                    amount1 = VTSPoolAndPositionAccountingLib._updateSettlement(
                        s,
                        positionId,
                        1,
                        -amount1
                    );
                } else {
                    // rfsDelta >= 0 means cannot withdraw
                    amount1 = 0;
                }
            } else if (amount1 < 0) {
                // deposit
                amount1 = VTSPoolAndPositionAccountingLib._updateSettlement(
                    s,
                    positionId,
                    1,
                    -amount1
                );
            }
        }

        // Clamps within _updateSettlement may modify the return delta. Flip the signs on amount0 and amount1 to match caller-context delta.
        settlementDelta = LiquidityUtils.negateBalanceDelta(
            toBalanceDelta(amount0.toInt128(), amount1.toInt128())
        );

        // Calculate seized liquidity units when seizing
        if (isSeizing) {
            seizedLiquidityUnits = _calcSeizure(
                s,
                poolManager,
                positionId,
                settlementDelta
            );
        } else {
            seizedLiquidityUnits = 0;
        }

        // Proactive extraction (incremental): fund only increases in pending slashes since last observation to avoid over-funding
        {
            (int256 adj0, int256 adj1) = VTSPoolAndPositionAccountingLib
                ._peekFeeAdjustment(s, positionId);
            int256 prev0 = pa.lastFundedPendingAdj.token0;
            int256 prev1 = pa.lastFundedPendingAdj.token1;

            if (adj0 > prev0) {
                VTSPoolAndPositionAccountingLib._fundFeePot(
                    s,
                    poolManager,
                    poolId,
                    lccCurrency0,
                    0,
                    uint256(adj0 - prev0)
                );
            }
            if (adj1 > prev1) {
                VTSPoolAndPositionAccountingLib._fundFeePot(
                    s,
                    poolManager,
                    poolId,
                    lccCurrency1,
                    1,
                    uint256(adj1 - prev1)
                );
            }

            // Snapshot current pending as baseline for the next settle
            pa.lastFundedPendingAdj.token0 = adj0;
            pa.lastFundedPendingAdj.token1 = adj1;
        }
    }

    /// @notice View helper for computing RFS state and delta for a position
    /// @param s The central VTS storage
    /// @param positionId The position id
    /// @return rfsOpen Whether the RFS is open
    /// @return delta The settlement delta required/available
    function _getRFS(
        VTSStorage storage s,
        PositionId positionId
    ) public view returns (bool rfsOpen, BalanceDelta delta) {
        PositionAccounting storage pa = s.positionAccounting[positionId];
        Position memory pos = s.positions[positionId];
        Pool memory pool = s.pools[pos.poolId];

        // Get commitments
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;

        // Get settled amounts and deficits
        uint256 s0 = pa.settled.token0;
        uint256 s1 = pa.settled.token1;
        uint256 d0 = pa.cumulativeDeficit.token0;
        uint256 d1 = pa.cumulativeDeficit.token1;

        // Base-required per token (commitment * baseVTSRate). RfS gates by max(deficitReq, baseReq)
        MarketVTSConfiguration memory cfg = pool.vtsConfig;
        (uint256 base0, uint256 base1) = LiquidityUtils
            .getBaseSettlementAmounts(
                c0,
                c1,
                cfg.token0.baseVTSRate,
                cfg.token1.baseVTSRate
            );

        // Cap deficits by commitment
        uint256 defReq0 = d0 < c0 ? d0 : c0;
        uint256 defReq1 = d1 < c1 ? d1 : c1;

        // Gate by base: require at least base amounts even without deficit
        uint256 req0 = base0 > defReq0 ? base0 : defReq0;
        uint256 req1 = base1 > defReq1 ? base1 : defReq1;

        // Inflate by commitment-scoped deficit (insolvency gate), clamp by commitment
        uint256 cd0 = pa.commitmentDeficit.token0;
        uint256 cd1 = pa.commitmentDeficit.token1;
        if (cd0 > 0) {
            uint256 add0 = req0 + cd0;
            req0 = add0 > c0 ? c0 : add0;
        }
        if (cd1 > 0) {
            uint256 add1 = req1 + cd1;
            req1 = add1 > c1 ? c1 : add1;
        }

        int128 amount0 = _rfsDeltaRaw(s0, req0);
        int128 amount1 = _rfsDeltaRaw(s1, req1);

        // Spec: amount > 0 => settlement required (RfS open); amount < 0 => withdraw allowed
        rfsOpen = (amount0 > 0) || (amount1 > 0);
        delta = toBalanceDelta(amount0, amount1);
    }

    /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
    /// @param settled Current settled amount
    /// @param need Required amount
    /// @return deltaRaw Signed delta in raw units
    function _rfsDeltaRaw(
        uint256 settled,
        uint256 need
    ) public pure returns (int128 deltaRaw) {
        if (need >= settled) {
            uint256 pos = need - settled; // rfs is the needed minus the already settled
            if (pos > INT128_MAX_U) return type(int128).max;
            return pos.toInt128();
        }
        uint256 neg = settled - need; // withdrawable
        if (neg > INT128_MAX_U) return type(int128).min;
        int128 magnitude = neg.toInt128();
        return -magnitude;
    }

    /// @notice Calculates liquidity units to seize for a given position and settlement delta
    /// @param s The central VTS storage
    /// @param poolManager The pool manager contract
    /// @param positionId The position id
    /// @param settlementDelta The settlement delta applied during seizure
    /// @return seizedLiquidityUnits The liquidity units to seize
    function _calcSeizure(
        VTSStorage storage s,
        IPoolManager poolManager,
        PositionId positionId,
        BalanceDelta settlementDelta
    ) public returns (uint256 seizedLiquidityUnits) {
        // Settle growths first
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(
            s,
            poolManager,
            positionId
        );

        Position memory pos = s.positions[positionId];
        (bool rfsOpen, BalanceDelta rfsDelta) = _getRFS(s, positionId);
        if (!rfsOpen) {
            revert("VTSSettleLib: RFS not open");
        }

        PositionAccounting storage pa = s.positionAccounting[positionId];
        Pool memory pool = s.pools[pos.poolId];

        // Commitments and RfS amounts
        uint256 c0 = pa.commitmentMax.token0;
        uint256 c1 = pa.commitmentMax.token1;
        uint256 r0 = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount0());
        uint256 r1 = LiquidityUtils.safeInt128ToUint256(rfsDelta.amount1());
        uint256 s0 = LiquidityUtils.safeInt128ToUint256(
            settlementDelta.amount0()
        );
        uint256 s1 = LiquidityUtils.safeInt128ToUint256(
            settlementDelta.amount1()
        );

        MarketVTSConfiguration memory cfg = pool.vtsConfig;

        // 1) Base exposures (RfS/commitment, floored by VTS_base)
        uint256 e0bps = LiquidityUtils.exposureBps(r0, c0);
        uint256 e1bps = LiquidityUtils.exposureBps(r1, c1);
        if (cfg.token0.baseVTSRate > e0bps) {
            e0bps = cfg.token0.baseVTSRate;
        }
        if (cfg.token1.baseVTSRate > e1bps) {
            e1bps = cfg.token1.baseVTSRate;
        }

        // 2) Determine a portion of the seizure exposure proportional to settled / RfS amount
        uint256 p0bps = LiquidityUtils.settleOfRfsBps(s0, r0);
        uint256 p1bps = LiquidityUtils.settleOfRfsBps(s1, r1);

        // 3) Calculate seized liquidity units based on exposure / commitment sized by settlement
        uint256 liq = uint256(pos.liquidity);
        uint256 u0 = LiquidityUtils.seizedUnitsFromBps(liq, e0bps, p0bps);
        uint256 u1 = LiquidityUtils.seizedUnitsFromBps(liq, e1bps, p1bps);

        // 4) Cap at full position liquidity and apply residual threshold
        uint256 total = u0 + u1;

        // Apply residual threshold: if remaining liquidity would be below minResidualUnits, fully close the position
        uint256 minResidual = cfg.minResidualUnits == 0
            ? 1
            : cfg.minResidualUnits;
        if (total < liq) {
            if ((liq - total) < minResidual) {
                total = liq;
            }
        } else if (total > liq) {
            // Final clamp to ensure we don't exceed position liquidity
            total = liq;
        }

        return total;
    }
}
