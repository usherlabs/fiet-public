// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;
/// @title ShaMerkle
/// @notice Library for verifying Merkle proofs using SHA256
/// @dev This library provides a function to verify Merkle proofs using SHA256
/// @dev The library is used to verify the Merkle proofs in the ICSpokeVerifier contract

library ShaMerkle {
    /**
     * @notice Verifies a Merkle proof for a given leaf in a Merkle tree
     * @param proof The Merkle proof of inclusion for the leaf node provided to verify
     * @param root The root hash of the Merkle tree
     * @param leaf The leaf hash to verify inclusion of
     * @return True if the proof is valid, false otherwise
     */
    function verify(bytes32[] calldata proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /**
     * @notice Processes a Merkle inclusion proof along with a leaf node to compute the root hash
     * @param proof The Merkle proof of inclusion for the leaf node provided to verify
     * @param leaf The leaf hash to verify inclusion of
     * @return The computed root hash
     */
    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        bytes32 computedHash = leaf;
        for (uint256 i = 0; i < proof.length; i++) {
            bytes32 proofElement = proof[i];
            if (computedHash < proofElement) {
                computedHash = sha256(abi.encodePacked(computedHash, proofElement));
            } else {
                computedHash = sha256(abi.encodePacked(proofElement, computedHash));
            }
        }
        return computedHash;
    }

    /**
     * @notice Verifies a Merkle proof for a given leaf in a Merkle tree
     * @param proof The Merkle proof of inclusion for the leaf node provided to verify
     * @param merkle_root The root hash of the Merkle tree
     * @param leaf The leaf hash to verify inclusion of
     * @return True if the proof is valid, false otherwise
     */
    function verifyMerkleTreeInclusion(bytes32[] memory proof, bytes32 merkle_root, bytes32 leaf)
        internal
        pure
        returns (bool)
    {
        return processProof(proof, leaf) == merkle_root;
    }
}
