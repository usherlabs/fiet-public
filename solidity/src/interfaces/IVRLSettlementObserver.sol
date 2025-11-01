// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IVRLSettlementObserver {
    error InvalidVerifierAddress();
    error InvalidSettlementProof();
    error InvalidVerifierIndex();
    error VerifierNotMapped();

    event VerifierAdded(address indexed verifier, uint256 indexed index);
    event VerifierRemoved(address indexed verifier, uint256 indexed removedIndex);
    event VerifierAllowed(address indexed token, uint32 indexed verifierIndex);
    event VerifierDisallowed(address indexed token, uint32 indexed verifierIndex);

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
    ) external view returns (bool isProofValid);
}
