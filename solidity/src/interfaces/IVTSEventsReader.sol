// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapEvent, DeficitEvent, SettlementEvent} from "../libraries/EventRing.sol";

interface IVTSEventsReader {
    function getSwapRingState(PoolId poolId) external view returns (uint16 head, uint16 tail);
    function getDeficitRingState(PoolId poolId) external view returns (uint16 head, uint16 tail);
    function getSettlementRingState(PoolId poolId) external view returns (uint16 head, uint16 tail);
    function getRingCaps(PoolId poolId)
        external
        view
        returns (uint16 swapCap, uint16 deficitCap, uint16 settlementCap);

    function readSwapAt(PoolId poolId, uint16 idx) external view returns (SwapEvent memory e);
    function readDeficitAt(PoolId poolId, uint16 idx) external view returns (DeficitEvent memory e);
    function readSettlementAt(PoolId poolId, uint16 idx) external view returns (SettlementEvent memory e);
}
