// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ERC20} from "solmate/tokens/ERC20.sol";

interface ILCC {
    function underlying() external view returns (address);

    function balancesOf(address account) external view returns (uint256 wrapped, uint256 marketDerived);

    function issue(uint256 amount) external;

    function cancel(uint256 amount) external;

    function confirmTake(bytes32 marketId, uint256 amount, bool shouldProcessQueue) external;

    function prepareSettle(uint256 amount) external;

    function unwrapFromVault(bytes32 marketId, uint256 amount, uint256 deficitAmount, address excessLCCRecipient)
        external;

    function traceTransfer(address to, bytes32 marketId, uint256 amount) external;

    function unwrapTo(address to, uint256 amount) external;

    function unwrap(uint256 amount) external;

    function wrap(uint256 amount) external;

    function wrapTo(address to, uint256 amount) external;
}
