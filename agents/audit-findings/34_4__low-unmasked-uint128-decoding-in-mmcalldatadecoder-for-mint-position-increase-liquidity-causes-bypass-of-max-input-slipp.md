[Low] Unmasked uint128 decoding in MMCalldataDecoder for MINT_POSITION/INCREASE_LIQUIDITY causes bypass of max-input slippage caps

# Description

The PR added amount0Max/amount1Max ceilings to plain add-liquidity paths and enforces them via [_validateMaxIn](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L241-L251), but [MMCalldataDecoder assigns these uint128s using raw calldataload](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/MMCalldataDecoder.sol#L92-L93) without 128-bit masking. Non-ABI-conforming calldata with dirty high bits can make the maxima appear much larger, defeating the check and allowing unexpected LCC spend beyond the user’s intended cap. Standard ABI encoding is unaffected. This regression is introduced by the PR because the fields and decoders were newly added.

For plain [MINT_POSITION](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L106-L117) and [INCREASE_LIQUIDITY](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L119-L129), the PR introduced user-provided amount0Max/amount1Max limits and routes them into [_validateMaxIn](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L241-L251) after computing principalDelta. In MMCalldataDecoder, these uint128 parameters are [read via calldataload and assigned directly without masking](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/MMCalldataDecoder.sol#L131-L132). In Solidity/Yul, assigning a 256-bit word to a smaller type from assembly does not auto-truncate; nonzero upper 128 bits persist. A caller who crafts params where the low 128 bits encode a small limit but the high 128 bits are nonzero can cause [_validateMaxIn’s comparisons](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L241-L251) to treat the values as very large, bypassing the new protection. On plain adds, [negative deltas are funded from the MMPositionManager’s omnibus LCC ERC20 balance](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/modules/PositionManagerImpl.sol#L124-L132); if sufficient, the add succeeds with higher-than-intended spend; if not, the transfer fails and the transaction reverts. This is a correctness/safety regression introduced by the PR; typical ABI-encoded calls are unaffected because standard encoders zero-extend small integers.

# Severity

**Impact Explanation:** [Low] This is a correctness/safety regression of user slippage ceilings on plain add-liquidity; it does not enable theft or invariant breaks. Overspent value funds the caller’s own LP and, if balances are insufficient, the transaction reverts without partial loss.

**Likelihood Explanation:** [Low] Exploitation requires non-standard calldata (dirty high bits) and often a malicious/compromised integrator; standard ABI encoders zero-extend smaller integers. It may also depend on sufficient omnibus balances and market conditions to observe material effects.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Malicious aggregator/front-end constructs non-ABI-conforming params for [MINT_POSITION](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L106-L117)/[INCREASE_LIQUIDITY](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/MMPositionActionsImpl.sol#L119-L129) where amount0Max/amount1Max have small low 128 bits but nonzero high 128 bits. The user signs believing tight caps are enforced. On-chain, the unmasked decode bypasses _validateMaxIn and the add-liquidity spends more LCC from the MMPositionManager’s balances than intended; optional MEV price moves worsen spend.
#### Preconditions / Assumptions
- (a). Caller uses an untrusted aggregator or tooling that constructs non-ABI-conforming calldata with dirty high bits for uint128 fields
- (b). MMPositionManager holds sufficient LCC ERC20 to fund negative deltas; otherwise the tx reverts
- (c). User signs and submits the transaction produced by the aggregator
- (d). Optional: attacker performs price movement (e.g., sandwich) to increase required spend beyond the intended cap

### Scenario 2.
A sophisticated user scripts raw calldata (non-ABI encoding) for plain add-liquidity and inadvertently sets dirty high bits on amount0Max/amount1Max. The unmasked decode treats the caps as much larger, bypassing the check and spending more LCC from the manager’s balances than the user intended.
#### Preconditions / Assumptions
- (a). Caller self-builds raw calldata (not using standard abi.encode) and accidentally includes nonzero high 128 bits for amount0Max/amount1Max
- (b). MMPositionManager holds sufficient LCC ERC20 to fund negative deltas; otherwise the tx reverts

### Scenario 3.
Omnibus depletion effect: Following Scenario 1 or 2, the unexpected higher spend consumes more of the MMPositionManager’s LCC balance. A later user’s flow that implicitly relied on those balances reverts or requires additional funding, causing disruption to other users.
#### Preconditions / Assumptions
- (a). A prior transaction from Scenario 1 or 2 has occurred and consumed more omnibus LCC than intended
- (b). Multiple users rely on the MMPositionManager’s shared LCC balances with no per-user reservation
- (c). A later user attempts a flow that implicitly expects sufficient LCC on the manager

# Proposed fix

## MMCalldataDecoder.sol

File: `contracts/evm/src/libraries/MMCalldataDecoder.sol`

[Source](https://github.com/usherlabs/fiet-protocol/blob/2397e38a51197b47cb5116a6c9bc74f4b9d01d2e/contracts/evm/src/libraries/MMCalldataDecoder.sol)

```diff
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
-            amount0Max := calldataload(add(params.offset, 0x100))
-            amount1Max := calldataload(add(params.offset, 0x120))
+            amount0Max := and(calldataload(add(params.offset, 0x100)), 0xffffffffffffffffffffffffffffffff)
+            amount1Max := and(calldataload(add(params.offset, 0x120)), 0xffffffffffffffffffffffffffffffff)
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
-            amount0Max := calldataload(add(params.offset, 0x120))
-            amount1Max := calldataload(add(params.offset, 0x140))
+            amount0Max := and(calldataload(add(params.offset, 0x120)), 0xffffffffffffffffffffffffffffffff)
+            amount1Max := and(calldataload(add(params.offset, 0x140)), 0xffffffffffffffffffffffffffffffff)
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
             amount0Max := calldataload(add(params.offset, 0xe0))
             amount1Max := calldataload(add(params.offset, 0x100))
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
             amount0Max := calldataload(add(params.offset, 0x100))
             amount1Max := calldataload(add(params.offset, 0x120))
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
```
