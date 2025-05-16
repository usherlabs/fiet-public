// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IRFS {
    function triggerRfS(
        address underlyingAsset,
        address custodian,
        address currency,
        uint256 amount
    ) external;

    function queueWithdrawal(
        address recipient,
        address custodian,
        address currency,
        uint256 amount
    ) external;
}
