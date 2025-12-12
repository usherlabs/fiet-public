// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

import {ImmutableVTSState} from "./ImmutableVTSState.sol";
import {ICheckpointEntrypoints} from "../interfaces/ICheckpointEntrypoints.sol";

/// @title CheckpointEntrypoints
/// @notice Abstract module providing checkpoint entrypoint functions
/// @dev Inherits ImmutableVTSState to access vtsOrchestrator for checkpoint operations
abstract contract CheckpointEntrypoints is ICheckpointEntrypoints, ImmutableVTSState {
    /// @notice Internal checkpoint function that can be overridden
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    /// @param liquiditySignal The liquidity signal to verify backing (empty if withCommitment is false)
    /// @param withCommitment Whether to run commitment backing checks
    function _checkpoint(
        address sender,
        uint256 tokenId,
        uint256 positionIndex,
        bytes memory liquiditySignal,
        bool withCommitment
    ) internal virtual;

    /// @notice Marks a checkpoint for a single position within a commitment
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    function checkpoint(uint256 tokenId, uint256 positionIndex) external {
        bytes memory emptySignal;
        _checkpoint(msg.sender, tokenId, positionIndex, emptySignal, false);
    }

    /// @notice Marks a checkpoint for a single position with commitment backing check
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    /// @param liquiditySignal The liquidity signal to verify backing
    function checkpoint(uint256 tokenId, uint256 positionIndex, bytes calldata liquiditySignal) external {
        _checkpoint(msg.sender, tokenId, positionIndex, bytes(liquiditySignal), true);
    }
}

