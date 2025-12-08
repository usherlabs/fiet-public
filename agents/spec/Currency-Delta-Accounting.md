# Currency Delta Accounting Model

> **Module**: `DynamicCurrencyDelta`, `VTSCurrencyDelta`, `MMPositionManager`, `PositionManagerBase`  
> **Author**: Fiet Protocol  
> **Last Updated**: December 2024

## Overview

The Fiet Protocol employs a **split delta accounting model** that explicitly separates deltas by **target address** and **currency type**. This provides clear semantics for what is takeable versus what requires settlement through the VTS flow.

---

## The Split Delta Model

Currency deltas are tracked on different target addresses based on their source and type:

| Currency Type | Delta Target | Storage | Take Mechanism | Resolution |
|---------------|--------------|---------|----------------|------------|
| **Underlying** (balance syncs) | Locker (`msgSender`) | ERC20 in MMPM | Direct transfer | `_take()` |
| **Underlying** (settlement) | MMPM | Market liquidity | N/A | `_settle()` only |
| **LCC** (fees, position outputs) | MMPM | ERC-6909 claims on PoolManager | Burn claims → Take ERC20 | `_take()` |

### Key Principles

1. **Locker deltas** = Physical underlying balance from wrap/unwrap operations (takeable)
2. **MMPM LCC deltas** = Fee credits held as ERC-6909 claims (takeable via settle/take dance)
3. **MMPM underlying deltas** = Market liquidity claims (settle-only)

```
┌─────────────────────────────────────────────────────────────────────┐
│                        MMPositionManager                            │
│  ┌──────────────────────────┐    ┌──────────────────────────────┐  │
│  │  Locker Underlying Δ     │    │      MMPM LCC Δ              │  │
│  │  (synced from balance)   │    │  (fee credits as ERC-6909)   │  │
│  │  • take() reads this     │    │  • take() burns & takes      │  │
│  └──────────────────────────┘    └──────────────────────────────┘  │
│                                                                     │
│  ┌──────────────────────────────────────────────────────────────┐  │
│  │                    MMPM Underlying Δ                          │  │
│  │         (settlement obligations from positions)               │  │
│  │              • _settle() operates on this                     │  │
│  └──────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Core Operations

### 1. `sync()` — Credit Locker Delta from Balance Increase

**Purpose**: Establishes delta credit on the **locker** when physical token balance increases (e.g., after wrap/unwrap transformations).

**Behaviour**:

- **ONLY ADDS** to delta — never reduces existing credits
- Credits the difference between balance and current delta (when balance > delta)
- Syncs to **locker** (msgSender), NOT MMPM
- Does NOT affect position-derived claims on MMPM

**Implementation** (`MMPositionManager._syncBalanceToDeltas`):

```solidity
function _syncBalanceToDeltas(Currency currency) internal {
    // Sync to locker delta (msgSender), not MMPM
    vtsOrchestrator.syncFor(currency, msgSender());
}
```

**Why Locker Target**:  
Balance syncs represent physical tokens held by MMPM that should be takeable by the locker. By targeting the locker's delta, we ensure explicit separation from MMPM's settlement obligations.

---

### 2. `take()` — Split by Currency Type

**Purpose**: Withdraws tokens from delta with currency-type-aware handling.

**Behaviour by Currency Type**:

#### LCC Currency (fees, position outputs)
- **Delta on**: MMPM (`address(this)`)
- **Stored as**: ERC-6909 claims on PoolManager
- **Flow**: Burn claims → Take actual ERC20 → Debit MMPM delta

#### Underlying Currency (wrap/unwrap results)
- **Delta on**: Locker (`msgSender()`)
- **Stored as**: ERC20 in MMPM
- **Flow**: Debit locker delta → Direct ERC20 transfer

**Implementation** (`PositionManagerBase._take`):

```solidity
function _take(Currency currency, address to, uint256 maxAmount) internal {
    if (_isLCC(currency)) {
        // LCC: held as ERC-6909 claims on PoolManager, delta on MMPM
        uint256 credit = vtsOrchestrator.getFullCredit(currency, address(this));
        uint256 takeAmount = maxAmount == 0 ? credit : Math.min(credit, maxAmount);

        if (takeAmount > 0) {
            // 1. Burn ERC-6909 claims (releases LCC from PoolManager custody)
            currency.settle(poolManager, address(this), takeAmount, true);

            // 2. Take actual ERC20 LCC tokens from PoolManager
            currency.take(poolManager, to, takeAmount, false);

            // 3. Debit MMPM delta
            vtsOrchestrator.take(currency, address(this), to, takeAmount);
        }
    } else {
        // Underlying: held as ERC20 by MMPM, delta on locker
        address locker = msgSender();
        uint256 trueMaxAmount = Math.min(maxAmount, currency.balanceOfSelf());
        uint256 takeAmount = vtsOrchestrator.take(currency, locker, to, trueMaxAmount);

        currency.transfer(to, takeAmount);
    }
}
```

**Example Scenarios**:

**LCC Take (fees)**:
- LCC delta on MMPM = 100 (ERC-6909 claims)
- `take(lcc, recipient, 50)`:
  1. Burns 50 ERC-6909 claims
  2. Takes 50 actual LCC ERC20 to recipient
  3. Debits MMPM delta by 50

**Underlying Take (after unwrap)**:
- Locker underlying delta = 100 (synced from balance)
- `take(underlying, recipient, 50)`:
  1. Debits locker delta by 50
  2. Transfers 50 ERC20 to recipient

---

### 3. `_settle()` — Resolve Market Liquidity Claims

**Purpose**: The **ONLY** proper path to resolve position-derived delta obligations.

**Behaviour**:

- Routes through VTS settlement flow (`VTSPositionLib.onMMSettle`)
- Interacts with MarketVault for liquidity
- Updates position accounting (settled amounts, RFS state)
- Can handle both deposits (negative delta) and withdrawals (positive delta)

**Flow**:

```
_settle() 
  → vtsOrchestrator.onMMSettle()
    → settlePositionGrowths()
    → _updateSettlement()
    → MarketVault.tryModifyLiquidities()
```

---

## Delta Flow Diagrams

### Native ETH Wrap Flow (Split Model)

```
┌─────────────────────────────────────────────────────────────┐
│                    _wrapNative(amount)                      │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  1. take(native, amount) — from LOCKER delta                │
│     - Reads locker's native delta (not MMPM)                │
│     - Debits locker delta, capped to MMPM balance           │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. _wrap(amount)                                           │
│     - Deposits ETH to WETH9 contract                        │
│     - Physical: ETH balance ↓, WETH balance ↑               │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. syncFor(weth, msgSender()) — to LOCKER delta            │
│     - Credits LOCKER's WETH delta from new balance          │
│     - Locker delta increases to match WETH balance          │
└─────────────────────────────────────────────────────────────┘
```

### Native ETH Unwrap Flow (Split Model)

```
┌─────────────────────────────────────────────────────────────┐
│              _unwrapNative(amount, payerIsUser)             │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┴───────────────┐
            │                               │
     payerIsUser=true              payerIsUser=false
            │                               │
            ▼                               ▼
┌───────────────────────┐     ┌────────────────────────────┐
│ transferFrom(user)    │     │ take(weth, amount)         │
│ - Pull WETH from user │     │ - Reads LOCKER delta       │
│ - No delta change     │     │ - Debits locker delta      │
└───────────────────────┘     └────────────────────────────┘
            │                               │
            └───────────────┬───────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  _unwrap(amount)                                            │
│  - Withdraws from WETH9 contract                            │
│  - Physical: WETH balance ↓, ETH balance ↑                  │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  syncFor(native, msgSender()) — to LOCKER delta             │
│  - Credits LOCKER's native delta from new balance           │
│  - Locker delta increases to match ETH balance              │
└─────────────────────────────────────────────────────────────┘
```

### LCC Take Flow (ERC-6909 Claims)

```
┌─────────────────────────────────────────────────────────────┐
│               _take(lccCurrency, to, maxAmount)             │
│                     [_isLCC() returns true]                 │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  1. Read MMPM's LCC delta (ERC-6909 claim credits)          │
│     credit = vtsOrchestrator.getFullCredit(lcc, MMPM)       │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  2. currency.settle(poolManager, MMPM, amount, burn=true)   │
│     - Burns ERC-6909 claims from MMPM                       │
│     - Releases LCC from PoolManager custody                 │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  3. currency.take(poolManager, to, amount, useClaim=false)  │
│     - Takes actual LCC ERC20 tokens                         │
│     - Transfers to recipient                                │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  4. vtsOrchestrator.take(lcc, MMPM, to, amount)             │
│     - Debits MMPM's LCC delta                               │
└─────────────────────────────────────────────────────────────┘
```

### LCC Unwrap Flow

```
┌─────────────────────────────────────────────────────────────┐
│           _unwrapLCC(lccAddr, from, to, requested)          │
└─────────────────────────────────────────────────────────────┘
                            │
            ┌───────────────┴───────────────┐
            │                               │
      from=address(this)              from=user
            │                               │
            ▼                               ▼
┌───────────────────────┐     ┌────────────────────────────┐
│ take(lcc, requested)  │     │ transferFrom(user, amount) │
│ - Debit LCC delta     │     │ - Pull LCC from user       │
│ - Returns actual take │     │ - No delta change          │
└───────────────────────┘     └────────────────────────────┘
            │                               │
            └───────────────┬───────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  liquidityHub.unwrapTo(lcc, to, toUnwrap)                   │
│  - Burns LCC tokens                                         │
│  - Delivers underlying to recipient                         │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  if (to == address(this)):                                  │
│    sync(underlying)                                         │
│    - Credits underlying delta from new balance              │
└─────────────────────────────────────────────────────────────┘
```

### Position Modification Delta Flow

```
┌─────────────────────────────────────────────────────────────┐
│              touchPosition() in VTSPositionLib              │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Calculate requiredSettlementDelta                          │
│  - Based on position params and VTS configuration           │
│  - Represents market liquidity obligation                   │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  accountUnderlyingSettlementDeltaChange()                   │
│  - Sets underlying currency deltas on MMPM                  │
│  - These are MARKET CLAIMS, not physical balance            │
└─────────────────────────────────────────────────────────────┘
                            │
                            ▼
┌─────────────────────────────────────────────────────────────┐
│  Resolution: ONLY via _settle() → onMMSettle()              │
│  - Cannot be cleared by take() (balance capped)             │
│  - Cannot be cleared by sync() (only adds, never reduces)   │
└─────────────────────────────────────────────────────────────┘
```

---

## Key Invariants

### Invariant 1: `sync()` Targets Locker, Only Credits

```
sync(currency) → syncFor(currency, msgSender())
deltaChange >= 0
```

- Balance syncs always target the **locker** (not MMPM)
- Can only increase delta (establish credit from balance increase) or reduce debt
- NEVER reduces positive delta

### Invariant 2: LCC Deltas Are on MMPM as ERC-6909 Claims

```
LCC delta on MMPM = ERC-6909 claims on PoolManager
take(lcc) → settle(burn=true) → take(useClaim=false)
```

- LCC fee credits are held as ERC-6909 claims on PoolManager
- Taking LCCs requires the settle/take dance to convert claims to actual ERC20

### Invariant 3: Underlying Deltas Split by Source

```
Underlying from balance sync → Locker delta (takeable)
Underlying from settlement → MMPM delta (settle-only)
```

- Balance syncs create locker deltas (explicitly takeable)
- Settlement obligations stay on MMPM (only resolvable via `_settle()`)

### Invariant 4: Position Claims Survive sync/take

```
MMPM underlying delta (settlement) cannot be taken via _take()
Only _settle() can resolve MMPM underlying obligations
```

Position-derived deltas representing market liquidity claims are on MMPM and are never reduced by `_take()` operations (which reads locker delta for underlying).

### Invariant 5: Settlement Is The Resolution Path for Market Claims

```
MMPM underlying delta (market claims) → _settle() → VTS flow → MarketVault
```

The only way to resolve position-derived underlying obligations is through the settlement system.

---

## Example Scenarios

### Scenario 1: Simple Wrap/Unwrap (Split Model)

```
Initial State:
  - MMPM ETH balance: 100
  - Locker ETH delta: 0
  - MMPM WETH balance: 0
  - Locker WETH delta: 0

After _handleNativeValue() (receive 100 ETH via msg.value):
  - MMPM ETH balance: 100
  - Locker ETH delta: 100 (synced to locker via syncFor)

After _wrapNative(100):
  - take(ETH, 100): Locker ETH delta → 0
  - wrap: ETH balance → 0, WETH balance → 100
  - sync(WETH): Locker WETH delta → 100 (synced to locker)
  
Final State:
  - MMPM balances: ETH=0, WETH=100
  - Locker deltas: ETH=0, WETH=100
```

### Scenario 2: LCC Fee Take (ERC-6909 Claims)

```
Initial State:
  - Position earns 100 LCC in fees
  - MMPM LCC delta: 100 (ERC-6909 claims on PoolManager)

take(lcc, recipient, 50):
  1. settle(lcc, 50, burn=true)  → Burns 50 ERC-6909 claims
  2. take(lcc, 50, useClaim=false) → Takes 50 actual LCC ERC20
  3. vtsOrchestrator.take()  → Debits MMPM LCC delta by 50

Final State:
  - MMPM LCC delta: 50 (remaining ERC-6909 claims)
  - Recipient: 50 actual LCC ERC20
```

### Scenario 3: Position Creates Settlement Obligation

```
Initial State:
  - MMPM underlying balance: 50
  - Locker underlying delta: 50 (synced from wrap)
  - MMPM underlying delta: 0

After touchPosition() creates settlement obligation:
  - MMPM underlying balance: 50 (unchanged)
  - Locker underlying delta: 50 (unchanged)
  - MMPM underlying delta: 400 (market claim from position)

Attempted take(underlying, 200):
  - Reads LOCKER delta (50), not MMPM delta
  - trueMaxAmount = min(200, 50) = 50
  - Takes 50 from locker delta, transfers 50
  - Locker underlying delta: 0
  - MMPM underlying delta: 400 (untouched!)

Resolution via _settle(400):
  - Routes through VTS settlement flow
  - MarketVault provides liquidity
  - MMPM underlying delta: 0
```

### Scenario 4: Mixed Currency Types

```
State after operations:
  - Locker underlying delta: 100 (from unwrap)
  - MMPM LCC delta: 200 (fee credits as ERC-6909)
  - MMPM underlying delta: 300 (settlement obligation)

take(underlying, recipient, 150):
  - Reads locker delta (100)
  - Takes min(150, 100, balance) = 100
  - Locker underlying delta: 0
  - MMPM underlying delta: 300 (unchanged, settle-only)

take(lcc, recipient, 150):
  - Reads MMPM LCC delta (200)
  - Burns 150 ERC-6909 claims
  - Takes 150 actual LCC ERC20
  - MMPM LCC delta: 50
```

---

## Related Modules

- **`DynamicCurrencyDelta.sol`**: Core delta accounting library
- **`VTSCurrencyDelta.sol`**: Contract interface for delta operations (`sync`, `syncFor`, `take`)
- **`PositionManagerBase.sol`**: Abstract base with `_take()`, `_isLCC()`, and abstract `msgSender()`/`_liquidityHub()`
- **`MMPositionManager.sol`**: Position manager with wrap/unwrap/take/settle actions
- **`LCCFactory.sol`**: LCC token factory with `isLCC()` validation
- **`VTSPositionLib.sol`**: Position lifecycle and settlement logic
- **`VTSOrchestrator.sol`**: Coordination layer for VTS operations

---

## Security Considerations

1. **Explicit Target Separation**: By splitting deltas by target address (locker vs MMPM), the system explicitly separates takeable balances from settlement obligations. This is safer than relying on implicit balance caps.

2. **LCC Detection via Registry**: `_isLCC()` uses `LCCFactory.isLCC()` to validate LCC tokens, ensuring only registered LCCs go through the ERC-6909 settle/take flow.

3. **ERC-6909 Claim Management**: LCC fee credits are held as ERC-6909 claims on PoolManager. The `_take()` function properly burns claims before taking actual ERC20 tokens, preventing double-spending.

4. **No Phantom Credit Clearing**: `sync()` only increases delta; it never reduces positive delta. This preserves market liquidity claims on MMPM.

5. **Settlement Validation**: The `_settle()` flow includes RFS (Required for Settlement) checks to ensure positions meet settlement requirements before withdrawals.

6. **Delta Consistency**: The `assertNonZeroDeltas` modifier ensures batches complete with all deltas resolved, preventing stuck obligations.
