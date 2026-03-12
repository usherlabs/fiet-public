// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {VTSStorage, PositionAccounting} from "../types/VTS.sol";
import {Position, PositionId} from "../types/Position.sol";
import {MarketVTSConfiguration} from "../types/VTS.sol";
import {Commit} from "../types/Commit.sol";
import {Errors} from "./Errors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {TokenConfiguration} from "../types/VTS.sol";

library CheckpointLibrary {
    uint8 internal constant TOKEN0_OPEN_MASK = 1;
    uint8 internal constant TOKEN1_OPEN_MASK = 2;

    /**
     * @notice Retrieves the checkpoint for a given position
     * @dev Returns a storage reference to the checkpoint associated with the position ID
     * @param s The VTS storage struct
     * @param positionId The position ID to retrieve the checkpoint for
     * @return A storage reference to the RFSCheckpoint for the position
     */
    function getCheckpoint(VTSStorage storage s, PositionId positionId) internal view returns (RFSCheckpoint storage) {
        return s.positions[positionId].checkpoint;
    }

    /**
     * @notice Determines if a position is open for seizure
     * @dev Two paths to seizability:
     *      1. Deficit path: position-level commitment deficit > 0 bypasses grace when configured gates pass:
     *         - token-specific minimum deficit age is met, and
     *         - `commitmentDeficitBps >= unbackedCommitmentGraceBypassBps`, or
     *         - optional per-token thresholds (when set > 0) are breached
     *      2. Normal RFS path: checkpoint has open lane(s) AND lane-local grace period elapsed
     * @param s The VTS storage struct
     * @param commitId The token ID to check
     * @param positionIndex The position index to check
     * @param revertOnFalse Whether to revert if not seizable
     * @return canSeize true if the position can be seized, false otherwise
     */
    function isSeizable(VTSStorage storage s, uint256 commitId, uint256 positionIndex, bool revertOnFalse)
        internal
        view
        returns (bool canSeize)
    {
        Commit storage commit = s.commits[commitId];
        PositionId positionId = commit.positions[positionIndex];

        // Deficit path: immediately seizable if position-level commitment deficit exists
        // RfS amounts are inflated by these position-level commitment deficit amounts
        PositionAccounting storage pa = s.positionAccounting[positionId];
        if (pa.commitmentDeficit.token0 > 0 || pa.commitmentDeficit.token1 > 0) {
            Position memory deficitPosition = s.positions[positionId];
            MarketVTSConfiguration memory deficitCfg = s.pools[deficitPosition.poolId].vtsConfig;
            bool bpsBypass = pa.commitmentDeficitBps >= deficitCfg.unbackedCommitmentGraceBypassBps;

            uint256 token0BypassTime = deficitCfg.token0.unbackedCommitmentGraceBypassTime;
            uint256 token1BypassTime = deficitCfg.token1.unbackedCommitmentGraceBypassTime;
            // Hardening: a commitment deficit must persist for a minimum time before
            // it can bypass grace. This prevents a freshly-written checkpoint snapshot
            // from being used as an instant seize trigger if it was created during a
            // short-lived adverse price move.
            bool token0AgeMet = token0BypassTime == 0
                || (pa.commitmentDeficitSince.token0 > 0
                    && pa.commitmentDeficitSince.token0 <= block.timestamp
                    && (block.timestamp - pa.commitmentDeficitSince.token0) >= token0BypassTime);
            bool token1AgeMet = token1BypassTime == 0
                || (pa.commitmentDeficitSince.token1 > 0
                    && pa.commitmentDeficitSince.token1 <= block.timestamp
                    && (block.timestamp - pa.commitmentDeficitSince.token1) >= token1BypassTime);

            bool token0ThresholdTriggered = deficitCfg.token0.unbackedCommitmentGraceBypassThreshold > 0
                && pa.commitmentDeficit.token0 >= deficitCfg.token0.unbackedCommitmentGraceBypassThreshold;
            bool token1ThresholdTriggered = deficitCfg.token1.unbackedCommitmentGraceBypassThreshold > 0
                && pa.commitmentDeficit.token1 >= deficitCfg.token1.unbackedCommitmentGraceBypassThreshold;

            // A token can only bypass grace once it is both severe enough and old
            // enough. The shared bps threshold still captures overall under-backing
            // severity, while the token-local threshold handles large single-token
            // deficits without treating every fresh deficit as immediately seizable.
            bool token0Bypass =
                pa.commitmentDeficit.token0 > 0 && token0AgeMet && (bpsBypass || token0ThresholdTriggered);
            bool token1Bypass =
                pa.commitmentDeficit.token1 > 0 && token1AgeMet && (bpsBypass || token1ThresholdTriggered);
            if (token0Bypass || token1Bypass) {
                return true;
            }
        }

        // Normal RFS path: check checkpoint + grace period
        RFSCheckpoint memory checkpoint = getCheckpoint(s, positionId);

        if (checkpoint.openMask == 0) {
            if (revertOnFalse) {
                revert Errors.RFSNotOpenForPosition(positionId);
            }
            return false;
        }

        // Get position to access poolId
        Position memory position = s.positions[positionId];

        // Get VTS configuration from pool
        MarketVTSConfiguration memory vtsConf = s.pools[position.poolId].vtsConfig;

        uint256 totalGracePeriod0 = vtsConf.token0.gracePeriodTime + checkpoint.gracePeriodExtension0;
        uint256 totalGracePeriod1 = vtsConf.token1.gracePeriodTime + checkpoint.gracePeriodExtension1;

        bool token0Open = (checkpoint.openMask & TOKEN0_OPEN_MASK) != 0;
        bool token1Open = (checkpoint.openMask & TOKEN1_OPEN_MASK) != 0;
        bool gracePeriod0Elapsed = token0Open && checkpoint.openSince0 > 0 && checkpoint.openSince0 <= block.timestamp
            && (block.timestamp - checkpoint.openSince0) > totalGracePeriod0;
        bool gracePeriod1Elapsed = token1Open && checkpoint.openSince1 > 0 && checkpoint.openSince1 <= block.timestamp
            && (block.timestamp - checkpoint.openSince1) > totalGracePeriod1;

        canSeize = gracePeriod0Elapsed || gracePeriod1Elapsed;
        if (revertOnFalse && !canSeize) {
            revert Errors.GracePeriodNotElapsed(commitId, positionIndex, positionId, checkpoint);
        }
    }

    /**
     * @notice Extends the grace period for a position by providing a settlement proof
     * @dev This function allows market makers to extend their grace period by providing
     *      a valid settlement proof that gets verified against a Settlement Observer's verifier.
     * @dev "I have a token coming, it's just pending a bank transfer to the stablecoin issuer."
     * @dev IMPORTANT: Callers MUST validate that `positionId` belongs to `poolKey.toId()`.
     * @param positionId The position ID
     * @param settlementProof The settlement signal containing the proof
     */
    function extendGracePeriod(
        VTSStorage storage s,
        IVRLSettlementObserver settlementObserver,
        PoolKey memory poolKey,
        PositionId positionId,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal {
        if (settlementTokenIndex != 0 && settlementTokenIndex != 1) {
            revert Errors.InvalidTokenIndex(settlementTokenIndex);
        }
        MarketVTSConfiguration memory vtsConfiguration = s.pools[poolKey.toId()].vtsConfig;

        // verify the settlement proof and get the grace period extension
        settlementObserver.verifySettlementProof(poolKey, settlementTokenIndex, verifierIndex, settlementProof, true);

        // extend the grace period for the position
        TokenConfiguration memory tokenConfiguration =
            settlementTokenIndex == 0 ? vtsConfiguration.token0 : vtsConfiguration.token1;
        bool tokenLaneOpen = settlementTokenIndex == 0
            ? (s.positions[positionId].checkpoint.openMask & TOKEN0_OPEN_MASK) != 0
            : (s.positions[positionId].checkpoint.openMask & TOKEN1_OPEN_MASK) != 0;
        if (!tokenLaneOpen) {
            revert Errors.RFSNotOpenForPosition(positionId);
        }
        // extend the grace period for the position using the `CheckpointLibrary` type
        s.positions[positionId].checkpoint.extendGracePeriod(tokenConfiguration, settlementTokenIndex);
    }

    /**
     * @notice Marks a checkpoint as open or closed for a given position
     * @dev Updates the checkpoint state by calling the mark function on the checkpoint
     * @param s The VTS storage struct
     * @param positionId The position ID to mark the checkpoint for
     * @param openMask Open lane mask (bit0=token0, bit1=token1)
     */
    function markCheckpoint(VTSStorage storage s, PositionId positionId, uint8 openMask) internal {
        s.positions[positionId].checkpoint.mark(openMask);
    }
}
