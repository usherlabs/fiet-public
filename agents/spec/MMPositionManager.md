# MMPositionManager Actions Reference

> **Module**: `MMPositionManager`, `MMPositionActionsImpl`, `MMActions`  
> **Author**: Fiet Protocol  
> **Last Updated**: December 2024

## Overview

The `MMPositionManager` (MMPM) is the primary entry point for Market Maker (MM) commitment and position management. It handles commitment lifecycle operations locally (as ERC721 tokens) and delegates position operations to `MMPositionActionsImpl` via delegatecall.

Actions are organised into three categories based on their action codes:

- **Position Operations** (`0x00–0x09`): Delegated to `MMPositionActionsImpl`
- **Commitment Operations** (`0x20–0x24`): Handled locally in `MMPositionManager`
- **Utility Operations** (`0x40+`): Handled locally in `MMPositionManager`

---

## Action Routing

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MMPositionManager                            │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │  _handleAction(action, params)                                │  │
│  │                                                               │  │
│  │  action <= 0x09 (SETTLE_POSITION_FROM_DELTAS)                 │  │
│  │    → delegatecall to MMPositionActionsImpl                    │  │
│  │                                                               │  │
│  │  action >= 0x20 && action < 0x40                              │  │
│  │    → _handleCommitmentAction() (local)                        │  │
│  │                                                               │  │
│  │  action >= 0x40                                               │  │
│  │    → _handleUtilityAction() (local)                           │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Position Operations (0x00–0x09)

These actions are delegated to `MMPositionActionsImpl` and handle position-level liquidity management.

### SETTLE_POSITION (0x00)

Settles underlying assets to/from a position. This is the core settlement operation for depositing or withdrawing underlying tokens from position backing.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `amount0` | `int128` | Amount of token0 to settle (negative = deposit, positive = withdraw) |
| `amount1` | `int128` | Amount of token1 to settle (negative = deposit, positive = withdraw) |
| `usePositionManagerBalance` | `bool` | Token flow control (see below) |

**`usePositionManagerBalance` Semantics:**

| Value   | Token Flow              | Delta Accounting         |
| ------- | ----------------------- | ------------------------ |
| `true`  | MMPM ↔ Vault            | Locker's deltas adjusted |
| `false` | Locker ↔ Vault (direct) | No delta adjustment      |

**Flow:**

```
_settle()
  → vtsOrchestrator.onMMSettle()       // Update VTS accounting
  → transferFrom/transfer()             // Move underlying tokens
  → vault.modifyLiquidities()           // Update vault liquidity tracking
  → syncPairBalanceToDeltas() (if withdrawing with deltas)
```

---

### MINT_POSITION (0x01)

Mints a new position within an existing commitment. Creates a new liquidity position at the specified tick range.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `tickLower` | `int24` | Lower tick of the position range |
| `tickUpper` | `int24` | Upper tick of the position range |
| `liquidity` | `uint256` | Amount of liquidity units to mint |

**Flow:**

```
_mintPosition()
  → vtsOrchestrator.getCommit()         // Get next position index
  → poolManager.modifyLiquidity()       // Create position in pool
  → CoreHook callback                   // VTS processes position, issues LCCs
```

---

### INCREASE_LIQUIDITY (0x02)

Increases liquidity in an existing position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `tickLower` | `int24` | Lower tick of the position range |
| `tickUpper` | `int24` | Upper tick of the position range |
| `liquidity` | `uint256` | Amount of liquidity units to add |

---

### DECREASE_LIQUIDITY (0x03)

Decreases liquidity from an existing position.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `amountToDecrease` | `uint256` | Amount of liquidity units to remove |
| `amount0Min` | `uint128` | Minimum **immediate non-fee LCC** token0 forwarded to the queue custodian after netting `feeAdj` (see `LiquidityUtils.forwardedNonFeeLccAmount` / `PositionManagerImpl._handleLccBalanceIncrease`). This is **not** the same scalar as VTS queue principal (`callerDelta - feesAccrued` on the hook-time delta). |
| `amount1Min` | `uint128` | Minimum **immediate non-fee LCC** token1 forwarded (same semantics as `amount0Min`). |

---

### BURN_POSITION (0x04)

Burns (fully decreases) a position, removing all liquidity.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `amount0Min` | `uint128` | Minimum **immediate non-fee LCC** token0 when burning (same decrease/burn min-out semantics as `DECREASE_LIQUIDITY`). |
| `amount1Min` | `uint128` | Minimum **immediate non-fee LCC** token1 when burning. |

---

### SEIZE_POSITION (0x05)

Seizes a position that has failed to meet its backing requirements after the grace period. This is a third-party guarantor action.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `amount0` | `uint256` | Amount of token0 for seizure settlement |
| `amount1` | `uint256` | Amount of token1 for seizure settlement |
| `usePositionManagerBalance` | `bool` | Token flow control |

**Flow:**

```
_seizePosition()
  → vtsOrchestrator.onSeize()           // Validate grace period elapsed
  → TransientSlots.setSeizedPositionId() // Mark position as being seized
  → _settle()                            // Settle seizure amounts
  → _decreaseInternal()                  // Remove seized liquidity
```

---

### INCREASE_LIQUIDITY_FROM_DELTAS (0x07)

Increases liquidity using available delta credits. Calculates liquidity from available credits and optionally settles underlying tokens.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `tickLower` | `int24` | Lower tick of the position range |
| `tickUpper` | `int24` | Upper tick of the position range |
| `payerIsUser` | `bool` | Delta source control (see below) |

**`payerIsUser` Semantics:**

| Value   | Delta Target           | Behaviour                                                                                                                                     |
| ------- | ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| `true`  | MMPM (`address(this)`) | User consumes credit the **protocol owes them**. LCCs are issued, capitalised by underlying already owed to the MM. No additional settlement. |
| `false` | Locker (`msgSender()`) | Uses locker's direct credit. After increasing, **settles underlying tokens** into position (clears locker delta).                             |

**Flow (payerIsUser = true):**

```
_increaseFromDeltas(payerIsUser=true)
  → _getFullCreditPair(MMPM)            // Read protocol's owed credit
  → _getLiquidityFromDeltas()           // Calculate liquidity from credits
  → _increaseInternal()                 // Add liquidity (LCCs issued)
  // No settlement - credit already owed to user
```

**Flow (payerIsUser = false):**

```
_increaseFromDeltas(payerIsUser=false)
  → _getFullCreditPair(locker)          // Read locker's credit
  → _getLiquidityFromDeltas()           // Calculate liquidity from credits
  → _increaseInternal()                 // Add liquidity (LCCs issued)
  → _settle(-credit0, -credit1, true)   // Deposit underlying to back position
```

---

### MINT_POSITION_FROM_DELTAS (0x08)

Mints a new position using available delta credits. Same semantics as `INCREASE_LIQUIDITY_FROM_DELTAS`.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `tickLower` | `int24` | Lower tick of the position range |
| `tickUpper` | `int24` | Upper tick of the position range |
| `payerIsUser` | `bool` | Delta source control |

**Behaviour:** Same as `INCREASE_LIQUIDITY_FROM_DELTAS` — if `payerIsUser = false`, automatically settles underlying tokens after minting.

---

### SETTLE_POSITION_FROM_DELTAS (0x09)

Settles into a position using available delta credits. This action deposits underlying tokens owed to the user into their position backing.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `payerIsUser` | `bool` | Delta source control |

**`payerIsUser` Semantics:**

| Value   | Delta Target | Behaviour                                                                                                                 |
| ------- | ------------ | ------------------------------------------------------------------------------------------------------------------------- |
| `true`  | MMPM         | User settles funds **already owed to them**. No token movement — `onMMSettle` called directly for accounting update only. |
| `false` | Locker       | Settle using `usePositionManagerBalance = true` — moves tokens from MMPM balance to vault, debits locker's delta.         |

**Flow (payerIsUser = true):**

```
_settleFromDeltas(payerIsUser=true)
  → _getFullCreditPair(MMPM)            // Read protocol's owed credit
  → vtsOrchestrator.onMMSettle()        // Update accounting directly
  // No token transfer - settlement is purely accounting
```

**Flow (payerIsUser = false):**

```
_settleFromDeltas(payerIsUser=false)
  → _getFullCreditPair(locker)          // Read locker's credit
  → _settle(amount0, amount1, true)     // Transfer from MMPM to vault
```

---

## FromDeltas Actions — Detailed Semantics

The `FromDeltas` actions deserve special attention due to their nuanced delta handling:

### Delta Target Semantics

| Delta Target               | Positive Delta (Credit)                 | Meaning                                               |
| -------------------------- | --------------------------------------- | ----------------------------------------------------- |
| **MMPM** (`address(this)`) | Protocol **owes** external sources      | User can consume this credit without providing tokens |
| **Locker** (`msgSender()`) | External entity **is owed** by protocol | MMPM holds tokens that belong to locker               |

### Token Flow Diagrams

**payerIsUser = true (MMPM delta):**

```
┌────────────────────────────────────────────────────────────┐
│  Protocol owes user 100 (tracked on MMPM delta)            │
│                                                            │
│  _settleFromDeltas → onMMSettle() directly                 │
│  • No token transfer                                       │
│  • Accounting: Position backing ↑ 100, MMPM delta ↓ 100    │
└────────────────────────────────────────────────────────────┘
```

**payerIsUser = false (Locker delta):**

```
┌────────────────────────────────────────────────────────────┐
│  Locker has 100 credit (MMPM holds their tokens)           │
│                                                            │
│  _settleFromDeltas → _settle(usePositionManagerBalance=true)│
│  • MMPM transfers 100 to Vault                             │
│  • Locker delta debited by 100                             │
│  • Position backing ↑ 100                                  │
└────────────────────────────────────────────────────────────┘
```

---

## Commitment Operations (0x20–0x24)

These actions manage commitment lifecycle and are handled directly in `MMPositionManager`.

### COMMIT_SIGNAL (0x20)

Commits a liquidity signal and mints a commitment NFT to the **locker** (the batch caller). Params are ABI-encoded as `(bytes liquiditySignal, bytes relayParams)`; there is no separate owner word in the action payload (custody separation uses ERC-721 `transferFrom` after the batch if needed).

**Parameters:**

| Name | Type | Description |
|------|------|-------------|
| `liquiditySignal` | `bytes` | ABI-encoded liquidity signal to verify and record |
| `relayParams` | `bytes` | Optional relay authorisation blob; when empty, direct commit path is used |

**Flow:**

```text
_commitSignal()
  → vtsOrchestrator.commitSignal()      // Validate and record signal
  → _mint(locker, tokenId)              // Mint ERC721 NFT to msgSender() / locker
  → emit SignalCommitted(tokenId)
```

---

### RENEW_SIGNAL (0x21)

Renews an existing signal with new parameters. Updates the commitment without creating a new NFT.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `tokenId` | `uint256` | The commitment NFT token ID |
| `liquiditySignal` | `bytes` | New liquidity signal parameters |

---

### DECOMMIT_SIGNAL (0x22)

Decommits a signal and burns the commitment NFT. Requires all positions to be removed first.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `tokenId` | `uint256` | The commitment NFT token ID |

**Requirements:**

- Caller must be approved or owner of the NFT
- Commitment must have zero positions (`positionCount == 0`)

---

### CHECKPOINT (0x23)

Marks a checkpoint for a position, optionally running commitment backing checks and updating deficits.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `liquiditySignal` | `bytes` | Liquidity signal (required if `withCommitment = true`) |
| `withCommitment` | `bool` | Whether to run commitment backing checks |

**Note:** This action can also be called outside of a batch via the standalone `checkpoint()` functions.

---

### EXTEND_GRACE_PERIOD (0x24)

Extends the grace period for a commitment via settlement proof verification.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `poolKey` | `PoolKey` | The pool key identifying the market |
| `tokenId` | `uint256` | The commitment NFT token ID |
| `positionIndex` | `uint256` | The position index within the commitment |
| `settlementTokenIndex` | `uint8` | Index of the settlement token (0 or 1) |
| `verifierIndex` | `uint32` | The verifier index to use |
| `settlementProof` | `bytes` | The settlement proof data |

---

## Utility Operations (0x40+)

Currency management and token transformation operations.

### TAKE (0x40)

Takes currency from delta and transfers to recipient.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `currency` | `Currency` | The currency to take |
| `to` | `address` | Recipient address |
| `maxAmount` | `uint256` | Maximum amount to take (0 = max available) |

**Behaviour:**

- For **LCC currencies**: Burns ERC-6909 claims → Takes actual ERC20 → Debits MMPM delta
- For **underlying currencies**: Debits locker delta → Direct ERC20 transfer

---

### UNWRAP_LCC (0x41)

Unwraps LCC tokens to underlying asset via the LiquidityHub.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `lccAddr` | `address` | The LCC token address |
| `amount` | `uint256` | Amount to unwrap (0 = max available) |
| `recipient` | `address` | After `_mapRecipient`, must be the locker or `address(this)` (MMPM); arbitrary third-party recipients revert |
| `payerIsUser` | `bool` | Whether to pull from user wallet or use deltas |

**Policy:** Resolved payout address must be `msgSender()` (locker) or `address(this)` so on-behalf-of unwraps do not route underlying to unserviceable addresses. The Hub additionally rejects exempt/DEX/Hub payout targets (HUB-02B).

---

### WRAP_NATIVE (0x42)

Wraps native ETH to WETH. Takes from locker's native delta.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `amount` | `uint256` | Amount of ETH to wrap (0 = max available from deltas) |

**Flow:**

```
_wrapNative()
  → vtsOrchestrator.take(NATIVE, locker, amount)  // Debit native delta
  → _wrap(amount)                                  // ETH → WETH
  → _syncBalanceAsCredit(weth)                     // Credit WETH delta
```

---

### UNWRAP_NATIVE (0x43)

Unwraps WETH to native ETH.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `amount` | `uint256` | Amount of WETH to unwrap (0 = max) |
| `payerIsUser` | `bool` | Whether to pull from user wallet or use deltas |

**Flow:**

```
_unwrapNative()
  → [if payerIsUser] transferFrom(user, amount)
  → [else] vtsOrchestrator.take(weth, locker, amount)
  → _unwrap(amount)                                // WETH → ETH
  → _syncBalanceAsCredit(NATIVE)                   // Credit native delta
```

---

### COLLECT_AVAILABLE_LIQUIDITY (0x44)

Collects available liquidity from the settlement queue for a specific LCC and commitment bucket.

**Parameters:**
| Name | Type | Description |
|------|------|-------------|
| `lcc` | `address` | The LCC token address |
| `tokenId` | `uint256` | Commitment token ID custody bucket to release from |
| `maxAmount` | `uint256` | Maximum amount to collect |

---

## Entry Points

### modifyLiquidities

Primary batch execution entry point with deadline checking.

```solidity
function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable
```

### modifyLiquiditiesWithoutUnlock

Executes actions without acquiring a new PoolManager unlock.

```solidity
function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) external payable
```

### checkpoint (standalone)

Mark checkpoint outside of a batch (no PoolManager unlock required).

```solidity
function checkpoint(uint256 tokenId, uint256 positionIndex) external
function checkpoint(uint256 tokenId, uint256 positionIndex, bytes calldata liquiditySignal) external
```

---

## Related Modules

- **`MMActions.sol`**: Action code constants
- **`MMCalldataDecoder.sol`**: Efficient calldata decoding for action parameters
- **`MMPositionActionsImpl.sol`**: Position operation implementations
- **`VTSOrchestrator.sol`**: VTS state coordination
- **`MarketVault.sol`**: Per-market liquidity vault
- **`LiquidityHub.sol`**: LCC wrapping/unwrapping and settlement queue
- **`Settlement Queue Semantics.md`**: Queue ownership, settleability, and retry semantics
- **`Currency-Delta-Accounting.md`**: Delta target semantics documentation

---

## Security Considerations

1. **Approval Checks**: All position-modifying actions verify `assertApprovedOrOwner(msgSender(), tokenId)` before execution.

2. **Seizure Flow**: Seizure requires grace period to have elapsed (checked in `VTSOrchestrator.onSeize`) and uses transient storage to track the seized position.

3. **Delta Target Semantics**: Proper handling of `payerIsUser` ensures credits are consumed from the correct delta target, preventing unintended token flows.

4. **Batch Atomicity**: All actions within a batch execute atomically via PoolManager unlock.

5. **NFT Transfer Protection**: Commitment NFT transfers are blocked while PoolManager is unlocked (`onlyIfPoolManagerLocked`).
