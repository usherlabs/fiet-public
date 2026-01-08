// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/**
 * @title ICommitmentDescriptor
 * @notice Interface for generating token URIs for commitment NFTs
 */
interface ICommitmentDescriptor {
    /**
     * @notice Generates a token URI for a commitment NFT
     * @param tokenId The token ID of the commitment NFT
     * @return The token URI as a data URI containing JSON metadata
     */
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

