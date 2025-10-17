// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

interface IVRLSettlementObserver {
    function verifySettlementProof(
        PoolKey memory poolKey,
        uint256 verifierIndex,
        address tokenToSettleFor,
        bytes memory settlementProof
    ) external view;
}
