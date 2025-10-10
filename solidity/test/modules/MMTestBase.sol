// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
import {ShaMerkle} from "../../src/libraries/ShaMerkle.sol";
import {LiquiditySignal} from "../../src/types/Position.sol";
import {Test} from "forge-std/Test.sol";

abstract contract MarketMakerTestBase is Test {
    using MarketMaker for MarketMaker.State;
    using ShaMerkle for bytes32[];
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    LiquiditySignal liquiditySignal;

    uint256 nonce = 1;

    // mock details about the ic canister
    uint256 icCanisterPrivateKey = uint256(keccak256(abi.encodePacked(makeAddr("icCanisterPrivateKey"))));
    address icCanister;

    struct StatePayload {
        uint256 privateKey;
        MarketMaker.State state;
    }

    function _setUpMM() public {
        icCanister = vm.addr(icCanisterPrivateKey);
        // Create a liquidity signal
        liquiditySignal = generateLiquiditySignals(1)[0];
    }

    function generateLiquiditySignals(uint256 numOfMarketMakers) internal returns (LiquiditySignal[] memory) {
        // store the states of the market makers
        StatePayload[] memory marketMakerStates = new StatePayload[](numOfMarketMakers);
        // store the merkle leaves of the market makers
        bytes32[] memory merkleLeaves = new bytes32[](numOfMarketMakers);

        for (uint256 i = 0; i < numOfMarketMakers; i++) {
            // generate a private key to serve as the signature
            uint256 uniquePrivateKey = uint256(keccak256(abi.encodePacked(i)));
            // append the market maker state to the liqudity signals
            MarketMaker.State memory state = _createMarketMakerState(uniquePrivateKey).state;
            // append the state to the array of merkle leaves, and store the mm state and private key info
            merkleLeaves[i] = state.toLeafHash();
            marketMakerStates[i] = StatePayload({privateKey: uniquePrivateKey, state: state});
        }

        // using the states, generate the merkle root hash for the states
        bytes32 merkleRootHash = ShaMerkle.generateMerkleRoot(merkleLeaves);
        // generate a canister signature of the merkle root hash
        bytes memory icCanisterMerkleRootHashSignature = _signEthMessage(icCanisterPrivateKey, merkleRootHash);

        // generate liquidity signals for each market maker
        LiquiditySignal[] memory liquiditySignals = new LiquiditySignal[](numOfMarketMakers);
        for (uint256 i = 0; i < numOfMarketMakers; i++) {
            // generate liquidity payload to sign
            bytes32 liquidityPayload = _generateLiquidityPayload(marketMakerStates[i], nonce);
            // generate the signature of the liquidity payload
            bytes memory liquidityPayloadSignature = _signEthMessage(marketMakerStates[i].privateKey, liquidityPayload);
            // generate the liquidity signal
            liquiditySignals[i] = LiquiditySignal({
                // the merkle root hash of the merkle tree generated from the states
                rootHash: merkleRootHash,
                // the ic canister's signature of the merkle root hash
                rootHashSignature: icCanisterMerkleRootHashSignature,
                // the merkle proof of the market maker state
                merkleProof: ShaMerkle.generateProof(merkleLeaves, i),
                // the market maker state
                mmState: marketMakerStates[i].state,
                // the signature of the market maker state and the nonce
                signature: liquidityPayloadSignature,
                // the nonce, since all leaves are from different market makers, the nonce can be the same.
                // however users cannot reuse a nonce, and the nonce must always be incrementing.
                nonce: nonce
            });
        }

        // increment the nonce
        nonce++;
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

        // Add reserves
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({source: "bybit", asset: "BTC", amount: 1000});
        state.reserves[1] = MarketMaker.Reserve({source: "bybit", asset: "USDT", amount: 50000});

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

    /**
     * @dev combine the mm state and the nonce to generate the liquidity payload
     * @param marketMakerState The market maker state
     * @param _nonce The nonce
     * @return The liquidity payload
     */
    function _generateLiquidityPayload(StatePayload memory marketMakerState, uint256 _nonce)
        internal
        pure
        returns (bytes32)
    {
        // use sha256 to hash to maintain consistency with the merkle tree generation/processing
        // but could potentially be combined any other way to generate the payload
        return sha256(abi.encodePacked(marketMakerState.state.toLeafHash(), _nonce));
    }
}
