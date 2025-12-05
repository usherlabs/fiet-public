// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {
    PositionId,
    PositionModificationHookData,
    PositionModificationHookDataLib,
    SeizureData
} from "../types/Position.sol";
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
    ) external {
        // validate there is an existing commit for the token id
        if (s.commits[tokenId].expiresAt < block.timestamp) {
            revert Errors.SignalExpired(tokenId);
        }

        // Get current position count to use as index for the new position
        uint256 currentPositionCount = s.commits[tokenId].positionCount;

        // modify the commit to include the position and update the position count
        s.commits[tokenId].positions[currentPositionCount] = positionId;
        s.commits[tokenId].positionCount++;

        // update the commitId of the position i.e associate the position with the commit
        // as specified in `MMPositionsLib._createPosition L67`
        s.positions[positionId].commitId = tokenId;
    }

    /// @notice Touch a position to update its state and calculate required settlement delta
    /// @dev Returns the settlement delta directly instead of using transient storage for same-call-scope efficiency
    /// @param s The VTS storage
    /// @param poolManager The pool manager
    /// @param owner The owner of the position
    /// @param poolId The pool id
    /// @param params The modify liquidity params
    /// @param hookData The hook data containing PositionModificationHookData
    /// @param positionManager The MM position manager address
    /// @return id The position id
    /// @return requiredSettlementDelta The required settlement delta (returned directly, not via transient storage)
    /// @return isSeizing Whether this is a seizure operation
    function _touchPosition(
        VTSStorage storage s,
        IPoolManager poolManager,
        address owner,
        PoolId poolId,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData,
        address positionManager
    ) external returns (PositionId id, BalanceDelta requiredSettlementDelta, bool isSeizing) {
        id = PositionLibrary.generateId(owner, params);
        Position storage pos = s.positions[id];

        // pos.owner == address(0) means new position, so we have to use the owner parameter to check if the position is MM-managed
        bool isMMPosition = pos.owner == address(0) ? owner == positionManager : pos.owner == positionManager;

        uint128 liq = poolManager.getPositionLiquidity(poolId, PositionId.unwrap(id));

        // Decode hookData using the new PositionModificationHookData struct
        BalanceDelta seizureSettlementDelta = BalanceDelta.wrap(0);
        PositionModificationHookData memory mmData = PositionModificationHookDataLib.decodeCalldata(hookData);

        if (mmData.seizure.isSeizing) {
            isSeizing = true;
            seizureSettlementDelta = toBalanceDelta(mmData.seizure.settle0, mmData.seizure.settle1);
        }

        // Initialize requiredSettlementDelta to zero
        requiredSettlementDelta = BalanceDelta.wrap(0);

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
                // Return settlement delta directly instead of writing to transient storage
                // Invert signs: negative delta = caller owes liquidity (deposit), positive = protocol owes (withdrawal)
                requiredSettlementDelta =
                    LiquidityUtils.safeToBalanceDelta(amountToSettle0, amountToSettle1, true, true);
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
                // ? Only save the settlement delta for MMPs - return directly instead of transient storage
                if (isMMPosition) {
                    // Return settlement delta directly
                    // Positive delta = protocol owes (withdrawal)
                    requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, false, false);
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

                    // Return settlement delta directly instead of transient storage
                    // Negative delta = caller owes liquidity (deposit)
                    requiredSettlementDelta = LiquidityUtils.safeToBalanceDelta(excess0, excess1, true, true);
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
