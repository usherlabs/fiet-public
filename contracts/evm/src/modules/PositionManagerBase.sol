// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ImmutableVTSState} from "./ImmutableVTSState.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {ILCC} from "../interfaces/ILCC.sol";
import {MMHelpers} from "../libraries/MMHelpers.sol";

/**
 * @title PositionManagerBase
 * @notice Base contract providing shared functionality for position management
 * @dev Contains abstract functions and shared currency detection utilities
 * @dev Note: ImmutableState is provided by inheriting contracts (BaseActionsRouter for entrypoint, direct for impl)
 */
abstract contract PositionManagerBase is ImmutableVTSState {
    constructor(address _vtsOrchestrator) ImmutableVTSState(_vtsOrchestrator) {}

    // ------------------------------------------------------------------------------------------------
    // ABSTRACT FUNCTIONS (must be implemented by inheriting contracts)
    // ------------------------------------------------------------------------------------------------

    /// @notice Returns the locker address (original caller of the batch)
    /// @dev Must be implemented by inheriting contracts (e.g., via BaseActionsRouter._getLocker())
    function msgSender() public view virtual returns (address);

    // ------------------------------------------------------------------------------------------------
    // ACCESS HELPERS
    // ------------------------------------------------------------------------------------------------

    function _assertSignalValid(uint256 tokenId) internal view {
        MMHelpers.assertSignalValid(vtsOrchestrator, tokenId);
    }

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
