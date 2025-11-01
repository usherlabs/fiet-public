// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
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
        // to verify hashing algorithm has not been changed
        // NOTE: This hash needs to be recalculated after switching from sha256 to keccak256
        // Run the test with -vvv to see the actual hash output, then update this value
        bytes32 expected_leaf_hash = bytes32(0x8b16fa0ca40552353a38f252dd251d4ef01166924606707a802441e94fb01cc2);
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
