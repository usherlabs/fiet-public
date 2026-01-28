// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Minimal PoolManager stub for `StateLibrary.getSlot0` via `extsload`.
/// @dev Stores a pre-packed slot0 word at the pool's state slot (as computed by `StateLibrary`).
contract MockPoolManagerSlot0 {
    // matches StateLibrary.POOLS_SLOT (uint256(6))
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    mapping(bytes32 => bytes32) internal slot;

    /// @notice Set the slot0 word for a given pool id.
    function setSlot0(PoolId poolId, uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) external {
        bytes32 stateSlot = keccak256(abi.encodePacked(PoolId.unwrap(poolId), POOLS_SLOT));

        uint256 t = uint256(uint24(tick));
        uint256 data = uint256(lpFee);
        data = (data << 24) | uint256(protocolFee);
        data = (data << 24) | t;
        data = (data << 160) | uint256(sqrtPriceX96);
        slot[stateSlot] = bytes32(data);
    }

    /// @notice Mimic `IPoolManager.extsload`.
    function extsload(bytes32 s) external view returns (bytes32) {
        return slot[s];
    }
}

