// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @notice These tests intentionally DOCUMENT a known upstream behaviour/footgun in Uniswap v4-periphery's
 *         `CalldataDecoder` library: many decoders do NOT validate the minimum ABI "head" length before
 *         reading fixed-size words via `calldataload`.
 *
 *         Consequence: with truncated calldata, `calldataload` past the end of the byte string returns `0`,
 *         and `toBytes(...)` may still succeed (e.g. decoding an empty `bytes`), so the decode can "succeed"
 *         while returning all-zero/default values.
 *
 *         This file is NOT asserting that these decodes are safe or desirable. It exists so that if upstream
 *         changes to strict head-length checks (start reverting on truncated heads), we notice the behavioural
 *         change and can revisit any protocol assumptions or harden call-sites accordingly.
 */

import "forge-std/Test.sol";

import {CalldataDecoder} from "../../lib/v4-periphery/src/libraries/CalldataDecoder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract PeripheryCalldataDecoderHarness {
    using CalldataDecoder for bytes;

    function decodeModifyLiquidityParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes memory hookData)
    {
        bytes calldata hd;
        (tokenId, liquidity, amount0, amount1, hd) = params.decodeModifyLiquidityParams();
        hookData = hd;
    }

    function decodeIncreaseLiquidityFromDeltasParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes memory hookData)
    {
        bytes calldata hd;
        (tokenId, amount0Max, amount1Max, hd) = params.decodeIncreaseLiquidityFromDeltasParams();
        hookData = hd;
    }

    function decodeMintParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        )
    {
        PoolKey calldata pk;
        bytes calldata hd;
        (pk, tickLower, tickUpper, liquidity, amount0Max, amount1Max, owner, hd) = params.decodeMintParams();
        poolKey = PoolKey({
            currency0: pk.currency0,
            currency1: pk.currency1,
            fee: pk.fee,
            tickSpacing: pk.tickSpacing,
            hooks: IHooks(address(pk.hooks))
        });
        hookData = hd;
    }

    function decodeMintFromDeltasParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        )
    {
        PoolKey calldata pk;
        bytes calldata hd;
        (pk, tickLower, tickUpper, amount0Max, amount1Max, owner, hd) = params.decodeMintFromDeltasParams();
        poolKey = PoolKey({
            currency0: pk.currency0,
            currency1: pk.currency1,
            fee: pk.fee,
            tickSpacing: pk.tickSpacing,
            hooks: IHooks(address(pk.hooks))
        });
        hookData = hd;
    }

    function decodeBurnParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes memory hookData)
    {
        bytes calldata hd;
        (tokenId, amount0Min, amount1Min, hd) = params.decodeBurnParams();
        hookData = hd;
    }
}

contract PeripheryCalldataDecoderTest is Test {
    PeripheryCalldataDecoderHarness internal h;

    function setUp() public {
        h = new PeripheryCalldataDecoderHarness();
    }

    function test_decodeModifyLiquidityParams_truncatedHead_returnsZeroes() public view {
        // Per upstream v4-periphery behaviour, these decoders may *not* revert on truncated heads
        // (static-word calldataload returns zero, and `toBytes` can still succeed with length=0).
        bytes memory truncated = new bytes(0x80);
        (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes memory hookData) =
            h.decodeModifyLiquidityParams(truncated);
        assertEq(tokenId, 0);
        assertEq(liquidity, 0);
        assertEq(amount0, 0);
        assertEq(amount1, 0);
        assertEq(hookData.length, 0);
    }

    function test_decodeIncreaseLiquidityFromDeltasParams_truncatedHead_returnsZeroes() public view {
        bytes memory truncated = new bytes(0x60);
        (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes memory hookData) =
            h.decodeIncreaseLiquidityFromDeltasParams(truncated);
        assertEq(tokenId, 0);
        assertEq(amount0Max, 0);
        assertEq(amount1Max, 0);
        assertEq(hookData.length, 0);
    }

    function test_decodeMintParams_truncatedHead_returnsZeroes() public view {
        bytes memory truncated = new bytes(0x160);
        (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = h.decodeMintParams(truncated);
        // PoolKey is read as a pointer to calldata; for a zero-filled buffer, its fields decode to zero.
        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), address(0));
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 0);
        assertEq(address(poolKey.hooks), address(0));
        assertEq(tickLower, 0);
        assertEq(tickUpper, 0);
        assertEq(liquidity, 0);
        assertEq(amount0Max, 0);
        assertEq(amount1Max, 0);
        assertEq(owner, address(0));
        assertEq(hookData.length, 0);
    }

    function test_decodeMintFromDeltasParams_truncatedHead_returnsZeroes() public view {
        bytes memory truncated = new bytes(0x140);
        (
            PoolKey memory poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes memory hookData
        ) = h.decodeMintFromDeltasParams(truncated);
        assertEq(Currency.unwrap(poolKey.currency0), address(0));
        assertEq(Currency.unwrap(poolKey.currency1), address(0));
        assertEq(poolKey.fee, 0);
        assertEq(poolKey.tickSpacing, 0);
        assertEq(address(poolKey.hooks), address(0));
        assertEq(tickLower, 0);
        assertEq(tickUpper, 0);
        assertEq(amount0Max, 0);
        assertEq(amount1Max, 0);
        assertEq(owner, address(0));
        assertEq(hookData.length, 0);
    }

    function test_decodeBurnParams_truncatedHead_returnsZeroes() public view {
        bytes memory truncated = new bytes(0x60);
        (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes memory hookData) = h.decodeBurnParams(truncated);
        assertEq(tokenId, 0);
        assertEq(amount0Min, 0);
        assertEq(amount1Min, 0);
        assertEq(hookData.length, 0);
    }
}

