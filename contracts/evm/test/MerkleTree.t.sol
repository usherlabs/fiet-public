// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {MerkleProofGenerator} from "./libraries/MerkleProofGenerator.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";

contract MerkleTreeTest is Test {
    // Helper function to hash a string to bytes32 for testing
    function hash(string memory input) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(input));
    }

    function testKeccak256OfOne() public pure {
        // keccak256(abi.encodePacked(uint256(1)))
        bytes32 hashValue = keccak256(abi.encodePacked(uint256(0)));

        // Expected hash value (checked via Rust + Solidity)
        bytes32 expected = 0x290decd9548b62a8d60345a988386fc84ba6bc95484008f6362f93160ef3e563;

        assertEq(hashValue, expected, "Hash of uint256(1) does not match expected value");
    }

    // Test verify and processProof with a valid proof
    function testVerifyValidProof() public pure {
        // Create leaves
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = hash(
            "{\"owner\":\"0x14791697260E4c9A71f18484C9f997B308e59325\",\"reserves\":{\"BTC\":0.0,\"ETH\":0.0,\"USDT\":0.00058569},\"source_state\":\"0x720b290771a46aec744e2d91e51b3ba71e9bbe72b82f25289ef324e3207faa5f\",\"prover\":\"0x638a1a9699319025401c605f31464cebc63a03f5\",\"nonce\":\"eda6893606a4b7672b67e5141a7abf1b962f554782e8fcd795887cc0b8f86245\"}"
        );
        leaves[1] = hash(
            "{\"owner\":\"0x0ad2084da15a4ac5aab3354def099cbcf9660042\",\"reserves\":{\"USDC\":0.9872,\"USDT\":0.0},\"source_state\":\"0x7a03d4963b0eae9ac248481b3d6282b6ee9b8a1a426210776d41435c90af5044\",\"prover\":\"0x638a1a9699319025401c605f31464cebc63a03f5\",\"nonce\":\"d125adc986b7f6c50ed9f96b6686a62ccc8866f2474b16d436f18a9ac94ac0c3\"}"
        );
        leaves[2] = hash(
            "{\"owner\":\"0x25447a79bc035b60edb8dabc1794f2d87749b397\",\"reserves\":{\"USDC\":0.9872,\"USDT\":0.0},\"source_state\":\"0x8133304d57bfc0aebe75a213a97f3018888faa6c5ed573a3e61a56cb308fdb78\",\"prover\":\"0x638a1a9699319025401c605f31464cebc63a03f5\",\"nonce\":\"4810ee0363d835b3f5d399658c8c161ede1b3335ac3412d0ae2ff15a79d28e4e\"}"
        );

        // Generate Merkle root
        bytes32 root = MerkleProofGenerator.generateMerkleRoot(leaves);

        bytes32 root2 = 0xf144e697f656497ca3486cdec50221904bbcc133cbdd8932ad73fdc9b4939938;

        assertEq(root, root2, "Check if the root generated match");

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
