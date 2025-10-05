// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
import {ICSpokeVerifier} from "../src/modules/ICSpokeVerifier.sol";
import {Test} from "forge-std/Test.sol";
import {ShaMerkle} from "../src/libraries/ShaMerkle.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";

contract MarketMakerTest is MarketMakerTestBase, Test {
    using MarketMaker for MarketMaker.State;
    using ShaMerkle for bytes32[];

    ICSpokeVerifier icVerifier;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        icVerifier = new ICSpokeVerifier(makeAddr("icCanister"));
    }

    /// Test the to_string function against a string generated using the rust code
    ///
    /// Rust implementation for reference:
    /// ```rust
    /// impl ToString for MMState {
    ///     /// Converts reserves + metadata into a deterministic string.
    ///     fn to_string(&self) -> String {
    ///         let mut parts = Vec::new();
    ///
    ///         for (source, assets) in &self.reserves {
    ///             for (asset, amount) in assets {
    ///                 parts.push(format!("reserves:{}:{}:{}", source, asset, amount));
    ///             }
    ///         }
    ///
    ///         parts.push(format!("prover:{}", self.prover));
    ///         parts.push(format!("nonce:{}", self.nonce));
    ///
    ///         parts.join("|")
    ///     }
    /// }
    /// ```
    function test_marketMaker_toString() public view {
        // Test the to_string function
        string memory result = MarketMaker.toString(mmState);

        // Verify the result
        // ? might have to globally change this to include the owner address, it must have been an oversight
        // ? to change on the prover generating the state
        string memory expected =
            "reserves:bybit:BTC:1000|reserves:bybit:USDT:50000|prover:0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C|nonce:nonce123";

        assertEq(result, expected);
    }

    /// Test the to_leaf_hash function against a hash generated using the rust code
    ///
    /// Rust implementation for reference:
    /// ```rust
    /// pub fn to_leaf_hash(&self) -> [u8; 32] {
    ///     let string_representation = self.to_string();
    ///     let bytes_repr = string_representation.as_bytes();
    ///     Sha256::digest(self.to_string().as_bytes()).into()
    /// }
    /// ```
    function test_marketMaker_toLeafHash() public view {
        // Test to_leaf_hash function
        bytes32 leafHash = mmState.toLeafHash();

        // Verify the hash is equal to the expected value
        // this value was generated using the rust counter part code for the above parameters
        bytes32 expected_leaf_hash = bytes32(0x29153f453f6fbd819b81b87259c0d16516765faa3350af02d2c15c460c2cdb81);
        assertEq(leafHash, expected_leaf_hash);
    }

    function test_marketMaker_canVerifyMerkleProofInclusion() public view {
        // construct the merkle proof
        // out tree conists of 2 identical leaves, so the second leaf is just the first leaf
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = mmState.toLeafHash();

        // this merkle root was generated using the rust code for the above parameters
        bytes32 expected_merkle_root = bytes32(0xbc7703872052714870434ff3b905125e6c10c6a1b125c12b7303c01fa42c15c7);

        bool is_valid = proof.verifyMerkleTreeInclusion(expected_merkle_root, mmState.toLeafHash());

        assert(is_valid);
    }

    function test_marketMaker_canVerifyProof() public view {
        // Verify the signatures and merkle proof
        bool success = icVerifier.verifyProof(
            merkleRootHash, icCanisterMerkleRootHashSignature, mm1StateHashSignature, mmState, merkleProofs
        );
        console.log("success:", success);
    }
}
