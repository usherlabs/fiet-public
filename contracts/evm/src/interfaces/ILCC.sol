// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface ILCC is IERC20 {
    // ============ LCC-Specific Methods ============

    function underlying() external view returns (address);
    function balancesOf(address account) external view returns (uint256 wrapped, uint256 marketDerived);

    // ============ Safe Transfer Methods ============

    function safeTransfer(address to, uint256 amount) external returns (bool);
    function safeTransferFrom(address from, address to, uint256 amount) external returns (bool);
}
