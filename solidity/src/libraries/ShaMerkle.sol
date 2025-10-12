// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @title ShaMerkle
/// @notice Library for verifying and generating Merkle proofs using SHA256
/// @dev Implements a positional Merkle tree (left/right order preserved, no sorting)
/// @dev Includes proof generation (intended for testing, gas-expensive on-chain)

library ShaMerkle {
    /**
     * @notice Verifies a Merkle proof for a given leaf in a Merkle tree
     * @param proof The Merkle proof of inclusion for the leaf node provided to verify
     * @param root The root hash of the Merkle tree
     * @param leaf The leaf hash to verify inclusion of
     * @return True if the proof is valid, false otherwise
     */
    function verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) internal pure returns (bool) {
        return processProof(proof, leaf) == root;
    }

    /**
     * @notice Processes a Merkle inclusion proof along with a leaf node to compute the root hash
     * @param proof The Merkle proof of inclusion for the leaf node provided to verify
     * @param leaf The leaf hash to verify inclusion of
     * @return The computed root hash
     */
    function processProof(bytes32[] memory proof, bytes32 leaf) internal pure returns (bytes32) {
        if (proof.length == 0) {
            return leaf;
        }

        if (proof.length < 2) {
            return bytes32(0); // invalid
        }

        uint256 index = uint256(proof[0]);
        uint256 leafCount = uint256(proof[1]);

        if (leafCount == 0 || index >= leafCount) {
            return bytes32(0); // invalid
        }

        bytes32 computedHash = leaf;
        uint256 proofIndex = 2;
        uint256 currentIndex = index;
        uint256 currentLength = leafCount;

        while (currentLength > 1) {
            if (currentIndex % 2 == 0) {
                // Potential left or solo
                if (currentIndex + 1 < currentLength) {
                    // Has right sibling
                    if (proofIndex >= proof.length) {
                        return bytes32(0); // invalid
                    }
                    bytes32 proofElement = proof[proofIndex++];
                    computedHash = sha256(abi.encodePacked(computedHash, proofElement));
                } else {
                    // Solo
                    computedHash = sha256(abi.encodePacked(computedHash, computedHash));
                }
            } else {
                // Right, has left sibling
                if (proofIndex >= proof.length) {
                    return bytes32(0); // invalid
                }
                bytes32 proofElement = proof[proofIndex++];
                computedHash = sha256(abi.encodePacked(proofElement, computedHash));
            }

            currentIndex /= 2;
            currentLength = (currentLength + 1) / 2;
        }

        if (proofIndex != proof.length) {
            return bytes32(0); // invalid, extra elements
        }

        return computedHash;
    }

    /**
     * @notice Generates a Merkle root from a list of leaves
     * @dev This is primarily used in testing to verify correctness
     * @param leaves The list of leaves to generate a Merkle root from
     * @return The Merkle root
     */
    function generateMerkleRoot(bytes32[] memory leaves) internal pure returns (bytes32) {
        if (leaves.length == 0) {
            revert("Empty leaves array");
        }

        if (leaves.length == 1) {
            // Return leaf directly if only one element
            return leaves[0];
        }

        // For multiple leaves, build the Merkle tree
        bytes32[] memory currentLevel = leaves;

        while (currentLevel.length > 1) {
            uint256 nextLevelSize = (currentLevel.length + 1) / 2;
            bytes32[] memory nextLevel = new bytes32[](nextLevelSize);

            for (uint256 i = 0; i < currentLevel.length; i += 2) {
                if (i + 1 < currentLevel.length) {
                    // Two elements exist, hash them together
                    nextLevel[i / 2] = sha256(abi.encodePacked(currentLevel[i], currentLevel[i + 1]));
                } else {
                    // Only one element left, hash it with itself
                    nextLevel[i / 2] = sha256(abi.encodePacked(currentLevel[i], currentLevel[i]));
                }
            }

            currentLevel = nextLevel;
        }

        return currentLevel[0];
    }

    /**
     * @notice Generates a Merkle root from a list of leaves
     * @dev This is primarily used in testing to verify correctness
     * @param leaves The list of leaves to generate a Merkle root from
     * @return proof The Merkle proof (sibling hashes along the path to the root)
     */
    function generateProof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory proof) {
        if (leaves.length == 0) {
            revert("Empty leaves array");
        }

        if (index >= leaves.length) {
            revert("Invalid leaf index");
        }

        // Calculate max possible proof length (height)
        uint256 maxProofLength = 0;
        uint256 tempLength = leaves.length;
        while (tempLength > 1) {
            maxProofLength++;
            tempLength = (tempLength + 1) / 2;
        }

        // Temporary array to collect siblings
        bytes32[] memory tempProof = new bytes32[](maxProofLength);
        uint256 proofIndex = 0;

        bytes32[] memory currentLevel = leaves;
        uint256 currentIndex = index;

        while (currentLevel.length > 1) {
            uint256 nextLevelSize = (currentLevel.length + 1) / 2;
            bytes32[] memory nextLevel = new bytes32[](nextLevelSize);

            for (uint256 i = 0; i < currentLevel.length; i += 2) {
                uint256 parentIndex = i / 2;

                if (i + 1 < currentLevel.length) {
                    // Two elements exist
                    bytes32 left = currentLevel[i];
                    bytes32 right = currentLevel[i + 1];
                    nextLevel[parentIndex] = sha256(abi.encodePacked(left, right));

                    // Check if currentIndex is in this pair
                    if (i == currentIndex) {
                        // Current index is left, sibling is right
                        tempProof[proofIndex++] = right;
                        currentIndex = parentIndex;
                    } else if (i + 1 == currentIndex) {
                        // Current index is right, sibling is left
                        tempProof[proofIndex++] = left;
                        currentIndex = parentIndex;
                    }
                } else {
                    // Only one element left
                    bytes32 solo = currentLevel[i];
                    nextLevel[parentIndex] = sha256(abi.encodePacked(solo, solo));

                    if (i == currentIndex) {
                        // Current index is the solo element, no sibling to add
                        currentIndex = parentIndex;
                    }
                }
            }

            currentLevel = nextLevel;
        }

        // Create final proof with index, leaf count, and siblings
        proof = new bytes32[](proofIndex + 2);
        proof[0] = bytes32(index);
        proof[1] = bytes32(leaves.length);
        for (uint256 i = 0; i < proofIndex; i++) {
            proof[i + 2] = tempProof[i];
        }

        return proof;
    }
}
