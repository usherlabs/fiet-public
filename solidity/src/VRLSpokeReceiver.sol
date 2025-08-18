// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {MarketMaker} from "./libraries/MarketMaker.sol";
import {ISpokeVerifier} from "./interfaces/ISpokeVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract VRLSpokeReceiver is Ownable {
    ISpokeVerifier public verifier;

    event VerifierChanged(address indexed oldVerifier, address indexed newVerifier);

    error InvalidProof();

    constructor(address _verifier) Ownable(msg.sender) {
        verifier = ISpokeVerifier(_verifier);
    }

    function setVerifier(address _newVerifier) external onlyOwner {
        address oldVerifier = address(verifier);
        verifier = ISpokeVerifier(_newVerifier);
        emit VerifierChanged(oldVerifier, _newVerifier);
    }

    function receiveVRL(
        bytes32 rootStateHash,
        bytes calldata rootStateHashSignature,
        bytes32[] calldata merkleProof,
        MarketMaker.State calldata mmStateData,
        bytes calldata mmStateHashSignature
    ) public view {
        // verify the proof
        bool success =
            verifier.verifyProof(rootStateHash, rootStateHashSignature, mmStateHashSignature, mmStateData, merkleProof);

        // if the verification is successful, start commitment process
        // if the verification is not successful, revert
        if (!success) {
            revert InvalidProof();
        }

        // TODO : begin commitment process
    }
}
