// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ECDSASignatureSignalVerifier} from "../src/verifiers/ECDSASignatureSignalVerifier.sol";
import {MarketMakerTestBase} from "./base/MMTestBase.sol";

contract MarketMakerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;

    ECDSASignatureSignalVerifier verifier;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        verifier = new ECDSASignatureSignalVerifier(signatureVerifier);
    }

    function test_marketMaker_toLeafHash() public view {
        // Test to_leaf_hash function
        bytes32 leafHash = liquiditySignal.mmState.toLeafHash();

        // Verify the hash is equal to the expected value
        bytes32 expected_leaf_hash = keccak256(abi.encode(liquiditySignal.mmState));
        assertEq(leafHash, expected_leaf_hash);
    }

    function test_marketMaker_canECDSASignatureSignalVerifierVerifyProof() public view {
        // Verify the signatures and merkle proof
        bool success = verifier.verifyProof(
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
