// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @notice Minimal orchestrator surface needed by the MMQ-01 custody harness.
interface IFuzzTakeOrchestrator {
    function take(Currency currency, address target, uint256 maxAmount) external returns (uint256);
}
