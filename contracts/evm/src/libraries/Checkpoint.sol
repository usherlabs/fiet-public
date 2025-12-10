// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {VTSStorage} from "../types/VTS.sol";
import {Position, PositionId} from "../types/Position.sol";
import {MarketVTSConfiguration, VTSStorage} from "../types/VTS.sol";
import {Commit} from "../types/Commit.sol";
import {Errors} from "./Errors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {TokenConfiguration} from "../types/VTS.sol";
import {console} from "forge-std/console.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

library CheckpointLibrary {
    /**
     * @notice Determines if a position is open for seizure
     * @dev Two paths to seizability:
     *      1. Deficit path: deficitBps > 0 means immediately seizable (no grace period check)
     *      2. Normal RFS path: checkpoint isOpen AND grace period elapsed
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

        // Deficit path: immediately seizable if deficitBps > 0
        // TODO: Update to use postion-derived deficit - coverage > 0 as a boolean flag.
        if (commit.deficitBps > 0) {
            return true;
        }

        // Normal RFS path: check checkpoint + grace period
        PositionId positionId = commit.positions[positionIndex];
        RFSCheckpoint memory checkpoint = s.positions[positionId].checkpoint;

        console.log("checkpoint.isOpen", checkpoint.isOpen);
        console.log("revertOnFalse", revertOnFalse);
        console.log("checkpoint.timeOfLastTransition", checkpoint.timeOfLastTransition);
        console.log("checkpoint.gracePeriodExtension0", checkpoint.gracePeriodExtension0);
        console.log("checkpoint.gracePeriodExtension1", checkpoint.gracePeriodExtension1);

        if (!checkpoint.isOpen) {
            if (revertOnFalse) {
                revert Errors.RFSNotOpenForPosition(positionId);
            }
            return false;
        }

        // Get position to access poolId
        Position memory position = s.positions[positionId];

        // Get VTS configuration from pool
        MarketVTSConfiguration memory vtsConf = s.pools[position.poolId].vtsConfig;

        uint256 timeSinceLastCheckpoint = block.timestamp - checkpoint.timeOfLastTransition;

        uint256 totalGracePeriod0 = vtsConf.token0.gracePeriodTime + checkpoint.gracePeriodExtension0;
        uint256 totalGracePeriod1 = vtsConf.token1.gracePeriodTime + checkpoint.gracePeriodExtension1;

        bool gracePeriod0Elapsed = timeSinceLastCheckpoint > totalGracePeriod0;
        bool gracePeriod1Elapsed = timeSinceLastCheckpoint > totalGracePeriod1;

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
     * @param commitId The token id of the position
     * @param positionIndex The position index
     * @param settlementProof The settlement signal containing the proof
     */
    function extendGracePeriod(
        VTSStorage storage s,
        IVRLSettlementObserver settlementObserver,
        PoolKey memory poolKey,
        uint256 commitId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal {
        require(settlementTokenIndex == 0 || settlementTokenIndex == 1, Errors.InvalidTokenIndex(settlementTokenIndex));
        MarketVTSConfiguration memory vtsConfiguration = s.pools[poolKey.toId()].vtsConfig;

        PositionId positionId = s.commits[commitId].positions[positionIndex];

        // verify the settlement proof and get the grace period extension
        settlementObserver.verifySettlementProof(poolKey, settlementTokenIndex, verifierIndex, settlementProof, true);

        // extend the grace period for the position
        TokenConfiguration memory tokenConfiguration =
            settlementTokenIndex == 0 ? vtsConfiguration.token0 : vtsConfiguration.token1;
        // extend the grace period for the position using the `CheckpointLibrary` type
        s.positions[positionId].checkpoint.extendGracePeriod(tokenConfiguration, settlementTokenIndex);
    }

    /**
     * @notice Marks a checkpoint as open or closed for a given position
     * @dev Updates the checkpoint state by calling the mark function on the checkpoint
     * @param s The VTS storage struct
     * @param positionId The position ID to mark the checkpoint for
     * @param isOpen Whether the checkpoint should be marked as open (true) or closed (false)
     */
    function markCheckpoint(VTSStorage storage s, PositionId positionId, bool isOpen) internal {
        s.positions[positionId].checkpoint.mark(isOpen);
    }
}
