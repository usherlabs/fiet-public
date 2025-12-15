// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

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
}
