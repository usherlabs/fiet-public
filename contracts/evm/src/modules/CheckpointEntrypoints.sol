// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionId} from "../types/Position.sol";
import {ImmutableVTSState} from "./ImmutableVTSState.sol";

/// @title CheckpointEntrypoints
/// @notice Abstract module providing checkpoint entrypoint functions
/// @dev Inherits ImmutableVTSState to access vtsOrchestrator for checkpoint operations
abstract contract CheckpointEntrypoints is ImmutableVTSState {
    /// @notice Marks a checkpoint for a single position within a commitment
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    function checkpoint(uint256 tokenId, uint256 positionIndex) public {
        (PositionId positionId, bool rfsOpen,) = vtsOrchestrator.calcRFS(tokenId, positionIndex, false);
        vtsOrchestrator.markCheckpoint(positionId, rfsOpen);
    }

    /// @notice Marks checkpoints for multiple (tokenId, positionIndex) pairs
    /// @param tokenIds Array of commitment NFT ids
    /// @param positionIndexes Array of position indexes within each commitment
    function checkpoint(uint256[] calldata tokenIds, uint256[] calldata positionIndexes) public {
        require(tokenIds.length == positionIndexes.length, "Invalid input lengths");
        for (uint256 i = 0; i < tokenIds.length; i++) {
            checkpoint(tokenIds[i], positionIndexes[i]);
        }
    }

    /// @notice Marks checkpoints for all positions within a single commitment
    /// @param tokenId The ERC721 token id (commitment NFT id)
    function checkpoint(uint256 tokenId) public {
        (,, uint256 positionCount,) = vtsOrchestrator.getCommit(tokenId);
        for (uint256 i = 0; i < positionCount; i++) {
            checkpoint(tokenId, i);
        }
    }

    /// @notice Marks checkpoints for all positions across multiple commitments
    /// @param tokenIds Array of commitment NFT ids
    function checkpoint(uint256[] calldata tokenIds) public {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            checkpoint(tokenIds[i]);
        }
    }
}

