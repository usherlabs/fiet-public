// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IVRLSettlementObserver} from "./interfaces/IVRLSettlementObserver.sol";
import {ISettlementVerifier} from "./interfaces/ISettlementVerifier.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {Errors} from "./libraries/Errors.sol";
import {EfficientHashLib} from "solady/utils/EfficientHashLib.sol";

contract VRLSettlementObserver is Ownable, IVRLSettlementObserver {
    mapping(uint32 => address) public verifiers;
    uint32 public nextVerifierIndex;
    mapping(address => mapping(uint32 => bool)) public allowedVerifiersForToken;
    mapping(bytes32 => bool) public usedProofHashes;
    address public immutable submitter;

    constructor(address _submitter, address _initialOwner) Ownable(_initialOwner) {
        if (_submitter == address(0)) revert Errors.InvalidAddress(_submitter);
        submitter = _submitter;
    }

    modifier onlySubmitter() {
        _onlySubmitter();
        _;
    }

    function _onlySubmitter() internal view {
        if (msg.sender != submitter) revert Errors.InvalidSender();
    }

    // New function to add a verifier
    function addVerifier(address _verifier) external onlyOwner returns (uint32) {
        if (_verifier == address(0)) {
            revert Errors.InvalidVerifier();
        }
        uint32 index = nextVerifierIndex++;
        verifiers[index] = _verifier;
        emit VerifierAdded(_verifier, index);
        return index;
    }

    // New function to nullify a verifier globally
    function nullifyVerifier(uint32 index) external onlyOwner {
        address verifier = verifiers[index];
        if (verifier == address(0)) {
            revert Errors.InvalidVerifier();
        }
        delete verifiers[index];
        emit VerifierRemoved(verifier, index);
    }

    // New function to allow a verifier for tokens (batch)
    function allowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external onlyOwner {
        if (verifiers[verifierIndex] == address(0)) {
            revert Errors.InvalidVerifier();
        }
        for (uint256 i = 0; i < tokens.length; i++) {
            allowedVerifiersForToken[tokens[i]][verifierIndex] = true;
            emit VerifierAllowed(tokens[i], verifierIndex);
        }
    }

    // New function to disallow a verifier for tokens (batch)
    function disallowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external onlyOwner {
        for (uint256 i = 0; i < tokens.length; i++) {
            allowedVerifiersForToken[tokens[i]][verifierIndex] = false;
            emit VerifierDisallowed(tokens[i], verifierIndex);
        }
    }

    /**
     * @dev This function is used to verify the settlement proof and return the grace period extension
     * @param poolKey The pool key of the pool to verify the settlement proof for
     * @param tokenIndex The index of the token to verify the settlement proof for
     * @param verifierIndex The index of the verifier to use
     * @param settlementProof The settlement proof to verify
     * @param revertOnInvalid Whether to revert if the settlement proof is invalid
     * @return isProofValid Whether the settlement proof is valid
     */
    function verifySettlementProof(
        PoolKey memory poolKey,
        uint8 tokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof,
        bool revertOnInvalid
    ) public onlySubmitter returns (bool isProofValid) {
        if (tokenIndex != 0 && tokenIndex != 1) {
            revert Errors.InvalidTokenIndex(tokenIndex);
        }
        address token = tokenIndex == 0 ? Currency.unwrap(poolKey.currency0) : Currency.unwrap(poolKey.currency1);

        if (settlementProof.length == 0) {
            revert Errors.InvalidProof();
        }

        address verifierAddress = verifiers[verifierIndex];
        if (verifierAddress == address(0)) {
            revert Errors.InvalidVerifier();
        }

        if (!allowedVerifiersForToken[token][verifierIndex]) {
            revert Errors.InvalidVerifier();
        }

        bytes32 poolId = PoolId.unwrap(poolKey.toId());
        bytes32 proofHash = EfficientHashLib.hash(settlementProof); // cannot replay settlement proof across market chain.
        if (usedProofHashes[proofHash]) {
            revert Errors.InvalidProof();
        }

        // Verify the settlement proof
        ISettlementVerifier verifier = ISettlementVerifier(verifierAddress);
        isProofValid = verifier.verifySettlementProof(settlementProof, abi.encode(poolId, tokenIndex));

        if (revertOnInvalid && !isProofValid) {
            revert Errors.InvalidProof();
        }
        if (isProofValid) {
            usedProofHashes[proofHash] = true;
            emit SettlementProofMarkedUsed(proofHash, poolKey.toId(), verifierIndex, tokenIndex);
        }
    }
}
