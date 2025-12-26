// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {OlympixUnitTest} from "../tools/OlympixUnitTest.sol";
import {MMCalldataDecoder} from "../../../src/libraries/MMCalldataDecoder.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";

contract MMCalldataDecoderHarness {
    using MMCalldataDecoder for bytes;

    function decodeSettlePositionParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, int128 amount0, int128 amount1, bool usePositionManagerBalance)
    {
        (, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance) =
            MMCalldataDecoder.decodeSettlePositionParams(params);
    }

    function decodeIncreaseLiquidityParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, uint256 liquidity)
    {
        (, tokenId, positionIndex, liquidity) = MMCalldataDecoder.decodeIncreaseLiquidityParams(params);
    }

    function decodeMintPositionParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
    {
        (, tokenId, tickLower, tickUpper, liquidity) = MMCalldataDecoder.decodeMintPositionParams(params);
    }

    function decodeDecreaseLiquidityParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
    {
        (, tokenId, positionIndex, amountToDecrease) = MMCalldataDecoder.decodeDecreaseLiquidityParams(params);
    }

    function decodeBurnPositionParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex)
    {
        (, tokenId, positionIndex) = MMCalldataDecoder.decodeBurnPositionParams(params);
    }

    function decodeSeizePositionParams(bytes calldata params)
        external
        pure
        returns (
            uint256 tokenId,
            uint256 positionIndex,
            uint256 amount0,
            uint256 amount1,
            bool usePositionManagerBalance
        )
    {
        (, tokenId, positionIndex, amount0, amount1, usePositionManagerBalance) =
            MMCalldataDecoder.decodeSeizePositionParams(params);
    }

    function decodeIncreaseFromDeltasParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, bool payerIsUser)
    {
        (, tokenId, positionIndex, payerIsUser) = MMCalldataDecoder.decodeIncreaseFromDeltasParams(params);
    }

    function decodeMintFromDeltasParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, int24 tickLower, int24 tickUpper, bool payerIsUser)
    {
        (, tokenId, tickLower, tickUpper, payerIsUser) = MMCalldataDecoder.decodeMintFromDeltasParams(params);
    }

    function decodeSettleFromDeltasParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake)
    {
        (, tokenId, positionIndex, payerIsUser, shouldTake) = MMCalldataDecoder.decodeSettleFromDeltasParams(params);
    }

    function decodeDecommitSignalParams(bytes calldata params) external pure returns (uint256 tokenId) {
        tokenId = MMCalldataDecoder.decodeDecommitSignalParams(params);
    }

    function decodeExtendGracePeriodParams(bytes calldata params)
        external
        pure
        returns (
            uint256 tokenId,
            uint256 positionIndex,
            uint8 settlementTokenIndex,
            uint32 verifierIndex,
            bytes memory settlementProof
        )
    {
        bytes calldata proof;
        (, tokenId, positionIndex, settlementTokenIndex, verifierIndex, proof) =
            MMCalldataDecoder.decodeExtendGracePeriodParams(params);
        settlementProof = proof;
    }

    function decodeCommitSignalParams(bytes calldata params)
        external
        pure
        returns (bytes memory liquiditySignal, address owner)
    {
        bytes calldata sig;
        (sig, owner) = MMCalldataDecoder.decodeCommitSignalParams(params);
        liquiditySignal = sig;
    }

    function decodeTokenIdAndBytes(bytes calldata params) external pure returns (uint256 tokenId, bytes memory data) {
        bytes calldata cd;
        (tokenId, cd) = MMCalldataDecoder.decodeTokenIdAndBytes(params);
        data = cd;
    }

    function decodeCheckpointParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, bytes memory data, bool withCommitment)
    {
        bytes calldata cd;
        (tokenId, positionIndex, cd, withCommitment) = MMCalldataDecoder.decodeCheckpointParams(params);
        data = cd;
    }

    function decodeUnwrapLccParams(bytes calldata params)
        external
        pure
        returns (address lccAddr, uint256 amount, address recipient, bool payerIsUser)
    {
        (lccAddr, amount, recipient, payerIsUser) = MMCalldataDecoder.decodeUnwrapLccParams(params);
    }

    function decodeCollectLiquidityParams(bytes calldata params)
        external
        pure
        returns (address lcc, address recipient, uint256 maxAmount)
    {
        (lcc, recipient, maxAmount) = MMCalldataDecoder.decodeCollectLiquidityParams(params);
    }

    function decodeUint256AndBool(bytes calldata params) external pure returns (uint256 amount, bool payerIsUser) {
        (amount, payerIsUser) = MMCalldataDecoder.decodeUint256AndBool(params);
    }

    function decodeTakeParams(bytes calldata params)
        external
        pure
        returns (Currency currency, address recipient, uint256 maxAmount)
    {
        (currency, recipient, maxAmount) = MMCalldataDecoder.decodeTakeParams(params);
    }

    function decodeUint256(bytes calldata params) external pure returns (uint256 amount) {
        amount = MMCalldataDecoder.decodeUint256(params);
    }

    function decodeSyncParams(bytes calldata params) external pure returns (Currency currency) {
        currency = MMCalldataDecoder.decodeSyncParams(params);
    }
}

contract MMCalldataDecoderTest_Autocover is Test, OlympixUnitTest("MMCalldataDecoderHarness") {
    MMCalldataDecoderHarness internal h;

    function setUp() public {
        h = new MMCalldataDecoderHarness();
    }

    function test_decodeSettlePositionParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeSettlePositionParams(hex"");
    }
}

