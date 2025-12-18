## Tick‑Indexed Growth Accounting (VTS): A Technical Specification

### Abstract

This document specifies the **tick‑indexed growth accounting** mechanism implemented in VTS. The mechanism generalises Uniswap v3/v4’s fee accounting pattern—based on *global growth accumulators*, *per‑tick “outside” values*, and *per‑position checkpoints*—to support three VTS‑specific growth streams:

- **Deficit growth**: attributed outflows per unit active liquidity.
- **Inflow growth**: attributed inflows per unit active liquidity (net of LP/protocol fees).
- **Coverage‑usage growth**: attributed “coverage usage” per unit active liquidity (used to conditionally burn a share of LP fees when deficits are exercised).

The design guarantees that growth accrues to the *active tick at the moment it occurs* and is only claimable by liquidity that is **in‑range** at that moment. Positions that are out‑of‑range do not accrue additional growth; however, the growth continues to accrue globally and can be claimed by other positions intersecting the active tick.

### 1. Background and Provenance

VTS adopts the accounting approach used for fee growth in Uniswap v4 core:

- **Inside growth branching** (depends on current tick): see `Pool.getFeeGrowthInside()` in
  `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`.
- **Tick cross “outside flip”**: see `Pool.crossTick()` in the same file, which updates:
  \(\text{outside} \leftarrow \text{global} - \text{outside}\) (modulo \(2^{256}\)).

VTS re‑implements the same structure for its own growth types:

- Accrual to pool‑global Q128 accumulators: `contracts/evm/src/libraries/VTSSwapLib.sol`
- Tick outside flipping: `VTSSwapLib._flipOutside()`
- Inside growth calculation + settlement/checkpointing: `contracts/evm/src/libraries/VTSPositionLib.sol`

### 2. Notation

Let:

- \(p\) denote a pool.
- \(t\) denote the **current tick**.
- \([l, u)\) denote a position’s tick range, with lower tick \(l\) and upper tick \(u\).
- \(L_p(t)\) denote the pool’s **active in‑range liquidity** at tick \(t\) (i.e. the liquidity that is currently “in range”).
- \(L_i\) denote a particular position \(i\)’s liquidity (in Uniswap v4 core terminology, the position’s liquidity units).

All growth accumulators are expressed in **Q128 fixed‑point** (i.e. scaled by \(2^{128}\)):

- A growth value \(G\) represents “amount per liquidity unit” scaled by \(2^{128}\).

We use the following standard conversion:

\[
\text{amount} = \left\lfloor \frac{\Delta G \cdot L_i}{2^{128}} \right\rfloor
\]

### 3. State Variables

For each pool \(p\) and token \(k \in \{0,1\}\), VTS maintains three pool‑global growth accumulators (all Q128):

- \(G^{\mathrm{def}}_{p,k}\): `PoolAccounting.deficitGrowthGlobal`
- \(G^{\mathrm{in}}_{p,k}\): `PoolAccounting.inflowGrowthGlobal`
- \(G^{\mathrm{cov}}_{p,k}\): `PoolAccounting.coverageUseGrowthGlobal`

For each pool \(p\), tick \(x\), and token \(k\), VTS maintains per‑tick “outside” values (all Q128):

- \(O^{\mathrm{def}}_{p,x,k}\): `VTSStorage.deficitGrowthOutside[p][x]`
- \(O^{\mathrm{in}}_{p,x,k}\): `VTSStorage.inflowGrowthOutside[p][x]`
- \(O^{\mathrm{cov}}_{p,x,k}\): `VTSStorage.coverageUseGrowthOutside[p][x]`

For each position \(i\) (identified by `PositionId`) and token \(k\), VTS maintains per‑position checkpoint snapshots (all Q128):

- \(S^{\mathrm{def}}_{i,k}\): `PositionAccounting.deficitGrowthInsideLast`
- \(S^{\mathrm{in}}_{i,k}\): `PositionAccounting.inflowGrowthInsideLast`
- \(S^{\mathrm{cov}}_{i,k}\): `PositionAccounting.coverageUseGrowthInsideLast`

These snapshots are the analogue of Uniswap’s `feeGrowthInsideLast` checkpointing.

### 4. Growth Accrual on Swaps

Growth accrues during swaps in `VTSSwapLib.processSwap()`. The key property is that swaps are decomposed into **price movement segments** across the tick grid such that within each segment:

- The active liquidity \(L_p\) is constant.
- The price moves from a segment start \(\sqrt{P_a}\) to a segment end \(\sqrt{P_b}\).

For each segment, VTS computes raw amounts based on Uniswap’s swap maths (via `SqrtPriceMath`) and updates the relevant global accumulator by:

\[
\Delta G = \left\lfloor \frac{\text{amount} \cdot 2^{128}}{L_p} \right\rfloor
\]

Concretely:

- **Deficit growth** accrues on the token paid out by the pool (“amount out” for the segment).
- **Inflow growth** accrues on the token flowing into the pool (“amount in”) using a no‑fee input calculation (net of LP/protocol fees).

This ensures *accrual is indexed to the tick at which it occurred*, because \(L_p\) is the in‑range liquidity for that exact segment/tick interval. Positions that are not in range for that tick are excluded from \(L_p\) and therefore do not participate in that segment’s growth.

### 5. Tick Crosses and the “Outside Flip”

When the swap crosses an initialised tick \(x\), VTS flips the “outside” values for each growth type:

\[
O_{p,x,k} \leftarrow G_{p,k} - O_{p,x,k} \quad (\text{mod } 2^{256})
\]

This is implemented in `VTSSwapLib._flipOutside()` and is directly derived from Uniswap v4 core’s `Pool.crossTick()` implementation.

**Interpretation.** After each flip, \(O_{p,x,k}\) is always “growth on the other side of tick \(x\) relative to the current tick”. This property is what makes it possible to reconstruct “growth inside a position range” from:

- the global growth \(G_{p,k}\), and
- the two boundary tick outside values \(O_{p,l,k}\), \(O_{p,u,k}\),
- plus the current tick \(t\) (for branching).

### 6. Computing Growth Inside a Range (Uniswap‑Style Branching)

Define \(I_{p,[l,u),k}(t)\) as the all‑time “growth inside” the range \([l,u)\) at current tick \(t\).

In Uniswap‑style accounting, the formula branches on the relationship between the current tick and the range:

1. **Below range** (\(t < l\)):
\[
I = O_{p,l,k} - O_{p,u,k}
\]

2. **Above range** (\(t \ge u\)):
\[
I = O_{p,u,k} - O_{p,l,k}
\]

3. **In range** (\(l \le t < u\)):
\[
I = G_{p,k} - O_{p,l,k} - O_{p,u,k}
\]

All arithmetic is performed modulo \(2^{256}\) (implemented via `unchecked`), matching Uniswap v4 core’s `Pool.getFeeGrowthInside()`.

**Why branching is required.** Without branching, an out‑of‑range position’s computed “inside growth” can change while the tick remains outside the range, violating the key invariant:

- If a position is out‑of‑range, its inside growth should be stable (no new accrual) until price re‑enters its range.

VTS aligns to Uniswap by implementing this branching in `VTSPositionLib._growthInsideSingle()`, using the current tick obtained from `slot0`.

### 7. Settlement via Checkpointing (Delta‑and‑Checkpoint)

For each position \(i\), token \(k\), and growth type \(x \in \{\mathrm{def}, \mathrm{in}, \mathrm{cov}\}\), define:

- \(I^x_{i,k}\): current inside growth for that position’s range (computed using Section 6).
- \(S^x_{i,k}\): the position’s stored checkpoint snapshot.

The position’s incremental growth delta is:

\[
\Delta I^x_{i,k} = I^x_{i,k} - S^x_{i,k}
\]

The corresponding token‑denominated attributed amount is:

\[
A^x_{i,k} = \left\lfloor \frac{\Delta I^x_{i,k} \cdot L_i}{2^{128}} \right\rfloor
\]

Settlement then performs:

- Write back the checkpoint: \(S^x_{i,k} \leftarrow I^x_{i,k}\)
- Return \(A^x_{i,k}\)

This is implemented in `VTSPositionLib._deltaAndCheckpointGrowth()`.

#### 7.1. “Settle before modify liquidity” invariance

If a position’s liquidity changes from \(L_i\) to \(L'_i\), settlement **must occur before** the change. Otherwise, historical accrual \(\Delta I\) would be multiplied by \(L'_i\) and allow new liquidity to capture past growth.

VTS enforces this by calling `VTSOrchestrator.settlePositionGrowths()` in:

- `CoreHook._beforeAddLiquidity()`
- `CoreHook._beforeRemoveLiquidity()`

This mirrors the standard guidance for Uniswap fee accounting: update owed fees (by checkpointing) before mutating liquidity.

### 8. Semantics of the Three VTS Growth Types

VTS uses the same accounting skeleton for three distinct settlement effects.

#### 8.1. Deficit Growth → Outflows and Deficits

Deficit growth returns attributed outflow amounts \(A^{\mathrm{def}}_{i,k}\).

VTS:

- Increments `PositionAccounting.cumulativeOutflows` by \(A^{\mathrm{def}}_{i,k}\) to track the outflow window used later for fee‑sharing normalisation.
- Consumes `settled` balance first; any remaining shortfall is recorded into `cumulativeDeficit`.

This ensures that deficits represent the portion of outflows not yet covered by settlement.

#### 8.2. Inflow Growth → Settlement Increases (Netting Deficits First)

Inflow growth returns attributed inflow amounts \(A^{\mathrm{in}}_{i,k}\).

VTS applies this via `_updateSettlement()` which, by design:

- Nets any existing `cumulativeDeficit` first.
- Nets any `commitmentDeficit` (commitment‑scoped insolvency gate) next.
- Applies the remainder to increase `settled`, clamped by commitment maxima.

This yields a monotone “pay down debt then build coverage” flow.

#### 8.3. Coverage‑Usage Growth → Conditional LP Fee Burning

Coverage usage growth returns amounts \(A^{\mathrm{cov}}_{i,k}\), interpreted as “coverage was used” against this position.

VTS then applies `_applyCoverageBurn()`:

1. Clamp effective coverage to \(d + s\) (deficit + settled).
2. Burn fees only on the exercised deficit portion \(\min(A^{\mathrm{cov}}, d)\).
3. Compute LP fees since last fee checkpoint using Uniswap’s fee growth inside (`StateLibrary.getFeeGrowthInside`).
4. Scale the burn proportionally to the exercised share of the outflow window and a basis‑points parameter.

This links protocol fee‑sharing to *actual deficit coverage*, rather than to nominal coverage availability.

### 9. Modulo Arithmetic and Overflow Safety

Uniswap treats growth accumulators as elements of \(\mathbb{Z} / 2^{256}\mathbb{Z}\).

VTS adopts the same behaviour for inside/outside computations:

- `unchecked` subtraction is used to avoid reverting on wraparound.
- This is both safe and required for semantic alignment because the difference of two modulo values is well‑defined modulo \(2^{256}\).

Practical note: Although wrapping can occur in theory, \(2^{256}\) is sufficiently large that wraparound is extraordinarily unlikely under any plausible economic volume; nevertheless, the design is correct even if it occurs.

### 10. Worked Example (Single Token, Single Growth Type)

Consider a single token growth type with:

- Two boundary ticks \(l\) and \(u\).
- Current tick \(t\).
- Global growth \(G\).
- Outside values \(O_l\), \(O_u\).

Suppose at time \(T_0\), a position is created and we snapshot:
\[
S = I(t_0)
\]

Later at time \(T_1\), after some swaps and tick crosses, we compute the new inside growth:
\[
I(t_1) =
\begin{cases}
O_l - O_u & t_1 < l \\
O_u - O_l & t_1 \ge u \\
G - O_l - O_u & l \le t_1 < u
\end{cases}
\]

The amount owed to the position is:
\[
A = \left\lfloor \frac{(I(t_1) - S)\cdot L_i}{2^{128}} \right\rfloor
\]

and we checkpoint \(S \leftarrow I(t_1)\).

If \(t_1 < l\) (out of range below), and the price remains below the range, repeated calls to settle will keep returning \(A = 0\) because \(I\) will remain stable absent re‑entry—this is the central “no out‑of‑range accrual” property.

### 11. Implementation Map (Where to Read the Code)

- **Swap segmentation and global growth accrual**
  - `contracts/evm/src/libraries/VTSSwapLib.sol`:
    - `processSwap()`
    - `_accrueDeficitGlobalGrowth()`
    - `_accrueInflowGlobalGrowth()`
- **Tick cross flipping**
  - `VTSSwapLib._flipOutside()` (derived from Uniswap v4 core `Pool.crossTick()`)
- **Inside growth computation and branching**
  - `contracts/evm/src/libraries/VTSPositionLib.sol`:
    - `_growthInsideSingle()` (derived from Uniswap v4 core `Pool.getFeeGrowthInside()`)
    - `_growthInside()`
- **Delta + checkpoint settlement**
  - `VTSPositionLib._deltaAndCheckpointGrowth()`
- **Hook‑time fairness (settle before liquidity changes)**
  - `contracts/evm/src/CoreHook.sol`:
    - `_beforeAddLiquidity()`
    - `_beforeRemoveLiquidity()`
- **Uniswap v4 reference points**
  - `contracts/evm/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol`:
    - `getFeeGrowthInside()`
    - `crossTick()`
