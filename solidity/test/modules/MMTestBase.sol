// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
import {MerkleProofVerifier} from "../../src/libraries/MerkleProofVerifier.sol";
import {MerkleProofGenerator} from "../libraries/MerkleProofGenerator.sol";
import {LiquiditySignal} from "../../src/types/Position.sol";
import {Test} from "forge-std/Test.sol";

abstract contract MarketMakerTestBase is Test {
    using MarketMaker for MarketMaker.State;
    using MerkleProofVerifier for bytes32[];
    using MerkleProofGenerator for bytes32[];
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    LiquiditySignal liquiditySignal;
    LiquiditySignal renewSignal;

    uint256 nonce = 1;

    // mock details about the ic canister
    uint256 icCanisterPrivateKey = uint256(keccak256(abi.encodePacked(makeAddr("icCanisterPrivateKey"))));
    address icCanister;

    struct StatePayload {
        uint256 privateKey;
        MarketMaker.State state;
    }

    /**
     * @dev entrypoint function to set up the market makers and generate the liquidity signals
     */
    function _setUpMM() public {
        icCanister = vm.addr(icCanisterPrivateKey);
        // Create a liquidity signal
        LiquiditySignal[] memory signals = generateLiquiditySignals(2);
        liquiditySignal = signals[0];
        renewSignal = signals[1];
    }

    /**
     * @dev generate liquidity signals for n market makers, each with a unique private key
     * @param numOfMarketMakers The number of market makers to generate signals for
     * @return The liquidity signals
     */
    function generateLiquiditySignals(uint256 numOfMarketMakers) internal returns (LiquiditySignal[] memory) {
        // store the states of the market makers
        StatePayload[] memory marketMakerStates = new StatePayload[](numOfMarketMakers);
        // store the merkle leaves of the market makers
        bytes32[] memory merkleLeaves = new bytes32[](numOfMarketMakers);

        for (uint256 i = 0; i < numOfMarketMakers; i++) {
            // generate a private key to serve as the signer
            uint256 uniquePrivateKey = uint256(keccak256(abi.encodePacked(i)));
            // append the market maker state to the liqudity signals generated so far
            MarketMaker.State memory state = _createMarketMakerState(uniquePrivateKey).state;
            // append the state to the array of merkle leaves, and store the mm state and private key info
            merkleLeaves[i] = state.toLeafHash();
            marketMakerStates[i] = StatePayload({privateKey: uniquePrivateKey, state: state});
        }

        // using the states, generate the merkle root hash for the states
        bytes32 merkleRootHash = merkleLeaves.generateMerkleRoot();

        // generate liquidity signals for each market maker
        LiquiditySignal[] memory liquiditySignals = new LiquiditySignal[](numOfMarketMakers);
        for (uint256 i = 0; i < numOfMarketMakers; i++) {
            // generate liquidity payload to sign
            // bytes32 liquidityPayload = _generateLiquidityPayload(marketMakerStates[i], nonce);
            // generate the signature of the liquidity payload
            bytes memory liquidityPayloadSignature =
                _signEthMessage(marketMakerStates[i].privateKey, marketMakerStates[i].state.toLeafHash());

            // generate a canister signature of the payload(merkle root hash and signature)
            bytes32 canisterSignaturePayload = sha256(abi.encodePacked(nonce, merkleRootHash));
            bytes memory icCanisterMerkleRootHashSignature =
                _signEthMessage(icCanisterPrivateKey, canisterSignaturePayload);
            // generate the liquidity signal
            liquiditySignals[i] = LiquiditySignal({
                // the merkle root hash of the merkle tree generated from the states
                rootHash: merkleRootHash,
                // the ic canister's signature of the payload(merkle root hash and the nonce)
                rootHashSignature: icCanisterMerkleRootHashSignature,
                // the merkle proof of the market maker state
                merkleProof: merkleLeaves.generateProof(i),
                // the market maker state
                mmState: marketMakerStates[i].state,
                // the signature of the market maker state and the nonce
                mmSignature: liquidityPayloadSignature,
                // The nonce must always be incrementing.
                nonce: nonce++
            });
        }

        // return the liquidity signals
        return liquiditySignals;
    }

    /**
     * @dev given a private key, generate a state for this market maker
     * @param privateKey The private key to generate the state for
     * @return The state payload
     */
    function _createMarketMakerState(uint256 privateKey) internal pure returns (StatePayload memory) {
        // use private key to get the address of the owner
        address owner = vm.addr(privateKey);
        // create a state for the owner
        MarketMaker.State memory state;
        state.owner = owner;
        state.sourceState = "0xstate.sourceState";
        state.prover = "state.prover";
        state.nonce = "nonce123";
        // this field could potentially be a zero address
        // it signifies who requests for the proof advance
        state.advancer = owner;

        // Add reserves
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({source: "bybit", asset: "BTC", amount: 1e20});
        state.reserves[1] = MarketMaker.Reserve({source: "bybit", asset: "USDT", amount: 5e18});

        return StatePayload({privateKey: privateKey, state: state});
    }

    /**
     * @dev convert the message to eth signed message and sign it, then compress the signature to 65 bytes
     * @param privateKey The private key to sign the message with
     * @param messageHash The message to sign
     * @return The compressed signature
     */
    function _signEthMessage(uint256 privateKey, bytes32 messageHash) internal pure returns (bytes memory) {
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, ethSignedMessageHash);
        return abi.encodePacked(r, s, v);
    }
}
