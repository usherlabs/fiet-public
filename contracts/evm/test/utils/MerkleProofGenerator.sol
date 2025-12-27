// SPDX-License-Identifier: BUSL-1.1

import {MerkleTreeLib} from "solady/utils/MerkleTreeLib.sol";

pragma solidity ^0.8.26;

/// @title MerkleTree
/// @notice Library for verifying and generating Merkle proofs
/// @dev Implements a positional Merkle tree (left/right order preserved, no sorting)
/// @dev Includes proof generation (intended for testing, gas-expensive on-chain)

library MerkleProofGenerator {
    /**
     * @notice Generates a Merkle root from a list of leaves
     * @dev This is primarily used in testing to verify correctness
     * @param leaves The list of leaves to generate a Merkle root from
     * @return The Merkle root
     */
    function generateMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        bytes32 root = MerkleTreeLib.root(tree);

        return root;
    }

    /**
     * @notice Generates a Merkle root from a list of leaves
     * @dev This is primarily used in testing to verify correctness
     * @param leaves The list of leaves to generate a Merkle root from
     * @return proof The Merkle proof (sibling hashes along the path to the root)
     */
    function generateProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory tree = MerkleTreeLib.build(leaves);
        proof = MerkleTreeLib.leafProof(tree, index);
    }
}
