// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionId} from "../types/Position.sol";

interface ISettlementVerifier {
    function verifySettlementProof(
        PositionId positionId,
        bytes calldata proof
    ) external returns (uint256 gracePeriodExtension);
}