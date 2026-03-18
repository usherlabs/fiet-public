// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.26;

import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {ECDSASignatureSignalVerifier} from "../../src/verifiers/ECDSASignatureSignalVerifier.sol";
import {MarketMakerTestBase} from "../base/MMTestBase.sol";
import {MerkleProofGenerator} from "../utils/MerkleProofGenerator.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract ECDSASignatureSignalVerifierTest is MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;
    using MerkleProofGenerator for bytes32[];

    ECDSASignatureSignalVerifier verifier;

    function setUp() public {
        // Create and fill in the test state
        _setUpMM();
        verifier = new ECDSASignatureSignalVerifier(signatureVerifier);
    }

    function _verifySignedState(
        uint256 nonce,
        bytes32 root,
        MarketMaker.State memory state,
        bytes32[] memory proof,
        uint256 mmSignerPrivateKey
    ) internal view returns (bool) {
        bytes memory rootHashSignature = _signEthMessage(
            signatureVerifierPrivateKey, EfficientHashLib.hash(abi.encodePacked(nonce, root))
        );
        mmSignerPrivateKey;
        return verifier.verifyProof(nonce, root, rootHashSignature, state, proof);
    }

    function test_verifyProof_validProofWithSignature() public view {
        // Verify the signatures and merkle proof
        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            liquiditySignal.rootHashSignature,
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        assertTrue(success, "Valid proof should verify successfully");
    }

    function test_verifyProof_validProofWithoutSignature_CallerIsOwner() public {
        // Create a new state where caller will be the owner
        uint256 privateKey = uint256(keccak256(abi.encodePacked("test_owner")));
        address owner = vm.addr(privateKey);

        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xf4425b4a018ab1889fdbae14e6fffae817a60341f3df5318e10b2ecaaabe1ecc";
        state.prover = "0x638a1a9699319025401c605f31464cebc63a03f5";
        state.nonce = "3df23a496fff6a3d99e1d3a6d788c4ba91d9b70afb7f90906b34fadae951d898";
        state.advancer = address(0);

        // Add reserves matching the fixture
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({asset: "USDC", amount: 493600000000000000}); // 0.4936 with 18 decimals
        state.reserves[1] = MarketMaker.Reserve({asset: "USDT", amount: 0});

        // Create merkle tree with single leaf
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0);

        // Sign root state hash with signature verifier
        bytes32 message = EfficientHashLib.hash(abi.encodePacked(uint256(1), root));
        bytes memory rootHashSignature = _signEthMessage(signatureVerifierPrivateKey, message);

        // Call as owner without mmStateHashSignature
        vm.prank(owner);
        bool success = verifier.verifyProof(1, root, rootHashSignature, state, proof);

        assertTrue(success, "Valid proof without signature should verify when caller is owner");
    }

    function test_verifyProof_validProofWithFixtureData() public view {
        // Create state matching the provided fixture structure
        // Use a known private key so we can sign properly
        uint256 ownerPrivateKey = uint256(keccak256(abi.encodePacked("fixture_owner")));
        address owner = vm.addr(ownerPrivateKey);

        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xf4425b4a018ab1889fdbae14e6fffae817a60341f3df5318e10b2ecaaabe1ecc";
        state.prover = "0x638a1a9699319025401c605f31464cebc63a03f5";
        state.nonce = "3df23a496fff6a3d99e1d3a6d788c4ba91d9b70afb7f90906b34fadae951d898";
        state.advancer = address(0);

        // Add reserves matching the fixture (0.4936 USDC, 0.0 USDT)
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({asset: "USDC", amount: 493600000000000000}); // 0.4936 with 18 decimals
        state.reserves[1] = MarketMaker.Reserve({asset: "USDT", amount: 0});

        // Create merkle tree with single leaf
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0);

        bool success = _verifySignedState(1, root, state, proof, ownerPrivateKey);

        assertTrue(success, "Fixture-based proof should verify successfully");
    }

    function test_validProofWithFixtureData() public pure {
        // Testing with fixture from FIET-prover
        //         {
        // "current_root": [
        //     86,
        //     36,
        //     19,
        //     151,
        //     153,
        //     216,
        //     146,
        //     186,
        //     117,
        //     180,
        //     254,
        //     78,
        //     188,
        //     137,
        //     5,
        //     12,
        //     76,
        //     108,
        //     97,
        //     113,
        //     119,
        //     140,
        //     38,
        //     214,
        //     0,
        //     206,
        //     54,
        //     219,
        //     241,
        //     136,
        //     203,
        //     143
        // ],
        // "market_makers": [
        //     {
        //     "nonce": "bd53ddf168f0944d06131160629ed560a9d69d253597e2fac47c5e479092162f",
        //     "owner": "0xb757d76289e61a616245faadcdbf3cf0a612bfd0",
        //     "prover": "0x899d216de273591276a0c2716946be87f990bed1",
        //     "reserves": {
        //         "USDC": 0.4936,
        //         "USDT": 0.0
        //     },
        //     "source_state": "0x06a2847653dce7af4ba9d3cf19d93b0e1556eeb7f2528e7d9159ad24053049a5"
        //     }
        // ]
        // }
        address fiet_owner = 0xB757D76289E61a616245fAadCdBf3CF0A612BFd0;

        MarketMaker.State memory state;
        state.owner = fiet_owner;
        state.sourceState = "0x06a2847653dce7af4ba9d3cf19d93b0e1556eeb7f2528e7d9159ad24053049a5";
        state.prover = "0x899d216de273591276a0c2716946be87f990bed1";
        state.nonce = "bd53ddf168f0944d06131160629ed560a9d69d253597e2fac47c5e479092162f";
        state.advancer = address(0);

        // Add reserves matching the fixture (0.4936 USDC, 0.0 USDT)
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({asset: "USDC", amount: 493600000000000000}); // 0.4936 with 18 decimals
        state.reserves[1] = MarketMaker.Reserve({asset: "USDT", amount: 0});

        // Create merkle tree with single leaf
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32 current_root = bytes32(0x5624139799d892ba75b4fe4ebc89050c4c6c6171778c26d600ce36dbf188cb8f); // current root from proof

        assertEq(root, current_root, "Fixture-based proof should verify successfully");
    }
    // ============ Invalid Signature Tests ============

    function test_verifyProof_invalidMMStateSignature_isIgnored() public view {
        // mmSignature is deprecated and no longer gates proof validity.
        uint256 wrongPrivateKey = uint256(keccak256(abi.encodePacked("wrong_key")));
        bytes32 mmStateHash = liquiditySignal.mmState.toLeafHash();
        bytes memory wrongSignature = _signEthMessage(wrongPrivateKey, mmStateHash);

        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            liquiditySignal.rootHashSignature,
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        assertTrue(success, "Proof should still verify when mmSignature is invalid");
    }

    function test_verifyProof_invalidRootStateHashSignature() public view {
        // Use wrong signature for root state hash - signed by wrong key
        uint256 wrongPrivateKey = uint256(keccak256(abi.encodePacked("wrong_key")));
        bytes32 message = EfficientHashLib.hash(abi.encodePacked(liquiditySignal.nonce, liquiditySignal.rootHash));
        bytes memory wrongSignature = _signEthMessage(wrongPrivateKey, message);

        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            wrongSignature, // Invalid signature (wrong signer)
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        assertFalse(success, "Proof with invalid root state hash signature should fail");
    }

    function test_verifyProof_malformedRootStateHashSignature_returnsFalse() public view {
        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            hex"1234",
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        assertFalse(success, "Proof with malformed root state hash signature should fail");
    }

    function test_verifyProof_nonOwnerCallerWithoutSignature() public {
        // Create state
        uint256 privateKey = uint256(keccak256(abi.encodePacked("test_owner")));
        address owner = vm.addr(privateKey);

        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xstate";
        state.prover = "prover";
        state.nonce = "nonce";
        state.advancer = address(0);
        state.reserves = new MarketMaker.Reserve[](0);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0);

        bytes32 message = EfficientHashLib.hash(abi.encodePacked(uint256(1), root));
        bytes memory rootHashSignature = _signEthMessage(signatureVerifierPrivateKey, message);

        // Caller no longer needs to be owner when mmSignature is empty.
        address wrongCaller = makeAddr("wrong_caller");
        vm.prank(wrongCaller);
        bool success = verifier.verifyProof(1, root, rootHashSignature, state, proof);

        assertTrue(success, "Proof should verify when root+merkle checks pass");
    }

    function test_verifyProof_invalidMerkleProof() public view {
        // Use wrong merkle proof
        bytes32[] memory wrongProof = new bytes32[](1);
        wrongProof[0] = bytes32(uint256(12345));

        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            liquiditySignal.rootHashSignature,
            liquiditySignal.mmState,
            wrongProof // Invalid proof
        );

        assertFalse(success, "Proof with invalid merkle proof should fail");
    }

    function test_verifyProof_wrongRootHash() public view {
        // Use wrong root hash
        bytes32 wrongRoot = bytes32(uint256(99999));

        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            wrongRoot, // Wrong root
            liquiditySignal.rootHashSignature,
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        assertFalse(success, "Proof with wrong root hash should fail");
    }

    function test_verifyProof_wrongMMState() public {
        // Create a different state
        MarketMaker.State memory wrongState = liquiditySignal.mmState;
        wrongState.owner = makeAddr("different_owner");

        bool success = verifier.verifyProof(
            liquiditySignal.nonce,
            liquiditySignal.rootHash,
            liquiditySignal.rootHashSignature,
            wrongState, // Wrong state
            liquiditySignal.merkleProof
        );

        assertFalse(success, "Proof with wrong mmState should fail");
    }

    function test_verifyProof_wrongNonce() public view {
        // Use wrong nonce with signature for original nonce - this should fail
        uint256 wrongNonce = liquiditySignal.nonce + 1;

        bool success = verifier.verifyProof(
            wrongNonce,
            liquiditySignal.rootHash,
            liquiditySignal.rootHashSignature, // Signature for original nonce, but using wrong nonce
            liquiditySignal.mmState,
            liquiditySignal.merkleProof
        );

        assertFalse(success, "Proof with wrong nonce should fail when signature doesn't match");
    }

    // ============ Edge Cases ============

    function test_verifyProof_emptyMerkleProof_SingleLeaf() public view {
        // Test with single leaf (empty proof)
        uint256 privateKey = uint256(keccak256(abi.encodePacked("single_leaf")));
        address owner = vm.addr(privateKey);

        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xstate";
        state.prover = "prover";
        state.nonce = "nonce";
        state.advancer = address(0);
        state.reserves = new MarketMaker.Reserve[](0);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0); // Should be empty for single leaf

        bool success = _verifySignedState(1, root, state, proof, privateKey);

        assertTrue(success, "Single leaf proof should verify successfully");
    }

    function test_verifyProof_multipleMarketMakers() public {
        // Test with multiple market makers in the tree
        uint256 numMMs = 3;
        StatePayload[] memory states = new StatePayload[](numMMs);
        bytes32[] memory leaves = new bytes32[](numMMs);

        for (uint256 i = 0; i < numMMs; i++) {
            uint256 privateKey = uint256(keccak256(abi.encodePacked(i)));
            states[i] = _createMarketMakerState(privateKey);
            leaves[i] = states[i].state.toLeafHash();
        }

        bytes32 root = leaves.generateMerkleRoot();
        // Test verification for each market maker
        for (uint256 i = 0; i < numMMs; i++) {
            bytes32[] memory proof = leaves.generateProof(i);
            bool success = _verifySignedState(1, root, states[i].state, proof, states[i].privateKey);

            assertTrue(success, "Multi-MM proof should verify successfully");
        }
    }

    function test_verifyProof_emptyReserves() public view {
        // Test with empty reserves
        uint256 privateKey = uint256(keccak256(abi.encodePacked("empty_reserves")));
        address owner = vm.addr(privateKey);

        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xstate";
        state.prover = "prover";
        state.nonce = "nonce";
        state.advancer = address(0);
        state.reserves = new MarketMaker.Reserve[](0); // Empty reserves

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0);

        bool success = _verifySignedState(1, root, state, proof, privateKey);

        assertTrue(success, "State with empty reserves should verify successfully");
    }

    function test_verifyProof_zeroAddressOwner() public {
        // Test with zero address owner (edge case)
        MarketMaker.State memory state;
        state.owner = address(0);
        state.sourceState = "0xstate";
        state.prover = "prover";
        state.nonce = "nonce";
        state.advancer = address(0);
        state.reserves = new MarketMaker.Reserve[](0);

        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = state.toLeafHash();
        bytes32 root = leaves.generateMerkleRoot();
        bytes32[] memory proof = leaves.generateProof(0);

        // Can't sign with zero address, so we'll test without signature and call as zero address
        bytes32 message = EfficientHashLib.hash(abi.encodePacked(uint256(1), root));
        bytes memory rootHashSignature = _signEthMessage(signatureVerifierPrivateKey, message);

        vm.prank(address(0));
        bool success = verifier.verifyProof(1, root, rootHashSignature, state, proof);

        assertTrue(success, "Zero address owner should verify when called from zero address");
    }
}
