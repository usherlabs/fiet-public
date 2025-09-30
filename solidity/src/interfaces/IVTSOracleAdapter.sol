// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PositionId} from "../types/Position.sol";

/// @notice Adapter interface for an external oracle that computes VTS_required
interface IVTSOracleAdapter {
    /// @return vts0 Required bps for token0
    /// @return vts1 Required bps for token1
    /// @return version Monotonic oracle computation version
    /// @return swapSeg Last processed swap segmentId
    /// @return deficitSeg Last processed deficit segmentId
    /// @return settlementSeg Last processed settlement segmentId
    function getVTSRequiredCached(PositionId positionId)
        external
        view
        returns (uint256 vts0, uint256 vts1, uint64 version, uint256 swapSeg, uint256 deficitSeg, uint256 settlementSeg);
}
