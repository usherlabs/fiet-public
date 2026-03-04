// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

interface IVRLSettlementObserver {
    event VerifierAdded(address indexed verifier, uint256 indexed index);
    event VerifierRemoved(address indexed verifier, uint256 indexed removedIndex);
    event VerifierAllowed(address indexed token, uint32 indexed verifierIndex);
    event VerifierDisallowed(address indexed token, uint32 indexed verifierIndex);
    event SettlementProofMarkedUsed(
        bytes32 indexed proofHash, PoolId indexed poolId, uint32 verifierIndex, uint8 tokenIndex
    );

    function submitter() external view returns (address);
    function addVerifier(address _verifier) external returns (uint32);
    function nullifyVerifier(uint32 index) external;
    function allowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external;
    function disallowVerifierForTokens(uint32 verifierIndex, address[] memory tokens) external;
    function verifySettlementProof(
        PoolKey memory poolKey,
        uint8 tokenIndex,
        uint32 verifierIndex,
        bytes memory settlementProof,
        bool revertOnInvalid
    ) external returns (bool isProofValid);
}
