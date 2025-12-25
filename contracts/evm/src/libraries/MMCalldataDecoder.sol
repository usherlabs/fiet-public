// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

import {Currency} from "v4-periphery/lib/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CalldataDecoder} from "v4-periphery/src/libraries/CalldataDecoder.sol";

/// @title Library for efficient calldata decoding in MMPositionManager
/// @notice Reduces bytecode by replacing abi.decode with assembly-based decoding
/// @dev Follows Uniswap v4 CalldataDecoder patterns for consistency
library MMCalldataDecoder {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice Mask used for offsets and lengths to ensure no overflow
    /// @dev No sane ABI encoding will pass in an offset or length greater than type(uint32).max
    uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;

    /// @notice Equivalent to SliceOutOfBounds.selector, stored in least-significant bits
    uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // High Priority Decoders (Position Operations)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev SETTLE_POSITION: (PoolKey, uint256, uint256, int128, int128, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return amount0 The amount of token0 to settle
    /// @return amount1 The amount of token1 to settle
    /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
    function decodeSettlePositionParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            int128 amount0,
            int128 amount1,
            bool usePositionManagerBalance
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
            // Minimum length: 0xa0 + 0x20*5 = 0x140
            if lt(params.length, 0x140) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            amount0 := calldataload(add(params.offset, 0xe0))
            amount1 := calldataload(add(params.offset, 0x100))
            usePositionManagerBalance := calldataload(add(params.offset, 0x120))
        }
    }

    /// @dev INCREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return liquidity The amount of liquidity to add
    function decodeIncreaseLiquidityParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint256 liquidity
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, liquidity
            // Minimum length: 0xa0 + 0x20*3 = 0x100
            if lt(params.length, 0x100) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            liquidity := calldataload(add(params.offset, 0xe0))
        }
    }

    /// @dev MINT_POSITION: (PoolKey, uint256, int24, int24, uint256)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return tickLower The lower tick of the position
    /// @return tickUpper The upper tick of the position
    /// @return liquidity The amount of liquidity to mint
    function decodeMintPositionParams(bytes calldata params)
        internal
        pure
        returns (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, uint256 liquidity)
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, liquidity
            // Minimum length: 0xa0 + 0x20*4 = 0x120
            if lt(params.length, 0x120) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            tickLower := calldataload(add(params.offset, 0xc0))
            tickUpper := calldataload(add(params.offset, 0xe0))
            liquidity := calldataload(add(params.offset, 0x100))
        }
    }

    /// @dev DECREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return amountToDecrease The amount of liquidity to remove
    function decodeDecreaseLiquidityParams(bytes calldata params)
        internal
        pure
        returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, uint256 amountToDecrease)
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amountToDecrease
            // Minimum length: 0xa0 + 0x20*3 = 0x100
            if lt(params.length, 0x100) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            amountToDecrease := calldataload(add(params.offset, 0xe0))
        }
    }

    /// @dev BURN_POSITION: (PoolKey, uint256, uint256)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    function decodeBurnPositionParams(bytes calldata params)
        internal
        pure
        returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex)
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex
            // Minimum length: 0xa0 + 0x20*2 = 0xe0
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
        }
    }

    /// @dev SEIZE_POSITION: (PoolKey, uint256, uint256, uint256, uint256, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return amount0 The amount of token0 for seizure
    /// @return amount1 The amount of token1 for seizure
    /// @return usePositionManagerBalance If true, tokens flow via MMPM balance and locker's deltas are adjusted
    function decodeSeizePositionParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint256 amount0,
            uint256 amount1,
            bool usePositionManagerBalance
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0, amount1, usePositionManagerBalance
            // Minimum length: 0xa0 + 0x20*5 = 0x140
            if lt(params.length, 0x140) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            amount0 := calldataload(add(params.offset, 0xe0))
            amount1 := calldataload(add(params.offset, 0x100))
            usePositionManagerBalance := calldataload(add(params.offset, 0x120))
        }
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Medium Priority Decoders (Delta Operations & Signal Management)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev INCREASE_LIQUIDITY_FROM_DELTAS: (PoolKey, uint256, uint256, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
    ///         If false, uses locker's direct credit.
    function decodeIncreaseFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            bool payerIsUser
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, payerIsUser
            // Minimum length: 0xa0 + 0x20*3 = 0x100
            if lt(params.length, 0x100) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            payerIsUser := calldataload(add(params.offset, 0xe0))
        }
    }

    /// @dev MINT_POSITION_FROM_DELTAS: (PoolKey, uint256, int24, int24, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return tickLower The lower tick of the position
    /// @return tickUpper The upper tick of the position
    /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
    ///         If false, uses locker's direct credit.
    function decodeMintFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (PoolKey calldata poolKey, uint256 tokenId, int24 tickLower, int24 tickUpper, bool payerIsUser)
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, payerIsUser
            // Minimum length: 0xa0 + 0x20*4 = 0x120
            if lt(params.length, 0x120) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            tickLower := calldataload(add(params.offset, 0xc0))
            tickUpper := calldataload(add(params.offset, 0xe0))
            payerIsUser := calldataload(add(params.offset, 0x100))
        }
    }

    /// @dev SETTLE_POSITION_FROM_DELTAS: (PoolKey, uint256, uint256, bool, bool, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return payerIsUser If true, use protocol delta (address(this)). If false, use locker delta (msgSender()).
    /// @return shouldTake If true, withdraw (consume credit). If false, deposit (settle credit into position).
    function decodeSettleFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (PoolKey calldata poolKey, uint256 tokenId, uint256 positionIndex, bool payerIsUser, bool shouldTake)
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, payerIsUser, shouldTake
            // Minimum length: 0xa0 + 0x20*4 = 0x120
            if lt(params.length, 0x120) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            payerIsUser := calldataload(add(params.offset, 0xe0))
            shouldTake := calldataload(add(params.offset, 0x100))
        }
    }

    /// @dev DECOMMIT_SIGNAL: (uint256)
    /// @param params The calldata bytes to decode
    /// @return tokenId The commitment NFT token ID
    function decodeDecommitSignalParams(bytes calldata params) internal pure returns (uint256 tokenId) {
        assembly ("memory-safe") {
            // tokenId: 1 slot (0x20)
            // Minimum length: 0x20
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            tokenId := calldataload(params.offset)
        }
    }

    /// @dev EXTEND_GRACE_PERIOD: (PoolKey, uint256, uint256, uint8, uint32, bytes)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return settlementTokenIndex The index of the settlement token
    /// @return verifierIndex The verifier index
    /// @return settlementProof The settlement proof bytes
    function decodeExtendGracePeriodParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint8 settlementTokenIndex,
            uint32 verifierIndex,
            bytes calldata settlementProof
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId (0x20), positionIndex (0x20), settlementTokenIndex (0x20), verifierIndex (0x20)
            // settlementProof offset pointer is at 0x120 (after all fixed-size params)
            // Minimum length: 0x120 + 0x20 (offset pointer) + 0x20 (length) = 0x160
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            settlementTokenIndex := calldataload(add(params.offset, 0xe0))
            verifierIndex := calldataload(add(params.offset, 0x100))

            // Read the offset pointer for settlementProof (dynamic bytes, index 5)
            // The offset pointer is stored at params.offset + 0x120 (after all fixed-size params)
            let proofOffsetPtr := add(params.offset, 0x120)
            let proofDataOffset := add(params.offset, and(calldataload(proofOffsetPtr), OFFSET_OR_LENGTH_MASK))

            // Read the length of the bytes
            let proofLength := and(calldataload(proofDataOffset), OFFSET_OR_LENGTH_MASK)

            // Set settlementProof calldata slice
            settlementProof.offset := add(proofDataOffset, 0x20)
            settlementProof.length := proofLength

            // Verify the bytes string fits within params
            if lt(add(params.length, params.offset), add(settlementProof.length, settlementProof.offset)) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }

    /// @dev COMMIT_SIGNAL: (bytes, address)
    /// @param params The calldata bytes to decode
    /// @return liquiditySignal The liquidity signal bytes
    /// @return owner The address to receive the commitment NFT (can be mapped constants)
    function decodeCommitSignalParams(bytes calldata params)
        internal
        pure
        returns (bytes calldata liquiditySignal, address owner)
    {
        assembly ("memory-safe") {
            owner := calldataload(add(params.offset, 0x20))
        }
        // Use CalldataDecoder.toBytes for dynamic bytes (index 0 = 1st argument)
        liquiditySignal = params.toBytes(0);
    }

    /// @dev RENEW_SIGNAL: (uint256, bytes)
    /// @param params The calldata bytes to decode
    /// @return tokenId The commitment NFT token ID
    /// @return data The liquidity signal bytes
    function decodeTokenIdAndBytes(bytes calldata params) internal pure returns (uint256 tokenId, bytes calldata data) {
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
        }
        // Use CalldataDecoder.toBytes for dynamic bytes (index 1 = 2nd argument)
        data = params.toBytes(1);
    }

    /// @dev CHECKPOINT: (uint256, uint256, bytes, bool)
    /// @param params The calldata bytes to decode
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The index of the position within the commitment
    /// @return data The liquidity signal bytes
    /// @return withCommitment Whether to run commitment backing checks
    function decodeCheckpointParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint256 positionIndex, bytes calldata data, bool withCommitment)
    {
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            positionIndex := calldataload(add(params.offset, 0x20))
            withCommitment := calldataload(add(params.offset, 0x40))
        }
        // Use CalldataDecoder.toBytes for dynamic bytes (index 2 = 3rd argument)
        data = params.toBytes(2);
    }

    // ═══════════════════════════════════════════════════════════════════════════════════════════
    // Low Priority Decoders (Simple Types)
    // ═══════════════════════════════════════════════════════════════════════════════════════════

    /// @dev UNWRAP_LCC: (address, uint256, address, bool)
    /// @param params The calldata bytes to decode
    /// @return lccAddr The LCC token address
    /// @return amount The amount to unwrap
    /// @return recipient The recipient address
    /// @return payerIsUser Whether the payer is the user
    function decodeUnwrapLccParams(bytes calldata params)
        internal
        pure
        returns (address lccAddr, uint256 amount, address recipient, bool payerIsUser)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x80) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            lccAddr := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
            recipient := calldataload(add(params.offset, 0x40))
            payerIsUser := calldataload(add(params.offset, 0x60))
        }
    }

    /// @dev COLLECT_AVAILABLE_LIQUIDITY: (address, address, uint256)
    /// @param params The calldata bytes to decode
    /// @return lcc The LCC token address
    /// @return recipient The recipient address
    /// @return maxAmount The maximum amount to collect
    function decodeCollectLiquidityParams(bytes calldata params)
        internal
        pure
        returns (address lcc, address recipient, uint256 maxAmount)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            lcc := calldataload(params.offset)
            recipient := calldataload(add(params.offset, 0x20))
            maxAmount := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev UNWRAP_NATIVE: (uint256, bool)
    /// @param params The calldata bytes to decode
    /// @return amount The amount to unwrap
    /// @return payerIsUser Whether the payer is the user
    function decodeUint256AndBool(bytes calldata params) internal pure returns (uint256 amount, bool payerIsUser) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            amount := calldataload(params.offset)
            payerIsUser := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev TAKE: (Currency, address, uint256)
    /// @notice Reuses Uniswap's decodeCurrencyAddressAndUint256 pattern
    /// @param params The calldata bytes to decode
    /// @return currency The currency to take
    /// @return recipient The recipient address
    /// @return maxAmount The maximum amount to take
    function decodeTakeParams(bytes calldata params)
        internal
        pure
        returns (Currency currency, address recipient, uint256 maxAmount)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            recipient := calldataload(add(params.offset, 0x20))
            maxAmount := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev WRAP_NATIVE: (uint256)
    /// @notice Reuses Uniswap's decodeUint256 pattern
    /// @param params The calldata bytes to decode
    /// @return amount The amount to wrap
    function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            amount := calldataload(params.offset)
        }
    }

    /// @dev SYNC: (Currency)
    /// @param params The calldata bytes to decode
    /// @return currency The currency to sync
    /// @dev owner is always address(this) (MMPM) and target is always msgSender() (locker)
    function decodeSyncParams(bytes calldata params) internal pure returns (Currency currency) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
        }
    }
}
