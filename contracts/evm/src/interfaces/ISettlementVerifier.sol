// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface ISettlementVerifier {
    /// @notice Verify a settlement attestation for grace extension.
    /// @param settlementProof Prover-specific payload (often includes position binding the prover attests to).
    /// @param settlementContext ABI-encoded `(bytes32 poolId, uint8 tokenIndex, bytes32 positionId)` matching the
    ///        on-chain extension target. Verifiers MUST enforce consistency between `settlementProof` and this context.
    function verifySettlementProof(bytes memory settlementProof, bytes memory settlementContext)
        external
        pure
        returns (bool);
}
