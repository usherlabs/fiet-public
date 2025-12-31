// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "forge-std/Test.sol";

import {MMCalldataDecoder} from "../../src/libraries/MMCalldataDecoder.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

contract MMCalldataDecoderHarness {
    using MMCalldataDecoder for bytes;

    function decodeSettlePositionParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey memory poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            int128 amount0,
            int128 amount1,
            bool usePMBalance
        )
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex, amount0, amount1, usePMBalance) = params.decodeSettlePositionParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeIncreaseLiquidityParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 liquidity)
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex, liquidity) = params.decodeIncreaseLiquidityParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeMintPositionParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
    {
        PoolKey calldata pk;
        (pk, tokenId, tickLower, tickUpper, liquidity) = params.decodeMintPositionParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeDecreaseLiquidityParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex, amountToDecrease) = params.decodeDecreaseLiquidityParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeBurnPositionParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex)
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex) = params.decodeBurnPositionParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeSeizePositionParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey memory poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint256 amount0,
            uint256 amount1,
            bool usePMBalance
        )
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex, amount0, amount1, usePMBalance) = params.decodeSeizePositionParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeIncreaseFromDeltasParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser)
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex, payerIsUser) = params.decodeIncreaseFromDeltasParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeMintFromDeltasParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, bool payerIsUser)
    {
        PoolKey calldata pk;
        (pk, tokenId, tickLower, tickUpper, payerIsUser) = params.decodeMintFromDeltasParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeSettleFromDeltasParams(bytes calldata params)
        external
        pure
        returns (PoolKey memory poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake)
    {
        PoolKey calldata pk;
        (pk, tokenId, positionIndex, payerIsUser, shouldTake) = params.decodeSettleFromDeltasParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
    }

    function decodeDecommitSignalParams(bytes calldata params) external pure returns (uint256 tokenId) {
        tokenId = params.decodeDecommitSignalParams();
    }

    function decodeExtendGracePeriodParams(bytes calldata params)
        external
        pure
        returns (
            PoolKey memory poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint8 settlementTokenIndex,
            uint32 verifierIndex,
            bytes memory settlementProof
        )
    {
        PoolKey calldata pk;
        bytes calldata proof;
        (pk, tokenId, positionIndex, settlementTokenIndex, verifierIndex, proof) =
            params.decodeExtendGracePeriodParams();
        poolKey = PoolKey({
            currency0: pk.currency0, currency1: pk.currency1, fee: pk.fee, tickSpacing: pk.tickSpacing, hooks: pk.hooks
        });
        settlementProof = proof;
    }

    function decodeCommitSignalParams(bytes calldata params)
        external
        pure
        returns (bytes memory liquiditySignal, address owner)
    {
        bytes calldata sig;
        (sig, owner) = params.decodeCommitSignalParams();
        liquiditySignal = sig;
    }

    function decodeTokenIdAndBytes(bytes calldata params) external pure returns (uint256 tokenId, bytes memory data) {
        bytes calldata cd;
        (tokenId, cd) = params.decodeTokenIdAndBytes();
        data = cd;
    }

    function decodeCheckpointParams(bytes calldata params)
        external
        pure
        returns (uint256 tokenId, uint256 positionIndex, bytes memory data, bool withCommitment)
    {
        bytes calldata cd;
        (tokenId, positionIndex, cd, withCommitment) = params.decodeCheckpointParams();
        data = cd;
    }

    function decodeUnwrapLccParams(bytes calldata params)
        external
        pure
        returns (address lccAddr, uint256 amount, address recipient, bool payerIsUser)
    {
        (lccAddr, amount, recipient, payerIsUser) = params.decodeUnwrapLccParams();
    }

    function decodeCollectLiquidityParams(bytes calldata params)
        external
        pure
        returns (address lcc, uint256 maxAmount)
    {
        (lcc, maxAmount) = params.decodeCollectLiquidityParams();
    }

    function decodeUint256AndBool(bytes calldata params) external pure returns (uint256 amount, bool payerIsUser) {
        (amount, payerIsUser) = params.decodeUint256AndBool();
    }

    function decodeTakeParams(bytes calldata params)
        external
        pure
        returns (Currency currency, address recipient, uint256 maxAmount)
    {
        (currency, recipient, maxAmount) = params.decodeTakeParams();
    }

    function decodeUint256(bytes calldata params) external pure returns (uint256 amount) {
        amount = params.decodeUint256();
    }

    function decodeSyncParams(bytes calldata params) external pure returns (Currency currency) {
        currency = params.decodeSyncParams();
    }
}

contract MMCalldataDecoderTest is Test {
    MMCalldataDecoderHarness internal h;

    function setUp() public {
        h = new MMCalldataDecoderHarness();
    }

    function _poolKey() internal pure returns (PoolKey memory key) {
        key = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(address(0x3333))
        });
    }

    // --- happy paths ---

    function test_decodeSettlePositionParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2), int128(-3), int128(4), true);

        (PoolKey memory k, uint256 tokenId, uint256 positionIndex, int128 a0, int128 a1, bool usePM) =
            h.decodeSettlePositionParams(params);
        assertEq(Currency.unwrap(k.currency0), Currency.unwrap(key.currency0));
        assertEq(Currency.unwrap(k.currency1), Currency.unwrap(key.currency1));
        assertEq(k.fee, key.fee);
        assertEq(k.tickSpacing, key.tickSpacing);
        assertEq(address(k.hooks), address(key.hooks));
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertEq(a0, -3);
        assertEq(a1, 4);
        assertTrue(usePM);
    }

    function test_decodeIncreaseLiquidityParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2), uint256(123));
        (PoolKey memory k, uint256 tokenId, uint256 positionIndex, uint256 liq) =
            h.decodeIncreaseLiquidityParams(params);
        assertEq(k.fee, key.fee);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertEq(liq, 123);
    }

    function test_decodeMintPositionParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(77), int24(-120), int24(120), uint256(999));
        (PoolKey memory k, uint256 tokenId, int24 tl, int24 tu, uint256 liq) = h.decodeMintPositionParams(params);
        assertEq(k.tickSpacing, key.tickSpacing);
        assertEq(tokenId, 77);
        assertEq(tl, -120);
        assertEq(tu, 120);
        assertEq(liq, 999);
    }

    function test_decodeDecreaseLiquidityParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2), uint256(5));
        (, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease) = h.decodeDecreaseLiquidityParams(params);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertEq(amountToDecrease, 5);
    }

    function test_decodeBurnPositionParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2));
        (, uint256 tokenId, uint256 positionIndex) = h.decodeBurnPositionParams(params);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
    }

    function test_decodeSeizePositionParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2), uint256(1), uint256(2), false);
        (, uint256 tokenId, uint256 positionIndex, uint256 amount0, uint256 amount1, bool usePM) =
            h.decodeSeizePositionParams(params);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertEq(amount0, 1);
        assertEq(amount1, 2);
        assertFalse(usePM);
    }

    function test_decodeIncreaseFromDeltasParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2), true);
        (, uint256 tokenId, uint256 positionIndex, bool payerIsUser) = h.decodeIncreaseFromDeltasParams(params);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertTrue(payerIsUser);
    }

    function test_decodeMintFromDeltasParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), int24(-1), int24(1), false);
        (, uint256 tokenId, int24 tl, int24 tu, bool payerIsUser) = h.decodeMintFromDeltasParams(params);
        assertEq(tokenId, 10);
        assertEq(tl, -1);
        assertEq(tu, 1);
        assertFalse(payerIsUser);
    }

    function test_decodeSettleFromDeltasParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory params = abi.encode(key, uint256(10), uint256(2), true, false);
        (, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake) =
            h.decodeSettleFromDeltasParams(params);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertTrue(payerIsUser);
        assertFalse(shouldTake);
    }

    function test_decodeDecommitSignalParams_ok() public view {
        bytes memory params = abi.encode(uint256(123));
        assertEq(h.decodeDecommitSignalParams(params), 123);
    }

    function test_decodeExtendGracePeriodParams_ok() public view {
        PoolKey memory key = _poolKey();
        bytes memory proof = hex"11223344";
        bytes memory params = abi.encode(key, uint256(10), uint256(2), uint8(7), uint32(9), proof);

        (
            PoolKey memory k,
            uint256 tokenId,
            uint256 positionIndex,
            uint8 settlementTokenIndex,
            uint32 verifierIndex,
            bytes memory settlementProof
        ) = h.decodeExtendGracePeriodParams(params);
        assertEq(k.fee, key.fee);
        assertEq(tokenId, 10);
        assertEq(positionIndex, 2);
        assertEq(settlementTokenIndex, 7);
        assertEq(verifierIndex, 9);
        assertEq(keccak256(settlementProof), keccak256(proof));
    }

    function test_decodeCommitSignalParams_ok() public view {
        bytes memory sig = hex"deadbeef";
        address owner = address(0xBEEF);
        bytes memory params = abi.encode(sig, owner);
        (bytes memory outSig, address outOwner) = h.decodeCommitSignalParams(params);
        assertEq(outOwner, owner);
        assertEq(keccak256(outSig), keccak256(sig));
    }

    function test_decodeTokenIdAndBytes_ok() public view {
        bytes memory data = "hello";
        bytes memory params = abi.encode(uint256(55), data);
        (uint256 tokenId, bytes memory out) = h.decodeTokenIdAndBytes(params);
        assertEq(tokenId, 55);
        assertEq(keccak256(out), keccak256(data));
    }

    function test_decodeCheckpointParams_ok() public view {
        bytes memory sig = hex"010203";
        bytes memory params = abi.encode(uint256(55), uint256(2), sig, false);
        (uint256 tokenId, uint256 positionIndex, bytes memory out, bool withCommitment) =
            h.decodeCheckpointParams(params);
        assertEq(tokenId, 55);
        assertEq(positionIndex, 2);
        assertEq(keccak256(out), keccak256(sig));
        assertFalse(withCommitment);
    }

    function test_decodeUnwrapLccParams_ok() public view {
        bytes memory params = abi.encode(address(0x1111), uint256(9), address(0x2222), true);
        (address lcc, uint256 amount, address recipient, bool payerIsUser) = h.decodeUnwrapLccParams(params);
        assertEq(lcc, address(0x1111));
        assertEq(amount, 9);
        assertEq(recipient, address(0x2222));
        assertTrue(payerIsUser);
    }

    function test_decodeCollectLiquidityParams_ok() public view {
        bytes memory params = abi.encode(address(0x1111), uint256(9));
        (address lcc, uint256 maxAmount) = h.decodeCollectLiquidityParams(params);
        assertEq(lcc, address(0x1111));
        assertEq(maxAmount, 9);
    }

    function test_decodeUint256AndBool_ok() public view {
        bytes memory params = abi.encode(uint256(9), false);
        (uint256 amount, bool payerIsUser) = h.decodeUint256AndBool(params);
        assertEq(amount, 9);
        assertFalse(payerIsUser);
    }

    function test_decodeTakeParams_ok() public view {
        Currency c = Currency.wrap(address(0x1234));
        bytes memory params = abi.encode(c, address(0xBEEF), uint256(42));
        (Currency outC, address recipient, uint256 maxAmount) = h.decodeTakeParams(params);
        assertEq(Currency.unwrap(outC), Currency.unwrap(c));
        assertEq(recipient, address(0xBEEF));
        assertEq(maxAmount, 42);
    }

    function test_decodeUint256_ok() public view {
        bytes memory params = abi.encode(uint256(9));
        assertEq(h.decodeUint256(params), 9);
    }

    function test_decodeSyncParams_ok() public view {
        Currency c = Currency.wrap(address(0x1234));
        bytes memory params = abi.encode(c);
        assertEq(Currency.unwrap(h.decodeSyncParams(params)), Currency.unwrap(c));
    }

    // --- revert paths (short calldata) ---

    function test_decodeSettlePositionParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeSettlePositionParams(hex"");
    }

    function test_decodeIncreaseLiquidityParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeIncreaseLiquidityParams(hex"");
    }

    function test_decodeMintPositionParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeMintPositionParams(hex"");
    }

    function test_decodeDecreaseLiquidityParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeDecreaseLiquidityParams(hex"");
    }

    function test_decodeBurnPositionParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeBurnPositionParams(hex"");
    }

    function test_decodeSeizePositionParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeSeizePositionParams(hex"");
    }

    function test_decodeIncreaseFromDeltasParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeIncreaseFromDeltasParams(hex"");
    }

    function test_decodeMintFromDeltasParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeMintFromDeltasParams(hex"");
    }

    function test_decodeSettleFromDeltasParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeSettleFromDeltasParams(hex"");
    }

    function test_decodeDecommitSignalParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeDecommitSignalParams(hex"");
    }

    function test_decodeExtendGracePeriodParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeExtendGracePeriodParams(hex"");
    }

    function test_decodeUnwrapLccParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeUnwrapLccParams(hex"");
    }

    function test_decodeCollectLiquidityParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeCollectLiquidityParams(hex"");
    }

    function test_decodeUint256AndBool_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeUint256AndBool(hex"");
    }

    function test_decodeTakeParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeTakeParams(hex"");
    }

    function test_decodeUint256_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeUint256(hex"");
    }

    function test_decodeSyncParams_revertsOnShortInput() public {
        vm.expectRevert(MMCalldataDecoder.SliceOutOfBounds.selector);
        h.decodeSyncParams(hex"");
    }
}

