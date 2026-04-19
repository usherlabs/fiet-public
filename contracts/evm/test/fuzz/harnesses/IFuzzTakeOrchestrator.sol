// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

/// @notice Minimal orchestrator surface used by `PositionManagerImpl._routeLccCustodyTakeAndForward`.
interface IFuzzTakeOrchestrator {
    function take(Currency currency, address target, uint256 maxAmount) external returns (uint256);
}
