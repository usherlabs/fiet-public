// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
import {ICSpokeVerifier} from "../src/modules/ICSpokeVerifier.sol";
import {Test} from "forge-std/Test.sol";
import {ShaMerkle} from "../src/libraries/ShaMerkle.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";

contract MarketMakerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;
    using ShaMerkle for bytes32[];

    ICSpokeVerifier icVerifier;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        icVerifier = new ICSpokeVerifier(icCanister);
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
        string memory result = MarketMaker.toString(liquiditySignal.mmState);

        // Verify the result
        // ? might have to globally change this to include the owner address, it must have been an oversight
        // ? to change on the prover generating the state
        string memory expected =
            "owner:0xa433f323541cf82f97395076b5f83a7a06f1646creserves:bybit:BTC:100000000000000000000|reserves:bybit:USDT:5000000000000000000|prover:state.prover|nonce:nonce123|advancer:0xa433f323541cf82f97395076b5f83a7a06f1646c";

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
        bytes32 leafHash = liquiditySignal.mmState.toLeafHash();

        // Verify the hash is equal to the expected value
        // this value was generated using the rust counter part code for the above parameters
        bytes32 expected_leaf_hash = bytes32(0x26a0a297556cc3d9844355528f53687532fffe959f37d8ba4725001e96d667fc);
        assertEq(leafHash, expected_leaf_hash);
    }

    function test_marketMaker_canICSpokeVerifierVerifyProof() public view {
        // Verify the signatures and merkle proof
        bool success = icVerifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            liquiditySignal.rootHashSignature,
            liquiditySignal.mmSignature,
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        require(success, "Failed to verify proof");
    }
}
