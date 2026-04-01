// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Minimal PoolManager stub for StateLibrary-backed reads via `extsload`.
/// @dev Stores pre-packed pool state words at the slots computed by `StateLibrary`.
contract MockPoolManager {
    // matches StateLibrary.POOLS_SLOT (uint256(6))
    bytes32 internal constant POOLS_SLOT = bytes32(uint256(6));

    mapping(bytes32 => bytes32) internal slot;
    mapping(bytes32 => uint128) internal positionLiquidity;

    /// @notice Set an arbitrary storage slot (StateLibrary layout).
    function setSlot(bytes32 s, bytes32 value) external {
        slot[s] = value;
    }

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

    /// @notice Mimic `IPoolManager.extsload` for multi-slot reads.
    function extsload(bytes32 s, uint256 nSlots) external view returns (bytes32[] memory data) {
        data = new bytes32[](nSlots);
        for (uint256 i = 0; i < nSlots; i++) {
            data[i] = slot[bytes32(uint256(s) + i)];
        }
    }

    /// @notice Stores mocked liquidity for a pool/position pair.
    /// @param poolId The pool identifier.
    /// @param positionId The position identifier.
    /// @param liquidity The mocked liquidity amount.
    function setPositionLiquidity(PoolId poolId, bytes32 positionId, uint128 liquidity) external {
        positionLiquidity[keccak256(abi.encodePacked(PoolId.unwrap(poolId), positionId))] = liquidity;
    }

    /// @notice Returns mocked liquidity for a pool/position pair.
    /// @param poolId The pool identifier.
    /// @param positionId The position identifier.
    /// @return liquidity The mocked liquidity amount.
    function getPositionLiquidity(PoolId poolId, bytes32 positionId) external view returns (uint128 liquidity) {
        return positionLiquidity[keccak256(abi.encodePacked(PoolId.unwrap(poolId), positionId))];
    }
}

