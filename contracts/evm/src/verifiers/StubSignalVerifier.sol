// SPDX-License-Identifier: BUSL-1.1
/// Stub implementation of the SpokeVerifier interface
/// This implementation does not perform any verification
/// It is used for development and testing purposes

pragma solidity ^0.8.0;

import {MarketMaker} from "../libraries/MarketMaker.sol";
import {ISignalVerifier} from "../interfaces/ISignalVerifier.sol";

contract StubSignalVerifier is ISignalVerifier {
    function verifyProof(
        uint256,
        bytes32,
        bytes calldata,
        bytes calldata,
        MarketMaker.State calldata,
        bytes32[] calldata
    ) external pure returns (bool) {
        return true;
    }
}
