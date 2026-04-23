// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILCC is IERC20 {
    // ============ LCC-Specific Methods ============
    /// @notice Factory namespace that governs this LCC.
    function factory() external view returns (address);

    /// @notice LiquidityHub authority allowed to mint/burn and coordination flows.
    function hub() external view returns (address);

    function underlying() external view returns (address);
    /// @notice Bucket split for `account`. For `BOUND_EXEMPT` holders, returns `(0, balanceOf(account))` — exempt-held
    ///         LCC is treated as market-derived for this view; bucket maps are not maintained on exempt endpoints.
    function balancesOf(address account) external view returns (uint256 wrapped, uint256 marketDerived);
}
