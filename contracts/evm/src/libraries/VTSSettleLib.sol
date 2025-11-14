// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

import {VTSStorage} from "../types/VTS.sol";
import {PositionId} from "../types/Position.sol";

/// @title VTSSettleLib
/// @notice Settlement and RFS logic for VTS, operating on VTSStorage
/// @dev All helper functions are external for linked-library usage. Functions that are conceptually internal are prefixed with `_`.
library VTSSettleLib {
    /// @notice Core settlement entrypoint for MM-managed positions
    /// @param s The central VTS storage
    /// @param positionId The position id
    /// @param lccCurrency0 The pool currency of the LCC token for token0
    /// @param lccCurrency1 The pool currency of the LCC token for token1
    /// @param delta The balance delta of the settlement
    /// @param isSeizing Whether the position is being seized
    /// @return settlementDelta The delta actually applied to underlying
    /// @return rfsOpen Whether the RFS is open for the position
    /// @return seizedLiquidityUnits The amount of liquidity units seized (non-zero only when seizing)
    function onMMSettle(
        VTSStorage storage s,
        PositionId positionId,
        Currency lccCurrency0,
        Currency lccCurrency1,
        BalanceDelta delta,
        bool isSeizing
    )
        external
        returns (
            BalanceDelta settlementDelta,
            bool rfsOpen,
            uint256 seizedLiquidityUnits
        )
    {
        // Implementation to be migrated from VTSManager.onMMSettle
        // Placeholder revert to avoid silent misuse before migration is complete.
        revert("VTSSettleLib: onMMSettle not yet implemented");
    }

    /// @notice View helper for computing RFS state and delta for a position
    /// @param s The central VTS storage
    /// @param positionId The position id
    /// @return rfsOpen Whether the RFS is open
    /// @return delta The settlement delta required/available
    function _getRFS(
        VTSStorage storage s,
        PositionId positionId
    ) external view returns (bool rfsOpen, BalanceDelta delta) {
        // Implementation to be migrated from VTSManager._getRFS
        revert("VTSSettleLib: _getRFS not yet implemented");
    }

    /// @notice Raw RFS delta helper: positive => needs settlement, negative => withdrawable
    /// @param settled Current settled amount
    /// @param need Required amount
    /// @return deltaRaw Signed delta in raw units
    function _rfsDeltaRaw(
        uint256 settled,
        uint256 need
    ) external pure returns (int128 deltaRaw) {
        // Implementation to be migrated from VTSManager._rfsDeltaRaw
        revert("VTSSettleLib: _rfsDeltaRaw not yet implemented");
    }

    /// @notice Calculates liquidity units to seize for a given position and settlement delta
    /// @param s The central VTS storage
    /// @param positionId The position id
    /// @param settlementDelta The settlement delta applied during seizure
    /// @return seizedLiquidityUnits The liquidity units to seize
    function _calcSeizure(
        VTSStorage storage s,
        PositionId positionId,
        BalanceDelta settlementDelta
    ) external returns (uint256 seizedLiquidityUnits) {
        // Implementation to be migrated from VTSManager._calcSeizure
        revert("VTSSettleLib: _calcSeizure not yet implemented");
    }
}
