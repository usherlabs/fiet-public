// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {
    ModifyLiquidityParams
} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {VTSStorage, PositionAccounting, PoolAccounting} from "../types/VTS.sol";
import {PositionId} from "../types/Position.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";

/// @title VTSPoolAndPositionAccountingLib
/// @notice Pool and position-level accounting helpers for VTS, operating on VTSStorage
/// @dev All functions are external for linked-library usage but prefixed with `_` as they are conceptually internal.
library VTSPoolAndPositionAccountingLib {
    using SafeCast for uint256;

    /// @notice Tracks the maximum potential commitment for both tokens in a position
    /// @param s The central VTS storage
    /// @param positionId The ascribed id of the position
    /// @param params The parameters of the transaction
    function _trackCommitment(
        VTSStorage storage s,
        PositionId positionId,
        ModifyLiquidityParams calldata params
    ) external {
        PositionAccounting storage pa = s.positionAccounting[positionId];

        // Current tracked maxima for this position
        uint256 currentC0 = pa.commitmentMax0;
        uint256 currentC1 = pa.commitmentMax1;

        if (params.liquidityDelta > 0) {
            // Liquidity added: increase tracked maxima by the delta's maxima over the tick range
            // Cast int256 -> uint256 -> uint128 to preserve full uint128 range (not limited by int128 max)
            uint128 liquidityAdded = uint256(params.liquidityDelta).toUint128();
            (uint256 addC0, uint256 addC1) = LiquidityUtils
                .calculateCommitmentMaxima(
                    params.tickLower,
                    params.tickUpper,
                    liquidityAdded
                );

            pa.commitmentMax0 = currentC0 + addC0;
            pa.commitmentMax1 = currentC1 + addC1;
        } else if (params.liquidityDelta < 0) {
            // Liquidity removed: decrease tracked maxima by the delta's maxima over the tick range
            uint128 liquidityRemoved = uint256(-params.liquidityDelta)
                .toUint128();
            (uint256 subC0, uint256 subC1) = LiquidityUtils
                .calculateCommitmentMaxima(
                    params.tickLower,
                    params.tickUpper,
                    liquidityRemoved
                );

            // Clamp at zero to avoid underflow; if fully removed, both become zero
            pa.commitmentMax0 = currentC0 > subC0 ? (currentC0 - subC0) : 0;
            pa.commitmentMax1 = currentC1 > subC1 ? (currentC1 - subC1) : 0;
        } else {
            // No-op if liquidityDelta == 0 (poke)
            return;
        }
    }

    /// @notice Updates the settlement amount by a delta which could be positive or negative
    /// @param s The central VTS storage
    /// @param id The position id
    /// @param tokenIndex The token index (0 or 1)
    /// @param delta The delta of the settlement
    /// @return applied The applied delta to the total settlement amount
    function _updateSettlement(
        VTSStorage storage s,
        PositionId id,
        uint8 tokenIndex,
        int256 delta
    ) external returns (int256 applied) {
        // Derive poolId from position to minimise parameters
        PoolId poolId = s.positions[id].poolId;
        PositionAccounting storage pa = s.positionAccounting[id];
        PoolAccounting storage paPool = s.poolAccounting[poolId];

        // Read current settled amount and commitment maxima for the selected token
        uint256 cur;
        uint256 c;
        uint256 cumulativeDef;
        uint256 commitmentDef;
        int256 netSinceLastMod;
        uint256 poolNetSinceLastMod;

        if (tokenIndex == 0) {
            cur = pa.settled0;
            c = pa.commitmentMax0;
            cumulativeDef = pa.cumulativeDeficit0;
            commitmentDef = pa.commitmentDeficit0;
            netSinceLastMod = pa.netSettlementSinceLastMod0;
            poolNetSinceLastMod = paPool.poolNetSinceLastMod0;
        } else {
            cur = pa.settled1;
            c = pa.commitmentMax1;
            cumulativeDef = pa.cumulativeDeficit1;
            commitmentDef = pa.commitmentDeficit1;
            netSinceLastMod = pa.netSettlementSinceLastMod1;
            poolNetSinceLastMod = paPool.poolNetSinceLastMod1;
        }

        if (delta == 0) {
            return 0;
        }
        uint256 next = cur;

        if (delta > 0) {
            // Auto-net any lingering deficit first
            if (cumulativeDef > 0) {
                uint256 cover = uint256(delta) > cumulativeDef
                    ? cumulativeDef
                    : uint256(delta);
                if (cover > 0) {
                    cumulativeDef -= cover;
                    // keep global coherent
                    if (tokenIndex == 0) {
                        uint256 gD0 = paPool.globalDeficit0;
                        paPool.globalDeficit0 = cover <= gD0
                            ? (gD0 - cover)
                            : 0;
                    } else {
                        uint256 gD1 = paPool.globalDeficit1;
                        paPool.globalDeficit1 = cover <= gD1
                            ? (gD1 - cover)
                            : 0;
                    }
                    delta -= int256(cover);
                }
            }
            // Then net against commitment-scoped deficit (insolvency gate)
            if (delta > 0 && commitmentDef > 0) {
                uint256 coverCd = uint256(delta) > commitmentDef
                    ? commitmentDef
                    : uint256(delta);
                if (coverCd > 0) {
                    commitmentDef -= coverCd;
                    delta -= int256(coverCd);
                }
            }

            if (delta > 0) {
                next = cur + uint256(delta);
                if (next > c) {
                    // clamp to commitment maxima
                    next = c;
                }
            }
        } else {
            // Negative delta: reduce settled, never create deficit here
            uint256 subtract = uint256(-delta);
            if (cur < subtract) {
                subtract = cur;
            }
            next = cur - subtract;
        }

        // Write back updated settlement and accounting fields based on token index
        if (tokenIndex == 0) {
            pa.settled0 = next;
            pa.cumulativeDeficit0 = cumulativeDef;
            pa.commitmentDeficit0 = commitmentDef;
        } else {
            pa.settled1 = next;
            pa.cumulativeDeficit1 = cumulativeDef;
            pa.commitmentDeficit1 = commitmentDef;
        }

        applied = next.toInt256() - cur.toInt256(); // output delta

        // Accrue persistent nets since last fee finalisation
        if (tokenIndex == 0) {
            pa.netSettlementSinceLastMod0 = netSinceLastMod + applied;
            if (applied >= 0) {
                paPool.poolNetSinceLastMod0 =
                    poolNetSinceLastMod +
                    uint256(applied);
            } else {
                uint256 dec = uint256(-applied);
                uint256 curPoolNet = poolNetSinceLastMod;
                paPool.poolNetSinceLastMod0 = dec > curPoolNet
                    ? 0
                    : (curPoolNet - dec);
            }
        } else {
            pa.netSettlementSinceLastMod1 = netSinceLastMod + applied;
            if (applied >= 0) {
                paPool.poolNetSinceLastMod1 =
                    poolNetSinceLastMod +
                    uint256(applied);
            } else {
                uint256 dec = uint256(-applied);
                uint256 curPoolNet = poolNetSinceLastMod;
                paPool.poolNetSinceLastMod1 = dec > curPoolNet
                    ? 0
                    : (curPoolNet - dec);
            }
        }
    }
}
