// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

interface ISettlementVerifier {
    function verifySettlementProof(bytes memory settlementProof, bytes memory poolIdAndTokenIndex)
        external
        pure
        returns (bool);
}
