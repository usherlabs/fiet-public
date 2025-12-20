// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ISettlementVerifier} from "../interfaces/ISettlementVerifier.sol";

contract StubSettlementVerifier is ISettlementVerifier {
    function verifySettlementProof(bytes memory, bytes memory) external pure returns (bool) {
        return true;
    }
}
