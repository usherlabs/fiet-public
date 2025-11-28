// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionMeta} from "../types/Position.sol";
import {PositionId} from "../types/Position.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {MMPositionManager} from "../MMPositionManager.sol";
import {Errors} from "./Errors.sol";
import {Position} from "../types/Position.sol";
import {
    VTSStorage,
    PositionAccounting,
    PoolAccounting,
    TokenPairUint,
    TokenPairInt,
    TokenPairLib
} from "../types/VTS.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PositionLibrary} from "../types/Position.sol";
import {ModifyLiquidityParams} from "v4-periphery/lib/v4-core/src/types/PoolOperation.sol";
import {SafeCast} from "v4-periphery/lib/v4-core/src/libraries/SafeCast.sol";
import {console} from "forge-std/console.sol";
import {IPoolManager} from "v4-periphery/lib/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol";
import {TransientStateLibrary} from "v4-periphery/lib/v4-core/src/libraries/TransientStateLibrary.sol";
import {BalanceDelta, toBalanceDelta} from "v4-periphery/lib/v4-core/src/types/BalanceDelta.sol";
import {VTSCommitLib} from "./VTSCommitLib.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {TokenPairUint} from "../types/VTS.sol";
import {TransientSlots} from "./TransientSlots.sol";
import {VTSPoolAndPositionAccountingLib} from "./VTSPoolAndPositionAccountingLib.sol";
import {VTSSettleLib} from "./VTSSettleLib.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @title MMPositionsLib
/// @notice Library for managing MM-managed positions
/// @dev All helper functions are external/public for linked-library usage. Functions that are conceptually internal are prefixed with `_`.
/// @author Fiet Protocol
library MMPositionsLib {
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using TokenPairLib for TokenPairUint;
    using TokenPairLib for TokenPairInt;
    using CurrencySettler for Currency;

    function _registerPosition(
        VTSStorage storage s,
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params
    ) public {
        // Derive position id consistent with Uniswap position keying
        PositionId id = PositionLibrary.generateId(owner, params);

        // Check if already registered
        if (s.positions[id].owner != address(0)) {
            revert Errors.AlreadyRegistered(id);
        }

        // Register the position in VTSStorage
        s.positions[id] = Position({
            owner: owner,
            poolId: poolId,
            commitId: 0, // Will be set when position is associated with a commit
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: SafeCast.toUint128(uint256(params.liquidityDelta)),
            isActive: true,
            salt: params.salt
        });
    }

    /// @notice Create a new position
    /// @param s The VTS storage
    /// @param positionManager The position manager address
    /// @param positionId The position id
    /// @param tokenId The token id
    function _linkPositionToCommit(
        VTSStorage storage s,
        address positionManager,
        PositionId positionId,
        uint256 tokenId
    ) external returns (uint256 positionCount) {
        // validate there is an existing commit for the token id
        if (s.commits[tokenId].expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }

        // get the number of positions for the token id from the commitment
        positionCount = s.commits[tokenId].positionCount;

        // modify the commit to inlcude the position and update the position count
        s.commits[tokenId].positions[positionCount] = positionId;
        s.commits[tokenId].positionCount++;

        // update the commitId of the position i.e associate the position with the commit
        // as specified in `MMPositionsLib._createPosition L67`
        s.positions[positionId].commitId = tokenId;
    }

    /// @notice Get a position by PositionId
    /// @param s The VTS storage
    /// @param id The position id
    /// @param requireActive Whether to require the position to be active
    /// @param revertIfInvalid Whether to revert if the position is invalid
    /// @return The position meta data
    function _getPosition(VTSStorage storage s, PositionId id, bool requireActive, bool revertIfInvalid)
        external
        view
        returns (PositionMeta memory)
    {
        Position memory pos = s.positions[id];
        if (pos.owner == address(0)) {
            if (revertIfInvalid) revert Errors.InvalidPosition(0, 0, id);
            return PositionMeta({
                tickLower: 0,
                tickUpper: 0,
                liquidity: 0,
                owner: address(0),
                isActive: false,
                poolId: PoolId.wrap(bytes32(0))
            });
        }
        if (requireActive && !pos.isActive) {
            if (revertIfInvalid) revert Errors.InvalidPosition(0, 0, id);
            return PositionMeta({
                tickLower: pos.tickLower,
                tickUpper: pos.tickUpper,
                liquidity: int256(uint256(pos.liquidity)),
                owner: pos.owner,
                isActive: false,
                poolId: pos.poolId
            });
        }
        return PositionMeta({
            tickLower: pos.tickLower,
            tickUpper: pos.tickUpper,
            liquidity: int256(uint256(pos.liquidity)),
            owner: pos.owner,
            isActive: pos.isActive,
            poolId: pos.poolId
        });
    }

    function _touchPosition(
        VTSStorage storage s,
        IPoolManager poolManager,
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        address positionManager
    ) external returns (PositionId id) {
        id = PositionLibrary.generateId(owner, params);
        Position storage pos = s.positions[id];

        // pos.owner == address(0) means new position, so we have to use the owner parameter to check if the position is MM-managed
        bool isMMPosition = pos.owner == address(0) ? owner == positionManager : pos.owner == positionManager;

        uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(id));

        // Decode hookData to determine if seizing
        bool isSeizing = false;
        BalanceDelta seizureSettlementDelta = BalanceDelta.wrap(0);

        if (hookData.length > 0) {
            (bytes32 seizedPositionIdBytes, int128 settle0, int128 settle1) =
                abi.decode(hookData, (bytes32, int128, int128));
            PositionId seizedPositionId = PositionId.wrap(seizedPositionIdBytes);

            if (PositionId.unwrap(seizedPositionId) == PositionId.unwrap(id)) {
                isSeizing = true;
                seizureSettlementDelta = toBalanceDelta(settle0, settle1);
            }
        }

        if (pos.owner == address(0)) {
            // NEW POSITION: initialize the liquidity to the liquidity delta, assuming it will always be positive
            _registerPosition(s, owner, poolId, params);
            // TODO: come back to including snapshot logic
            // _initPositionSnapshots(id);
            VTSCommitLib._trackCommitment(s, id, params);

            // get the commitment maxima for the position
            TokenPairUint memory commitmentMaxima = s.positionAccounting[id].commitmentMax;

            if (isMMPosition) {
                // New positions mean base settlement.
                // If the modifyDelta is 0 AND the position is active (created), then default settlement to base amounts
                MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
                (uint256 amountToSettle0, uint256 amountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                    commitmentMaxima.token0,
                    commitmentMaxima.token1,
                    vtsConfiguration.token0.baseVTSRate,
                    vtsConfiguration.token1.baseVTSRate
                );
                // Set the settlement amounts to the total commitment amounts for DirectLPs.
                // ? No _updateSettlement calls inside of this function - as we're now using flash-ier accounting.
                // All MM settlements handled inside of onMMSettle.

                // Invert signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
                TransientSlots.addPositionRequiredSettlementDelta(
                    id, LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true)
                );
            } else {
                // Set the settlement amounts to the total commitment amounts for DirectLPs.
                // DirectLPs do not settle in underlying terms - as they are handled natively.
                VTSPoolAndPositionAccountingLib._updateSettlement(s, id, 0, SafeCast.toInt256(commitmentMaxima.token0));
                VTSPoolAndPositionAccountingLib._updateSettlement(s, id, 1, SafeCast.toInt256(commitmentMaxima.token1));
            }
        } else if (pos.isActive == true) {
            // EXISTING POSITION: update the liquidity by the liquidity delta
            if (params.liquidityDelta < 0) {
                // FULL or PARTIAL LIQUIDATION:

                // validate that RfS is closed before we track position param (commitment maxima) updates.
                // Skip calcRFS when seizing
                if (!isSeizing) {
                    _calcRFS(s, poolManager, id, true); // rfs is always closed for DirectLPs.
                }
                VTSCommitLib._trackCommitment(s, id, params);
                // active position is being liquidated.
                PositionAccounting storage pa = s.positionAccounting[id];
                uint256 s0 = pa.settled.token0;
                uint256 s1 = pa.settled.token1;
                uint256 excess0 = 0;
                uint256 excess1 = 0;
                if (liq == 0) {
                    // full liquidation
                    excess0 = s0;
                    excess1 = s1;
                } else {
                    // a partial liquidation results in removal of the settlements above the NEW commitment maxima.
                    TokenPairUint memory commitmentMaxima = pa.commitmentMax;
                    if (isSeizing) {
                        // Use seizure-specific excess calculation
                        (excess0, excess1) = LiquidityUtils.calculateSeizureExcess(
                            s0,
                            s1,
                            uint256(liq),
                            uint256(-params.liquidityDelta), // the amount to seize - determined in _calcSeizure
                            seizureSettlementDelta
                        );
                    } else {
                        // Standard excess calculation
                        if (s0 > commitmentMaxima.token0) {
                            excess0 = s0 - commitmentMaxima.token0;
                        }
                        if (s1 > commitmentMaxima.token1) {
                            excess1 = s1 - commitmentMaxima.token1;
                        }
                    }
                }
                console.log("excess0", excess0);
                console.log("excess1", excess1);
                console.log("isMMPosition", isMMPosition);
                console.logBytes32(PositionId.unwrap(id));
                // ? Only save the settlement delta for MMPs.
                if (isMMPosition) {
                    // this sets the required settlement because we changed the position.
                    // Invert signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
                    // if we do not do this, then the excess credits to go to the position instead of the address that seized the position
                    // since the address that siezed the position cannot be accessed here, then we cache to get it after modification of liquidity
                    if (isSeizing) {
                        TransientSlots.setSiezedSettlementDelta(
                            id, LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false)
                        );
                    } else {
                        TransientSlots.addPositionRequiredSettlementDelta(
                            id, LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false)
                        );
                    }
                } else {
                    // ? Update settlement for DirectLPs.
                    if (excess0 > 0) {
                        VTSPoolAndPositionAccountingLib._updateSettlement(s, id, 0, -SafeCast.toInt256(excess0));
                    }
                    if (excess1 > 0) {
                        VTSPoolAndPositionAccountingLib._updateSettlement(s, id, 1, -SafeCast.toInt256(excess1));
                    }
                }
            } else if (params.liquidityDelta > 0) {
                // POSITION DELTA INCREASE:

                VTSCommitLib._trackCommitment(s, id, params);

                PositionAccounting storage pa = s.positionAccounting[id];
                uint256 s0 = pa.settled.token0;
                uint256 s1 = pa.settled.token1;
                TokenPairUint memory commitmentMaxima = pa.commitmentMax;

                if (isMMPosition) {
                    // commitment maxima increases, and therefore base settlement requirements do too.
                    // Therefore, recalculate the base settlement requirements, and determine excess over s0,s1 to settle IN.
                    MarketVTSConfiguration memory vtsConfiguration = s.pools[poolId].vtsConfig;
                    (uint256 baseAmountToSettle0, uint256 baseAmountToSettle1) = LiquidityUtils.getBaseSettlementAmounts(
                        commitmentMaxima.token0,
                        commitmentMaxima.token1,
                        vtsConfiguration.token0.baseVTSRate,
                        vtsConfiguration.token1.baseVTSRate
                    );
                    uint256 excess0 = baseAmountToSettle0 > s0 ? baseAmountToSettle0 - s0 : 0;
                    uint256 excess1 = baseAmountToSettle1 > s1 ? baseAmountToSettle1 - s1 : 0;

                    // Instruct MMP to source underlying for the excess
                    // Invert signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
                    TransientSlots.addPositionRequiredSettlementDelta(
                        id, LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true)
                    );
                } else {
                    // Increase DirectLPs settlement amounts by the difference between the commitment maxima and the last settled amounts.
                    VTSPoolAndPositionAccountingLib._updateSettlement(
                        s, id, 0, SafeCast.toInt256(commitmentMaxima.token0) - SafeCast.toInt256(s0)
                    );
                    VTSPoolAndPositionAccountingLib._updateSettlement(
                        s, id, 1, SafeCast.toInt256(commitmentMaxima.token1) - SafeCast.toInt256(s1)
                    );
                }
            }

            // Update position liquidity
            int256 newLiquidity = SafeCast.toInt256(uint256(pos.liquidity)) + params.liquidityDelta;
            if (newLiquidity < 0) {
                // this should never happen in theory but check is performed to be safe since it is a uint256 and a position must not have a negative liquidity
                pos.liquidity = 0;
            } else {
                pos.liquidity = SafeCast.toUint128(uint256(newLiquidity));
            }
        } else {
            revert Errors.NotActive(id);
        }

        // Update active status based on liquidity
        if (liq == 0) {
            pos.isActive = false;
        } else {
            pos.isActive = true;
        }
    }

    function _calcRFS(VTSStorage storage s, IPoolManager poolManager, PositionId id, bool requireClosedRfS)
        public
        returns (bool, BalanceDelta)
    {
        VTSPoolAndPositionAccountingLib._settlePositionGrowths(s, poolManager, id);
        (bool rfsOpen, BalanceDelta delta) = VTSSettleLib._getRFS(s, id);
        if (requireClosedRfS && rfsOpen) {
            revert Errors.RFSOpenForPosition(id);
        }
        return (rfsOpen, delta);
    }
}
