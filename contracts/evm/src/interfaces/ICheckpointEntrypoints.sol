// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title ICheckpointEntrypoints
/// @notice Interface for checkpoint entrypoint functions
interface ICheckpointEntrypoints {
    /// @notice Marks a checkpoint for a single position within a commitment
    /// @param tokenId The ERC721 token id (commitment NFT id)
    /// @param positionIndex The index of the position within the commitment
    function checkpoint(uint256 tokenId, uint256 positionIndex) external;

    /// @notice Marks checkpoints for multiple (tokenId, positionIndex) pairs
    /// @param tokenIds Array of commitment NFT ids
    /// @param positionIndexes Array of position indexes within each commitment
    function checkpoint(uint256[] calldata tokenIds, uint256[] calldata positionIndexes) external;

    /// @notice Marks checkpoints for all positions within a single commitment
    /// @param tokenId The ERC721 token id (commitment NFT id)
    function checkpoint(uint256 tokenId) external;

    /// @notice Marks checkpoints for all positions across multiple commitments
    /// @param tokenIds Array of commitment NFT ids
    function checkpoint(uint256[] calldata tokenIds) external;
}

