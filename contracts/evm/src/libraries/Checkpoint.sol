// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {RFSCheckpoint} from "../types/Checkpoint.sol";
import {VTSStorage} from "../types/VTS.sol";
import {Position, PositionId} from "../types/Position.sol";
import {MarketVTSConfiguration, VTSStorage} from "../types/VTS.sol";
import {Errors} from "./Errors.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IVRLSettlementObserver} from "../interfaces/IVRLSettlementObserver.sol";
import {TokenConfiguration} from "../types/VTS.sol";
import {console} from "forge-std/console.sol";

library CheckpointLibrary {
    event Checkpointed(uint256 tokenId, uint256 positionIndex, RFSCheckpoint checkpoint);
    event GracePeriodExtended(uint256 tokenId, uint256 positionIndex, uint8 tokenIndex, RFSCheckpoint checkpoint);

    function getPositionCheckpoint(VTSStorage storage s, PositionId positionId)
        internal
        view
        returns (RFSCheckpoint storage)
    {
        return s.checkpoints[PositionId.unwrap(positionId)];
    }

    function getCommitCheckpoint(VTSStorage storage s, uint256 tokenId) internal view returns (RFSCheckpoint storage) {
        return s.checkpoints[keccak256(abi.encodePacked(tokenId))];
    }

    /**
     * @notice Determines if a position is open for seizure by checking if the grace period has elapsed
     * @dev Returns true if timeSinceLastCheckpoint > (gracePeriodTime + extension) for either token
     * @param s The VTS storage struct
     * @param tokenId The token ID to check
     * @param positionIndex The position index to check
     * @return true if the position can be seized (grace period elapsed for either token), false otherwise
     */
    function isSeizable(VTSStorage storage s, uint256 tokenId, uint256 positionIndex, bool revertOnFalse)
        internal
        view
        returns (bool)
    {
        // Get checkpoint from storage using PositionId as key
        PositionId positionId = s.commits[tokenId].positions[positionIndex];
        RFSCheckpoint memory checkpoint = getPositionCheckpoint(s, positionId);

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
        MarketVTSConfiguration memory vtsConfiguration = s.pools[position.poolId].vtsConfig;

        uint256 timeSinceLastCheckpoint = block.timestamp - checkpoint.timeOfLastTransition;

        uint256 totalGracePeriod0 = vtsConfiguration.token0.gracePeriodTime + checkpoint.gracePeriodExtension0;
        uint256 totalGracePeriod1 = vtsConfiguration.token1.gracePeriodTime + checkpoint.gracePeriodExtension1;

        bool gracePeriod0Elapsed = timeSinceLastCheckpoint > totalGracePeriod0;
        bool gracePeriod1Elapsed = timeSinceLastCheckpoint > totalGracePeriod1;

        bool canSeize = gracePeriod0Elapsed || gracePeriod1Elapsed;
        if (revertOnFalse && !canSeize) {
            revert Errors.GracePeriodNotElapsed(tokenId, positionIndex, positionId, checkpoint);
        }
        return canSeize;
    }

    /**
     * @notice Extends the grace period for a position by providing a settlement proof
     * @dev This function allows market makers to extend their grace period by providing
     *      a valid settlement proof that gets verified against a Settlement Observer's verifier.
     * @dev "I have a token coming, it's just pending a bank transfer to the stablecoin issuer."
     * @param tokenId The token id of the position
     * @param positionIndex The position index
     * @param settlementProof The settlement signal containing the proof
     */
    function extendGracePeriod(
        VTSStorage storage s,
        IVRLSettlementObserver settlementObserver,
        PoolKey memory poolKey,
        uint256 tokenId,
        uint256 positionIndex,
        uint8 settlementTokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof
    ) internal {
        require(settlementTokenIndex == 0 || settlementTokenIndex == 1, Errors.InvalidTokenIndex(settlementTokenIndex));
        MarketVTSConfiguration memory vtsConfiguration = s.pools[poolKey.toId()].vtsConfig;

        PositionId positionId = s.commits[tokenId].positions[positionIndex];

        // verify the settlement proof and get the grace period extension
        settlementObserver.verifySettlementProof(poolKey, settlementTokenIndex, verifierIndex, settlementProof, true);

        // extend the grace period for the position
        TokenConfiguration memory tokenConfiguration =
            settlementTokenIndex == 0 ? vtsConfiguration.token0 : vtsConfiguration.token1;
        // extend the grace period for the position using the `CheckpointLibrary` type
        s.checkpoints[PositionId.unwrap(positionId)].extendGracePeriod(tokenConfiguration, settlementTokenIndex);

        // emit an event to notify the market maker that the grace period has been extended
        emit GracePeriodExtended(
            tokenId, positionIndex, settlementTokenIndex, s.checkpoints[PositionId.unwrap(positionId)]
        );
    }

    function _markCheckpoint(VTSStorage storage s, PositionId positionId, bool isOpen) internal {
        s.checkpoints[PositionId.unwrap(positionId)].mark(isOpen);
    }

    function _forceOpenAndElapse(VTSStorage storage s, uint256 tokenId, uint256 positionIndex) internal {
        PositionId positionId = s.commits[tokenId].positions[positionIndex];

        // Backdate by the larger of the two token max grace windows plus 1 second
        MarketVTSConfiguration memory vtsConfiguration = s.pools[s.positions[positionId].poolId].vtsConfig;
        uint256 max0 = vtsConfiguration.token0.maxGracePeriodTime;
        uint256 max1 = vtsConfiguration.token1.maxGracePeriodTime;
        uint256 backdate = max0 > max1 ? max0 : max1;
        unchecked {
            backdate = backdate + 1;
        }
        // update the checkpoint to open and elapse the grace period
        s.checkpoints[PositionId.unwrap(positionId)].forceOpenAndElapse(backdate);
        emit Checkpointed(tokenId, positionIndex, s.checkpoints[PositionId.unwrap(positionId)]);
    }
}
