// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PositionId} from "../types/Position.sol";

interface IVTSCalculator {
    struct PositionSnapshot {
        PositionId positionId;
        uint128 liquidity; // L(r)
        int24 tickLower;
        int24 tickUpper;
        uint256 commitment0; // C0(r)
        uint256 commitment1; // C1(r)
        uint256 settled0; // S0(r)
        uint256 settled1; // S1(r)
    }

    /// @notice Compute required VTS in basis points for each position in batch
    /// @dev Pure/view calculator; no storage writes
    function vtsRequiredBatchBps(PositionSnapshot[] calldata snapshots)
        external
        view
        returns (uint256[] memory vtsRequired0Bps, uint256[] memory vtsRequired1Bps);
}
