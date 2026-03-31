// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Lock} from "@uniswap/v4-core/src/libraries/Lock.sol";
import {MockERC20Transferable} from "./MockERC20Transferable.sol";
import {MarketLiquidityRouterLib} from "../../../src/libraries/MarketLiquidityRouterLib.sol";

/// @notice Minimal transient-slot PoolManager mock for nested ingress fuzzing.
contract MockPoolManagerTransient {
    mapping(bytes32 => bytes32) internal transientSlot;
    address[] internal syncCalls;

    function exttload(bytes32 slot) external view returns (bytes32 value) {
        return transientSlot[slot];
    }

    function exttload(bytes32[] calldata slots) external view returns (bytes32[] memory values) {
        values = new bytes32[](slots.length);
        for (uint256 i = 0; i < slots.length; i++) {
            values[i] = transientSlot[slots[i]];
        }
    }

    function setExttload(bytes32 slot, bytes32 value) external {
        transientSlot[slot] = value;
    }

    function setLocked(bool locked) external {
        transientSlot[Lock.IS_UNLOCKED_SLOT] = locked ? bytes32(0) : bytes32(uint256(1));
    }

    function sync(Currency currency) external {
        address raw = Currency.unwrap(currency);
        syncCalls.push(raw);
        transientSlot[MarketLiquidityRouterLib.CURRENCY_SLOT] = bytes32(uint256(uint160(raw)));
        if (raw == address(0)) {
            transientSlot[MarketLiquidityRouterLib.RESERVES_OF_SLOT] = bytes32(0);
        } else {
            transientSlot[MarketLiquidityRouterLib.RESERVES_OF_SLOT] =
                bytes32(MockERC20Transferable(raw).balanceOf(address(this)));
        }
    }

    function syncCallsLength() external view returns (uint256) {
        return syncCalls.length;
    }

    function extttloadCurrency() external view returns (bytes32) {
        return transientSlot[MarketLiquidityRouterLib.CURRENCY_SLOT];
    }

    function extttloadReserves() external view returns (uint256) {
        return uint256(transientSlot[MarketLiquidityRouterLib.RESERVES_OF_SLOT]);
    }
}

