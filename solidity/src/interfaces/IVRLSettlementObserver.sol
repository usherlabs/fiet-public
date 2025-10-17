// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface IVRLSettlementObserver {
    function verifySettlementProof(uint256 verifierIndex, bytes memory settlementProof) external returns (uint256);
}
