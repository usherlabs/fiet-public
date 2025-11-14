// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {VTSStorage, PositionAccounting} from "../types/VTS.sol";
import {PositionId, Position} from "../types/Position.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LiquidityUtils} from "./LiquidityUtils.sol";
import {Errors} from "../libraries/Errors.sol";

/// @title VTSCommitLib
/// @notice Commit and commitment deficit management helpers for VTS, operating on VTSStorage
/// @dev All functions are external/public for linked-library usage but prefixed with `_` as they are conceptually internal.
/// @author Fiet Protocol
library VTSCommitLib {
    /// @notice Applies commitment deficit to a batch of positions
    /// @param s The central VTS storage
    /// @param mmPositionManager The MM Position Manager address (for validation)
    /// @param ids Array of position IDs to apply deficit to
    /// @param totalDeficitBps Total deficit basis points to distribute across positions
    function _applyCommitmentDeficit(
        VTSStorage storage s,
        address mmPositionManager,
        PositionId[] calldata ids,
        uint256 totalDeficitBps
    ) external {
        uint256 n = ids.length;
        uint256 bpsValue = totalDeficitBps / n;

        for (uint256 i = 0; i < n; ) {
            PositionId id = ids[i];
            Position memory pos = s.positions[id];

            // Validate position is MM-managed
            if (pos.owner != mmPositionManager) {
                revert Errors.InvalidPosition(0, 0, id);
            }

            PositionAccounting storage pa = s.positionAccounting[id];
            uint256 cd0 = pa.commitmentDeficit0;
            uint256 cd1 = pa.commitmentDeficit1;

            // If bps = 0 and deficit exists, clear it
            if (bpsValue == 0) {
                if (cd0 > 0 || cd1 > 0) {
                    pa.commitmentDeficit0 = 0;
                    pa.commitmentDeficit1 = 0;
                }
            } else {
                // Apply same BPS to both tokens
                uint256 c0 = pa.commitmentMax0;
                uint256 c1 = pa.commitmentMax1;
                uint256 add0 = c0 == 0
                    ? 0
                    : FullMath.mulDiv(
                        c0,
                        bpsValue,
                        LiquidityUtils.BPS_DENOMINATOR
                    );
                uint256 add1 = c1 == 0
                    ? 0
                    : FullMath.mulDiv(
                        c1,
                        bpsValue,
                        LiquidityUtils.BPS_DENOMINATOR
                    );
                if (add0 > c0) add0 = c0;
                if (add1 > c1) add1 = c1;
                if (add0 > 0) {
                    pa.commitmentDeficit0 += add0;
                }
                if (add1 > 0) {
                    pa.commitmentDeficit1 += add1;
                }
            }
            unchecked {
                i++;
            }
        }
    }
}
