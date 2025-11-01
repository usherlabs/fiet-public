// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HexStrings} from "v4-periphery/src/libraries/HexStrings.sol";

library MarketMaker {
    /// @dev The reserve of the market maker
    struct Reserve {
        /// The source of the reserve
        string source;
        /// The asset of the reserve
        string asset;
        /// The amount of the reserve
        uint256 amount;
    }

    /// @dev The state of the market maker
    struct State {
        /// The owner of this mm state
        address owner;
        /// Reserves of the market maker
        Reserve[] reserves;
        /// Hash of state of sources
        string sourceState;
        /// Prover for the state of this market maker.
        string prover;
        /// Unique nonce derived from proofs.
        string nonce;
        /// The advancer (requestor for VRL state proof) of the market maker. Set to ensure state advancer is not spoofed on Market Chain verification.
        address advancer;
    }

    /// @dev The parameters of the proof to verify the state of the market maker
    struct ProofParams {
        /// The root state hash of the merkle tree
        bytes32 rootStateHash;
        /// The signature of the root state hash
        bytes rootStateHashSignature;
        /// The merkle proof of mm state data we want to verify in the merkle tree
        bytes32[] merkleProof;
        /// The state of the market maker
        MarketMaker.State mmStateData;
        /// The signature of the state of the market maker
        bytes mmStateHashSignature;
    }

    /// @dev The parameters of the position to create
    struct PositionParams {
        /// The core pool key of the position
        PoolKey corePoolKey;
        /// The lower tick of the position
        int24 tickLower;
        /// The upper tick of the position
        int24 tickUpper;
    }

    /**
     * @dev This function is used to get the tickers and amounts of the reserves of the market maker
     * @param state The state to get the reserves from
     * @return tickers The tickers of the reserves
     * @return amounts The amounts of the reserves
     */
    function getReserves(State memory state) internal pure returns (string[] memory tickers, uint256[] memory amounts) {
        // get the tickers and amounts from the reserves
        tickers = new string[](state.reserves.length);
        amounts = new uint256[](state.reserves.length);
        for (uint256 i = 0; i < state.reserves.length; i++) {
            tickers[i] = state.reserves[i].asset;
            amounts[i] = state.reserves[i].amount;
        }
        return (tickers, amounts);
    }

    /**
     * @dev This function is used to convert the state of the market maker to a leaf hash
     * @param state The state to convert to a leaf hash
     * @return The leaf hash of the state
     */
    function toLeafHash(State memory state) internal pure returns (bytes32) {
        return keccak256(abi.encode(state));
    }
}
