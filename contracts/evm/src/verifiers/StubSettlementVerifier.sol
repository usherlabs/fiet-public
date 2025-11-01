// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {ISettlementVerifier} from "../interfaces/ISettlementVerifier.sol";

contract StubSettlementVerifier is ISettlementVerifier {
    function verifySettlementProof(bytes memory, bytes memory) external pure returns (bool) {
        return true;
    }
}
