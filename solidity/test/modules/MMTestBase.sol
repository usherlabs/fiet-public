// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "../../src/libraries/MarketMaker.sol";
import {console} from "forge-std/console.sol";
import {ShaMerkle} from "../../src/libraries/ShaMerkle.sol";
import {LiquiditySignal} from "../../src/types/Position.sol";

abstract contract MarketMakerTestBase {
    using MarketMaker for MarketMaker.State;
    using ShaMerkle for bytes32[];

    MarketMaker.State mmState;
    LiquiditySignal liquiditySignal;

    bytes32[] merkleProofs;

    address mm1 = address(0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C);
    address icCanister = address(0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C);
    bytes32 merkleRootHash = bytes32(0xbc7703872052714870434ff3b905125e6c10c6a1b125c12b7303c01fa42c15c7);
    // sig(merkleRootHash)
    bytes icCanisterMerkleRootHashSignature =
        hex"7f9e497a6ea35fa6b2a2b70a2a9ae2920b59f89231d00a58eb5c422751b48dfb489b085a867bbd03b905a26c9c7d3f62b6d9d326b11e51644c8f7b31e21f7dac1b";
    // sig(mm.toLeafHash())
    bytes mm1StateHashSignature =
        hex"99e43530c72d6ded98e0c0c04812b0fadbe1ffb487efe507b4300f8fe35ff6866c31314ed8a4c85ccb230508401f75366ce912f4d4f89d261e973165529b7d7d1c";

    function _setUpMM() public {
        // Create and fill in the test state
        mmState = _createTestState();
        // construct a merkle proof where the other leaf is the same as the first leaf
        merkleProofs = new bytes32[](1);
        merkleProofs[0] = mmState.toLeafHash();
        // Create a liquidity signal
        liquiditySignal = LiquiditySignal({
            rootHash: merkleRootHash,
            rootHashSignature: icCanisterMerkleRootHashSignature,
            merkleProof: merkleProofs,
            mmState: mmState,
            mmStateHashSignature: mm1StateHashSignature
        });
    }

    function _createTestState() internal pure returns (MarketMaker.State memory) {
        MarketMaker.State memory state;
        state.owner = address(0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C);
        state.sourceState = "0xabcdef1234567890";
        state.prover = "0x39E7b9A0E61dc09980858c20481C3273E1dAaa9C";
        state.nonce = "nonce123";

        // Add reserves
        state.reserves = new MarketMaker.Reserve[](2);
        state.reserves[0] = MarketMaker.Reserve({source: "bybit", asset: "BTC", amount: 1000});
        state.reserves[1] = MarketMaker.Reserve({source: "bybit", asset: "USDT", amount: 50000});

        return state;
    }
}
