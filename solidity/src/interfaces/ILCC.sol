// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

interface ILCC {
    function burn(uint256 amount) external;

    function underlyingAsset() external view returns (address);

    function usdPrice(address oracleFactory) external view returns (uint256, uint256);

    function issue(uint256 amount) external;

    function cancel(uint256 amount, address deficitRecipient)
        external
        returns (uint256 amountToCancel, uint256 deficitAmount);
}
