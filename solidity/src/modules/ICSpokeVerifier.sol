// SPDX-License-Identifier: MIT
// This contract is used by the VRLSignalManager contract to verify the root state hash and the mm state data
pragma solidity ^0.8.0;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {ISpokeVerifier} from "../interfaces/ISpokeVerifier.sol";
import {MarketMaker} from "../libraries/MarketMaker.sol";
import {MerkleProofLib} from "solmate/utils/MerkleProofLib.sol";

contract ICSpokeVerifier is ISpokeVerifier {
    using ECDSA for bytes32;
    using MarketMaker for MarketMaker.State;

    error UnauthorizedCaller();
    error InvalidMerkleProof();
    error InvalidRootStateHashSignature();

    address public immutable canisterAddress; // Threshold signature scheme (TSS) (tECDSA via MPC) address used to decentralise this signer.

    constructor(address _canisterAddress) {
        canisterAddress = _canisterAddress;
    }

    /**
     * @dev Verifies the proof of the market maker state
     * @param nonce The nonce of the market maker
     * @param rootStateHash The root state hash of the market maker
     * @param rootStateHashSignature The signature of the root state hash
     * @param mmStateHashSignature The signature of the market maker state
     * @param mmStateData The market maker state data
     * @param merkleProof The merkle proof of the market maker state
     * @return True if the proof is valid, false otherwise
     */
    function verifyProof(
        uint256 nonce,
        bytes32 rootStateHash,
        bytes calldata rootStateHashSignature,
        bytes calldata mmStateHashSignature,
        MarketMaker.State calldata mmStateData,
        bytes32[] calldata merkleProof
    ) external view returns (bool) {
        address caller = address(msg.sender);
        bytes32 mmStateHash = mmStateData.toLeafHash();
        bool isCallerAuthorized = false;
        // if signature is provided, validate it against mmstate 'owner' field
        // if it is not, verify the msg.sender is the mmstate 'owner' field i.e owner is caller
        if (mmStateHashSignature.length == 0) {
            // if the caller is valid, set isCallerAuthorized to true
            isCallerAuthorized = caller == mmStateData.owner;
        } else {
            // if the signature is valid, set isCallerAuthorized to true
            // generate the message hash to sign from the leafhash and the nonce
            address recovered =
                MessageHashUtils.toEthSignedMessageHash(mmStateData.toLeafHash()).recover(mmStateHashSignature);
            isCallerAuthorized = recovered == mmStateData.owner;
        }

        // make sure the caller is authorized to perform this action
        if (!isCallerAuthorized) {
            // revert UnauthorizedCaller();
            return false;
        }

        // verify the merkle proof
        bool isProofValid = MerkleProofLib.verify(merkleProof, rootStateHash, mmStateHash);
        if (!isProofValid) {
            // revert InvalidMerkleProof();
            return false;
        }

        // verify signature of the canister on the root state hash
        bytes32 message = keccak256(abi.encodePacked(nonce, rootStateHash));
        bool isRootStateHashValid =
            MessageHashUtils.toEthSignedMessageHash(message).recover(rootStateHashSignature) == canisterAddress;

        if (!isRootStateHashValid) {
            // revert InvalidRootStateHashSignature();
            return false;
        }

        return true;
    }
}
