// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";

library MarketMaker {
    struct State {
        /// The owner of this mm state
        address owner;
        /// Nested mapping: source → Asset → Amount.
        /// pub reserves: BTreeMap<String, BTreeMap<String, u64>>,
        /// ? Nested mappings are complicated to iterate over in solidity
        /// ? better to preprocess the data into a string array
        /// ? so leaf can be generated using the string array rather than the nested mapping
        /// e.g ["reserves:{source1}:{asset1}:{amount1}","reserves:{source2}:{asset2}:{amount2}"]
        string[] reservesString;
        /// Hash of state of sources
        string sourceState;
        /// Prover for the state of this market maker.
        string prover;
        /// Unique nonce derived from proofs.
        string nonce;
    }

    /// Converts reserves + metadata into a deterministic string.
    function toString(State memory state) internal pure returns (string memory) {
        // Start with the reserves strings
        string memory result = "";

        // Add all reserves strings
        for (uint256 i = 0; i < state.reservesString.length; i++) {
            if (i > 0) {
                result = string(abi.encodePacked(result, "|"));
            }
            result = string(abi.encodePacked(result, state.reservesString[i]));
        }

        // Add prover
        if (state.reservesString.length > 0) {
            result = string(abi.encodePacked(result, "|"));
        }
        result = string(abi.encodePacked(result, "prover:", state.prover));

        // Add nonce
        result = string(abi.encodePacked(result, "|nonce:", state.nonce));

        return result;
    }
    /// Converts MM State to a leaf hash using SHA256 (equivalent to Rust's Sha256::digest)

    function toLeafHash(State memory state) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(toString(state)));
    }
}
