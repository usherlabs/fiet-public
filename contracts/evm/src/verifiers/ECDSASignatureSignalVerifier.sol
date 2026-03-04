// SPDX-License-Identifier: BUSL-1.1
// This contract is used by the VRLSignalManager contract to verify the root state hash and the mm state data
pragma solidity ^0.8.26;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ISignalVerifier} from "../interfaces/ISignalVerifier.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {MerkleProofLib} from "solady/utils/MerkleProofLib.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract ECDSASignatureSignalVerifier is ISignalVerifier {
    using ECDSA for bytes32;
    using MarketMaker for MarketMaker.State;

    address public immutable publicKeyAddress; // Threshold signature scheme (TSS) (tECDSA via MPC) address used to decentralise this signer.

    constructor(address _publicKeyAddress) {
        publicKeyAddress = _publicKeyAddress;
    }

    /**
     * @dev Verifies the proof of the market maker state
     * @param nonce The nonce of the market maker
     * @param rootStateHash The root state hash of the market maker
     * @param rootStateHashSignature The signature of the root state hash
     * @param mmStateData The market maker state data
     * @param merkleProof The merkle proof of the market maker state
     * @return True if the proof is valid, false otherwise
     */
    function verifyProof(
        uint256 nonce,
        bytes32 rootStateHash,
        bytes calldata rootStateHashSignature,
        MarketMaker.State calldata mmStateData,
        bytes32[] calldata merkleProof
    ) external view returns (bool) {
        // verify the merkle proof
        if (!MerkleProofLib.verify(merkleProof, rootStateHash, mmStateData.toLeafHash())) {
            return false;
        }

        // verify signature of the canister on the root state hash
        return MessageHashUtils.toEthSignedMessageHash(EfficientHashLib.hash(abi.encodePacked(nonce, rootStateHash)))
                .recover(rootStateHashSignature) == publicKeyAddress;
    }
}
