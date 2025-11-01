// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title ICommitmentDescriptor
 * @notice Interface for generating token URIs for commitment NFTs
 */
interface ICommitmentDescriptor {
    /**
     * @notice Generates a token URI for a commitment NFT
     * @param manager The address of the MMPositionManager contract
     * @param tokenId The token ID of the commitment NFT
     * @return The token URI as a data URI containing JSON metadata
     */
    function tokenURI(address manager, uint256 tokenId) external view returns (string memory);
}

