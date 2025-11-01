// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionId} from "../types/Position.sol";

interface ISettlementVerifier {
    function verifySettlementProof(bytes memory settlementProof, bytes memory poolIdAndTokenIndex)
        external
        pure
        returns (bool);
}
