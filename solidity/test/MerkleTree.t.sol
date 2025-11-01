// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MerkleProofGenerator} from "./libraries/MerkleProofGenerator.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

contract MerkleTreeTest is Test {
    // Helper function to hash a string to bytes32 for testing
    function hash(string memory input) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(input));
    }

    // Test verify and processProof with a valid proof
    function testVerifyValidProof() public pure {
        // Create leaves
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = hash("leaf1");
        leaves[1] = hash("leaf2");
        leaves[2] = hash("leaf3");
        leaves[3] = hash("leaf4");

        // Generate Merkle root
        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);

        // Generate proof for leaf at index 1
        bytes32[] memory proof = MerkleProofGenerator.generateProof(leaves, 1);

        // Verify proof
        bool isValid = MerkleProofLib.verify(proof, root, leaves[1]);
        assertTrue(isValid);
    }

    // Test verify with an invalid proof
    function testVerifyInvalidProof() public pure {
        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = hash("leaf1");
        leaves[1] = hash("leaf2");
        leaves[2] = hash("leaf3");
        leaves[3] = hash("leaf4");

        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);
        bytes32[] memory proof = MerkleProofGenerator.generateProof(leaves, 1);

        // Use wrong leaf
        bool isValid = MerkleProofLib.verify(proof, root, hash("wrong_leaf"));
        assertFalse(isValid);
    }

    // Test generateMerkleRoot with a single leaf
    function testGenerateMerkleRootSingleLeaf() public pure {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = hash("leaf1");

        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);
        assertEq(root, leaves[0]);
    }

    // Test generateMerkleRoot with multiple leaves
    function testGenerateMerkleRootMultipleLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = hash("leaf1");
        leaves[1] = hash("leaf2");
        leaves[2] = hash("leaf3");

        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);

        // Verify that proof generation and verification works correctly
        bytes32[] memory proof = MerkleProofGenerator.generateProof(leaves, 0);
        bool isValid = MerkleProofLib.verify(proof, root, leaves[0]);
        assertTrue(isValid);
    }

    // Test generateProof and verify for an odd number of leaves
    function testGenerateProofOddLeaves() public pure {
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = hash("leaf1");
        leaves[1] = hash("leaf2");
        leaves[2] = hash("leaf3");

        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);
        bytes32[] memory proof = MerkleProofGenerator.generateProof(leaves, 2); // Last leaf

        bool isValid = MerkleProofLib.verify(proof, root, leaves[2]);
        assertTrue(isValid);
    }

    // Test generating and verifying a proof for the 7th leaf in a 10-leaf tree
    function testGenerateAndVerifyProofForTenthLeaf() public pure {
        // Create 10 leaves
        bytes32[] memory leaves = new bytes32[](10);
        leaves[0] = hash("leaf1");
        leaves[1] = hash("leaf2");
        leaves[2] = hash("leaf3");
        leaves[3] = hash("leaf4");
        leaves[4] = hash("leaf5");
        leaves[5] = hash("leaf6");
        leaves[6] = hash("leaf7");
        leaves[7] = hash("leaf8");
        leaves[8] = hash("leaf9");
        leaves[9] = hash("leaf10");

        // Generate Merkle root
        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);

        // Generate proof for the 7th leaf (index 6)
        bytes32[] memory proof = MerkleProofGenerator.generateProof(leaves, 6);

        // Verify proof
        bool isValid = MerkleProofLib.verify(proof, root, leaves[6]);
        assertTrue(isValid);
    }
}
