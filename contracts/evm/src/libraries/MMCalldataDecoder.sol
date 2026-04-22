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

    /// @notice Lower 128 bits only: assembly `calldataload` is 256-bit; narrow `uint128` fields must be canonicalised
    /// @dev Prevents non-ABI-conforming calldata (dirty high bits) from inflating max-in / min-out checks.
    uint256 constant UINT128_MASK = 0xffffffffffffffffffffffffffffffff;

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

    /// @dev INCREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256, uint128, uint128)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return liquidity The amount of liquidity to add
    /// @return amount0Max Maximum token0 principal spend (LCC leg; negative delta in `principalDelta`)
    /// @return amount1Max Maximum token1 principal spend
    function decodeIncreaseLiquidityParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, liquidity, amount0Max, amount1Max
            // Minimum length: 0xa0 + 0x20*5 = 0x140
            if lt(params.length, 0x140) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            liquidity := calldataload(add(params.offset, 0xe0))
            amount0Max := and(calldataload(add(params.offset, 0x100)), UINT128_MASK)
            amount1Max := and(calldataload(add(params.offset, 0x120)), UINT128_MASK)
        }
    }

    /// @dev MINT_POSITION: (PoolKey, uint256, int24, int24, uint256, uint128, uint128)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return tickLower The lower tick of the position
    /// @return tickUpper The upper tick of the position
    /// @return liquidity The amount of liquidity to mint
    /// @return amount0Max Maximum token0 principal spend (LCC leg)
    /// @return amount1Max Maximum token1 principal spend
    function decodeMintPositionParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, liquidity, amount0Max, amount1Max
            // Minimum length: 0xa0 + 0x20*6 = 0x160
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            tickLower := calldataload(add(params.offset, 0xc0))
            tickUpper := calldataload(add(params.offset, 0xe0))
            liquidity := calldataload(add(params.offset, 0x100))
            amount0Max := and(calldataload(add(params.offset, 0x120)), UINT128_MASK)
            amount1Max := and(calldataload(add(params.offset, 0x140)), UINT128_MASK)
        }
    }

    /// @dev DECREASE_LIQUIDITY: (PoolKey, uint256, uint256, uint256, uint128, uint128)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return amountToDecrease The amount of liquidity to remove
    /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 out after fee netting (see `LiquidityUtils.forwardedNonFeeLccAmount`; commit surplus is locker credit)
    /// @return amount1Min Minimum immediate non-fee LCC token1 out
    function decodeDecreaseLiquidityParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint256 amountToDecrease,
            uint128 amount0Min,
            uint128 amount1Min
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amountToDecrease, amount0Min, amount1Min
            // Minimum length: 0xa0 + 0x20*5 = 0x140
            if lt(params.length, 0x140) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            amountToDecrease := calldataload(add(params.offset, 0xe0))
            amount0Min := calldataload(add(params.offset, 0x100))
            amount1Min := calldataload(add(params.offset, 0x120))
        }
    }

    /// @dev BURN_POSITION: (PoolKey, uint256, uint256, uint128, uint128)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return amount0Min Minimum per-leg immediate non-fee LCC token0 when burning (same semantics as decrease min-out)
    /// @return amount1Min Minimum immediate non-fee LCC token1 out
    function decodeBurnPositionParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint128 amount0Min,
            uint128 amount1Min
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Min, amount1Min
            // Minimum length: 0xa0 + 0x20*4 = 0x120
            if lt(params.length, 0x120) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            amount0Min := calldataload(add(params.offset, 0xe0))
            amount1Min := calldataload(add(params.offset, 0x100))
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

    /// @dev INCREASE_LIQUIDITY_FROM_DELTAS: (PoolKey, uint256, uint256, uint128, uint128, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The position index within the commitment
    /// @return amount0Max The maximum amount of token0 to spend
    /// @return amount1Max The maximum amount of token1 to spend
    /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
    ///         If false, uses locker's direct credit.
    function decodeIncreaseFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            uint256 positionIndex,
            uint128 amount0Max,
            uint128 amount1Max,
            bool payerIsUser
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, positionIndex, amount0Max, amount1Max, payerIsUser
            // Minimum length: 0xa0 + 0x20*5 = 0x140
            if lt(params.length, 0x140) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            positionIndex := calldataload(add(params.offset, 0xc0))
            amount0Max := and(calldataload(add(params.offset, 0xe0)), UINT128_MASK)
            amount1Max := and(calldataload(add(params.offset, 0x100)), UINT128_MASK)
            payerIsUser := calldataload(add(params.offset, 0x120))
        }
    }

    /// @dev MINT_POSITION_FROM_DELTAS: (PoolKey, uint256, int24, int24, uint128, uint128, bool)
    /// @param params The calldata bytes to decode
    /// @return poolKey The pool key (calldata pointer)
    /// @return tokenId The commitment NFT token ID
    /// @return tickLower The lower tick of the position
    /// @return tickUpper The upper tick of the position
    /// @return amount0Max The maximum amount of token0 to spend
    /// @return amount1Max The maximum amount of token1 to spend
    /// @return payerIsUser If true, user consumes credit protocol owes them (MMPM delta).
    ///         If false, uses locker's direct credit.
    function decodeMintFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            uint256 tokenId,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            bool payerIsUser
        )
    {
        assembly ("memory-safe") {
            // PoolKey: 5 slots (0xa0), then tokenId, tickLower, tickUpper, amount0Max, amount1Max, payerIsUser
            // Minimum length: 0xa0 + 0x20*6 = 0x160
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            poolKey := params.offset
            tokenId := calldataload(add(params.offset, 0xa0))
            tickLower := calldataload(add(params.offset, 0xc0))
            tickUpper := calldataload(add(params.offset, 0xe0))
            amount0Max := and(calldataload(add(params.offset, 0x100)), UINT128_MASK)
            amount1Max := and(calldataload(add(params.offset, 0x120)), UINT128_MASK)
            payerIsUser := calldataload(add(params.offset, 0x140))
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

    /// @dev COMMIT_SIGNAL: (bytes liquiditySignal, bytes relayParams)
    /// @param params The calldata bytes to decode
    /// @return liquiditySignal The liquidity signal bytes
    /// @return relayParams Optional relayer auth params encoded as
    ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)`.
    ///         When non-empty, EIP-712 `RelayAuth.sender` is supplied as `sender` (`address(0)` means mint to
    ///         `mmState.owner`; otherwise must equal the batch locker / NFT recipient) while VRL `signer` remains
    ///         `mmState.owner`.
    function decodeCommitSignalParams(bytes calldata params)
        internal
        pure
        returns (bytes calldata liquiditySignal, bytes calldata relayParams)
    {
        assembly ("memory-safe") {
            // ABI encoding: (bytes liquiditySignal, bytes relayParams)
            // Minimum length for empty bytes fields:
            // - head (2 words): offset, offset => 0x40
            // - tails (2 length words)                => 0x40
            // total                               => 0x80
            if lt(params.length, 0x80) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
        // Use CalldataDecoder.toBytes for dynamic bytes (index 0 = 1st argument)
        liquiditySignal = params.toBytes(0);
        relayParams = params.toBytes(1);
    }

    /// @dev RENEW_SIGNAL: (uint256, bytes, bytes relayParams)
    /// @param params The calldata bytes to decode
    /// @return tokenId The commitment NFT token ID
    /// @return data The liquidity signal bytes
    /// @return relayParams Optional relayer auth params encoded as
    ///         `(uint256 deadline, uint256 authNonce, bytes authSig, address sender)` (renew: typed-data
    ///         `RelayAuth.sender` must be `address(0)`).
    function decodeTokenIdAndBytes(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, bytes calldata data, bytes calldata relayParams)
    {
        assembly ("memory-safe") {
            // ABI encoding: (uint256 tokenId, bytes data, bytes relayParams)
            // Minimum length for empty bytes fields:
            // - head (3 words): tokenId, offset, offset => 0x60
            // - tails (2 length words)                  => 0x40
            // total                                      => 0xa0
            if lt(params.length, 0xa0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            tokenId := calldataload(params.offset)
        }
        // Use CalldataDecoder.toBytes for dynamic bytes (index 1 = 2nd argument)
        data = params.toBytes(1);
        relayParams = params.toBytes(2);
    }

    /// @dev CHECKPOINT: (uint256, uint256, bool)
    /// @param params The calldata bytes to decode
    /// @return tokenId The commitment NFT token ID
    /// @return positionIndex The index of the position within the commitment
    /// @return withCommitment Whether to run commitment backing checks
    function decodeCheckpointParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint256 positionIndex, bool withCommitment)
    {
        assembly ("memory-safe") {
            // ABI encoding: (uint256 tokenId, uint256 positionIndex, bool withCommitment)
            // Minimum length: 3 words = 0x60
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            tokenId := calldataload(params.offset)
            positionIndex := calldataload(add(params.offset, 0x20))
            // Head layout: tokenId @ 0x00, positionIndex @ 0x20, withCommitment @ 0x40
            withCommitment := calldataload(add(params.offset, 0x40))
        }
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

    /// @dev COLLECT_AVAILABLE_LIQUIDITY: `(address lcc, uint256 maxAmount)` — **0x40** bytes; locker’s custodian scope.
    /// @param params The calldata bytes to decode
    /// @return lcc The LCC token address
    /// @return maxAmount The maximum amount to collect
    function decodeCollectLiquidityParams(bytes calldata params)
        internal
        pure
        returns (address lcc, uint256 maxAmount)
    {
        if (params.length != 0x40) {
            revert SliceOutOfBounds();
        }
        assembly ("memory-safe") {
            lcc := calldataload(params.offset)
            maxAmount := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev INITIALISE: no calldata words (must be exactly empty).
    function decodeInitialiseParams(bytes calldata params) internal pure {
        if (params.length != 0) {
            revert SliceOutOfBounds();
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
