// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.0;

/// @title ICheckpointEntrypoints
/// @notice Interface for checkpoint entrypoint functions
interface ICheckpointEntrypoints {
    /// @notice Marks a checkpoint for a single position within a commitment
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    function checkpoint(uint256 tokenId, uint256 positionIndex) external;

    /// @notice Marks a checkpoint for a single position with commitment backing check
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    /// @param liquiditySignal The liquidity signal to verify backing (required if withCommitment)
    function checkpoint(uint256 tokenId, uint256 positionIndex, bytes calldata liquiditySignal) external;
}

