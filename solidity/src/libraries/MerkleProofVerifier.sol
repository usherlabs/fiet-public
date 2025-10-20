// SPDX-License-Identifier: MIT

import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

pragma solidity ^0.8.20;

/// @title MerkleProofVerifier
/// @notice Library for verifying and generating Merkle proofs

library MerkleProofVerifier {
    /**
     * @notice Verifies a Merkle proof for a given leaf in a Merkle tree
     * @param proof The Merkle proof of inclusion for the leaf node provided to verify
     * @param root The root hash of the Merkle tree
     * @param leaf The leaf hash to verify inclusion of
     * @return True if the proof is valid, false otherwise
     */
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        // return processProof(proof, leaf) == root;
        return MerkleProofLib.verify(proof, root, leaf);
    }

}
