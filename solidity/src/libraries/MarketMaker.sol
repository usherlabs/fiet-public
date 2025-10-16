// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {console} from "forge-std/console.sol";
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
        /// The advancer of the request for the state of the market maker
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
     * @dev This function is used to convert the state of the market maker to a string
     * @param state The state to convert to a string
     * @return result The string representation of the state
     */
    function toString(State memory state) internal pure returns (string memory result) {
        // Start with the reserves strings
        result = "";

        result = string(abi.encodePacked(result, "owner:", _addressToString(state.owner)));

        // Add all reserves strings
        for (uint256 i = 0; i < state.reserves.length; i++) {
            if (i > 0) {
                result = string(abi.encodePacked(result, "|"));
            }
            result = string(abi.encodePacked(result, _reserveToString(state.reserves[i])));
        }

        // Add prover
        if (state.reserves.length > 0) {
            result = string(abi.encodePacked(result, "|"));
        }
        result = string(abi.encodePacked(result, "prover:", state.prover));

        // Add nonce
        result = string(abi.encodePacked(result, "|nonce:", state.nonce));

        // Add advancer
        result = string(abi.encodePacked(result, "|advancer:", _addressToString(state.advancer)));
    }

    /**
     * @dev This function is used to convert the state of the market maker to a leaf hash
     * @param state The state to convert to a leaf hash
     * @return The leaf hash of the state
     */
    function toLeafHash(State memory state) internal pure returns (bytes32) {
        return sha256(abi.encodePacked(toString(state)));
    }

    /**
     * @dev This function is used to convert a uint256 to a string
     * @param _i The uint256 to convert to a string
     * @return The string representation of the uint256
     */
    function _uintToString(uint256 _i) internal pure returns (string memory) {
        if (_i == 0) {
            return "0";
        }

        uint256 number = _i;
        uint256 digitCount;

        while (number != 0) {
            digitCount++;
            number /= 10;
        }

        bytes memory resultBytes = new bytes(digitCount);
        uint256 currentPosition = digitCount;

        while (_i != 0) {
            currentPosition -= 1;
            uint8 digit = (48 + uint8(_i - (_i / 10) * 10));
            bytes1 char = bytes1(digit);
            resultBytes[currentPosition] = char;
            _i /= 10;
        }

        return string(resultBytes);
    }

    function _addressToString(address _address) internal pure returns (string memory) {
        string memory addressStr = HexStrings.toHexStringNoPrefix(uint256(uint160(_address)), 20);
        return string(abi.encodePacked("0x", addressStr));
    }

    /**
     * @param reserve The reserve to convert to a string
     * @return The string representation of the reserve
     */
    function _reserveToString(Reserve memory reserve) internal pure returns (string memory) {
        return
            string(
                abi.encodePacked("reserves:", reserve.source, ":", reserve.asset, ":", _uintToString(reserve.amount))
            );
    }
}
