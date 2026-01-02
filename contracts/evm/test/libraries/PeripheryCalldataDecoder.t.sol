// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {CalldataDecoder} from "../../lib/v4-periphery/src/libraries/CalldataDecoder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

contract PeripheryCalldataDecoderHarness {
    using CalldataDecoder for bytes;

    function decodeModifyLiquidityParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes calldata hookData)
    {
        return params.decodeModifyLiquidityParams();
    }

    function decodeIncreaseLiquidityFromDeltasParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
    {
        return params.decodeIncreaseLiquidityFromDeltasParams();
    }

    function decodeMintParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        return params.decodeMintParams();
    }

    function decodeMintFromDeltasParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        return params.decodeMintFromDeltasParams();
    }

    function decodeBurnParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
    {
        return params.decodeBurnParams();
    }
}

contract PeripheryCalldataDecoderTest is Test {
    PeripheryCalldataDecoderHarness internal h;

    function setUp() public {
        h = new PeripheryCalldataDecoderHarness();
    }

    function test_decodeModifyLiquidityParams_revertsOnTruncatedHead() public {
        // Head length is 0xa0; use a 0x80 payload to ensure we were previously vulnerable to OOB calldataload defaulting.
        bytes memory truncated = new bytes(0x80);
        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        h.decodeModifyLiquidityParams(truncated);
    }

    function test_decodeIncreaseLiquidityFromDeltasParams_revertsOnTruncatedHead() public {
        // Head length is 0x80; use a 0x60 payload.
        bytes memory truncated = new bytes(0x60);
        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        h.decodeIncreaseLiquidityFromDeltasParams(truncated);
    }

    function test_decodeMintParams_revertsOnTruncatedHead() public {
        // Head length is 0x180; use a 0x160 payload.
        bytes memory truncated = new bytes(0x160);
        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        h.decodeMintParams(truncated);
    }

    function test_decodeMintFromDeltasParams_revertsOnTruncatedHead() public {
        // Head length is 0x160; use a 0x140 payload.
        bytes memory truncated = new bytes(0x140);
        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        h.decodeMintFromDeltasParams(truncated);
    }

    function test_decodeBurnParams_revertsOnTruncatedHead() public {
        // Head length is 0x80; use a 0x60 payload.
        bytes memory truncated = new bytes(0x60);
        vm.expectRevert(CalldataDecoder.SliceOutOfBounds.selector);
        h.decodeBurnParams(truncated);
    }
}

