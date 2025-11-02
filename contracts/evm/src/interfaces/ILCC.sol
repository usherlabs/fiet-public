// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

interface ILCC {
    // ============ LCC-Specific Methods ============

    function underlying() external view returns (address);
    function balancesOf(address account) external view returns (uint256 wrapped, uint256 marketDerived);
}
