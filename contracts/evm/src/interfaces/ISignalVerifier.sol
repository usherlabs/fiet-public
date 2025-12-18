// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.26;

import {MarketMaker} from "../libraries/MarketMaker.sol";

interface ISignalVerifier {
    function verifyProof(
        uint256 nonce,
        bytes32 rootStateHash,
        bytes calldata rootStateHashSignature,
        bytes calldata mmStateHashSignature,
        MarketMaker.State calldata mmStateData,
        bytes32[] calldata merkleProof
    ) external view returns (bool);
}
