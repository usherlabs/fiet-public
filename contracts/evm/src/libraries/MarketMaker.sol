// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

library MarketMaker {
    /// @dev The reserve of the market maker
    struct Reserve {
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
        /// @dev Absolute unix timestamp after which this signed MM leaf must not be accepted on-chain (enforced in
        ///      `VRLSignalManager` against `block.timestamp`). Included in the Merkle leaf via `abi.encode(state)`.
        uint256 expiryAt;
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
     * @return The leaf hash of the state (`keccak256(abi.encode(v0))`)
     */
    function toLeafHash(State memory state) internal pure returns (bytes32) {
        return EfficientHashLib.hash(abi.encode(state));
    }

    /**
     * @dev Copies a State from memory to storage (legacy pipeline compatible)
     * @notice Direct struct assignment of State (memory → storage) requires via_ir.
     *         This helper avoids that by copying fields individually and using push() for the array.
     * @param dest The destination storage pointer
     * @param src The source memory State
     */
    function save(State storage dest, State memory src) internal {
        dest.owner = src.owner;
        dest.sourceState = src.sourceState;
        dest.prover = src.prover;
        dest.nonce = src.nonce;
        dest.advancer = src.advancer;
        dest.expiryAt = src.expiryAt;

        // Clear existing reserves and copy new ones element by element
        delete dest.reserves;
        for (uint256 i = 0; i < src.reserves.length; i++) {
            dest.reserves.push(src.reserves[i]);
        }
    }
}
