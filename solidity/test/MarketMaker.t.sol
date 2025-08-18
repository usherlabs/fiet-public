// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
import {ICSpokeVerifier} from "../src/modules/ICSpokeVerifier.sol";
import {Test} from "forge-std/Test.sol";
import {ShaMerkle} from "../src/libraries/ShaMerkle.sol";

contract MarketMakerTest is Test {
    using MarketMaker for MarketMaker.State;
    using ShaMerkle for bytes32[];

    MarketMaker.State mmState;
    ICSpokeVerifier icVerifier;

    address mm1 = address(0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C);
    address icCanister = address(0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C);
    bytes32 merkleRootHash = bytes32(0xbc7703872052714870434ff3b905125e6c10c6a1b125c12b7303c01fa42c15c7);
    // sig(merkleRootHash)
    bytes mm1MerkleRootHashSignature =
        hex"7f9e497a6ea35fa6b2a2b70a2a9ae2920b59f89231d00a58eb5c422751b48dfb489b085a867bbd03b905a26c9c7d3f62b6d9d326b11e51644c8f7b31e21f7dac1b";
    // sig(mm.toLeafHash())
    bytes mm1StateHashSignature =
        hex"99e43530c72d6ded98e0c0c04812b0fadbe1ffb487efe507b4300f8fe35ff6866c31314ed8a4c85ccb230508401f75366ce912f4d4f89d261e973165529b7d7d1c";

    function setUp() public {
        // Create and fill in the test state
        mmState = _createTestState();
        icVerifier = new ICSpokeVerifier(icCanister);
    }

    function _createTestState() internal pure returns (MarketMaker.State memory) {
        MarketMaker.State memory state;
        state.owner = address(0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C);
        state.sourceState = "0xabcdef1234567890";
        state.prover = "0xprover1234567890";
        state.nonce = "nonce123";

        // Add reserves
        state.reservesString = new string[](2);
        state.reservesString[0] = "reserves:bybit:BTC:1000";
        state.reservesString[1] = "reserves:bybit:USDT:50000";

        return state;
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
            "reserves:bybit:BTC:1000|reserves:bybit:USDT:50000|prover:0xprover1234567890|nonce:nonce123";

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
        bytes32 expected_leaf_hash = bytes32(0xc7575a618fa9773c29d24f6302671fc475931325176c750bd3248f1b6bf3221e);
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
        // construct a merkle proof where the other leaf is the same as the first leaf
        bytes32[] memory merkle_proofs = new bytes32[](1);
        merkle_proofs[0] = mmState.toLeafHash();

        // Verify the signatures and merkle proof
        bool success = icVerifier.verifyProof(
            merkleRootHash, mm1MerkleRootHashSignature, mm1StateHashSignature, mmState, merkle_proofs
        );
        console.log("success:", success);
    }
}
