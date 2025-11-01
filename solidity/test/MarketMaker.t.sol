// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {ICSpokeVerifier} from "../src/modules/ICSpokeVerifier.sol";
import {Test} from "forge-std/Test.sol";
import {MarketMakerTestBase} from "./modules/MMTestBase.sol";

contract MarketMakerTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;

    ICSpokeVerifier icVerifier;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        icVerifier = new ICSpokeVerifier(icCanister);
    }

    function test_marketMaker_toLeafHash() public view {
        // Test to_leaf_hash function
        bytes32 leafHash = liquiditySignal.mmState.toLeafHash();

        // Verify the hash is equal to the expected value
        bytes32 expected_leaf_hash = keccak256(abi.encode(liquiditySignal.mmState));
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
