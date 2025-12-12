// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {ImmutableVTSState} from "./ImmutableVTSState.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {ILiquidityHub} from "../interfaces/ILiquidityHub.sol";

/**
 * @title PositionManagerBase
 * @notice Base contract providing shared functionality for position management
 * @dev Contains abstract functions and shared currency detection utilities
 * @dev Note: ImmutableState is provided by inheriting contracts (BaseActionsRouter for entrypoint, direct for impl)
 */
abstract contract PositionManagerBase is ImmutableVTSState {
    ILiquidityHub internal immutable liquidityHub;

    constructor(address _liquidityHub, address _vtsOrchestrator) ImmutableVTSState(_vtsOrchestrator) {
        liquidityHub = ILiquidityHub(_liquidityHub);
    }

    // ------------------------------------------------------------------------------------------------
    // ABSTRACT FUNCTIONS (must be implemented by inheriting contracts)
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns the locker address (original caller of the batch)
    /// @dev Must be implemented by inheriting contracts (e.g., via BaseActionsRouter._getLocker())
    function msgSender() public view virtual returns (address);

    // ------------------------------------------------------------------------------------------------
    // SHARED UTILITIES
    // ------------------------------------------------------------------------------------------------

    /// @notice Converts LCC currency to underlying currency
    /// @param lcc The LCC currency
    /// @return The underlying currency
    function _lccToUnderlyingCurrency(Currency lcc) internal view returns (Currency) {
        return Currency.wrap(ILCC(Currency.unwrap(lcc)).underlying());
    }
}
