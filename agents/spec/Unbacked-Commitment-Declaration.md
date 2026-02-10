# Unbacked Commitments (Position-Level Commitment Deficit)

The Fiet Protocol maintains a critical invariant: **all issued Liquidity Commitment Certificates (LCCs) must remain backed by** verified off-chain reserves (signal) **plus** on-chain settled liquidity.

Earlier designs described an explicit “unbacked commitment declaration” entrypoint. **The current on-chain implementation does not rely on a single declaration function.** Instead, it uses a **position-level insolvency gate** called `commitmentDeficit` that is:

- **Computed on-demand** via `checkpoint(..., withCommitment=true)` (permissionless).
- **Enforced economically** by inflating Required for Settlement (RfS) and enabling **immediate seizure** whenever a position has non-zero `commitmentDeficit`.

This document describes the _current_ mechanism, then elaborates the “single commit, multi-market leverage” scenario and the operational risk model required of market makers.

## The Backing Invariant (as enforced today)

For a given **position** $p$ that is linked to a **commit** $c$, the protocol enforces:

$$
\text{issuedUsd}(p) \le \text{signalUsd}(c) + \text{settledUsd}(p)
$$

**Where:**

- $\text{issuedUsd}(p)$: USD value of the position’s **effective** token amounts at the current pool price (derived from liquidity, ticks, and current price).
- $\text{signalUsd}(c)$: USD value of verified off-chain reserves stored in the commit’s `mmState` (computed from the `MarketMaker.State.reserves` array).
- $\text{settledUsd}(p)$: USD value of the position’s on-chain settled amounts (`pa.settled.token0/token1`).

**Important nuance:** $\text{signalUsd}$ is **commit-scoped** (shared across all positions linked to the commit), while $\text{issuedUsd}$ and $\text{settledUsd}$ are **position-scoped**.

## How unbackedness is detected (checkpointing)

Unbackedness is not “continuously” evaluated by the chain. Instead, it is **materialised** when someone calls:

- `VTSOrchestrator.checkpoint(commitId, positionIndex, true)`; or
- the equivalent router action through `MMPositionManager`.

When `withCommitment=true`, the checkpoint flow computes:

1. $\text{issuedUsd}(p)$ from the position’s effective amounts.
2. $\text{settledUsd}(p)$ from `pa.settled`.
3. $\text{signalUsd}(c)$ from the stored commit `mmState`, **unless the signal has expired**.

### Signal expiry behaviour

Signals are time-bounded. If a commit’s signal is expired at checkpoint time, it is treated as **zero backing** for the purpose of the invariant:

$$
\text{signalUsd}(c) := 0 \quad \text{if the commit’s signal is expired}
$$

Operationally, expiry is a _hard cliff_: a previously safe position can become underbacked at the next checkpoint if the signal is not renewed.

### Signals are sampled state (not live reserves)

The commit’s `mmState` is **stored on-chain** when a signal is committed/renewed, and $\text{signalUsd}(c)$ is computed from that stored state. This means:

- Reserve changes off-chain are not reflected on-chain until the commit is **renewed** with a newer proof (or the signal expires).
- The “contagion” effect across markets is therefore _realised_ at renewal/checkpoint time, not continuously.

## When a position becomes underbacked

A position becomes underbacked (relative to its commit) whenever:

$$
\text{issuedUsd}(p) > \text{signalUsd}(c) + \text{settledUsd}(p)
$$

Typical causes (adapted from earlier “unbacked declaration” write-ups, but expressed in the current position-level model):

- **Reserve depletion**: the market maker’s verified reserves (signal) fall, potentially due to:
  - withdrawals from reserve accounts
  - losses in external trading
  - regulatory action or account freezes
  - operational failures
- **Settlement demand spikes elsewhere (cross-market contagion)**: if a market maker funds large on-chain settlements for Market A from off-chain reserves, the next signal renewal may show a reduced \(\text{signalUsd}(c)\). Because \(\text{signalUsd}(c)\) is shared across all positions under the commit, other markets can become underbacked at their next checkpoint even if their own settled amounts did not change materially.
- **Price movements / range effects**: changes in pool price can increase $\text{issuedUsd}(p)$ even if reserves are unchanged.
- **Insufficient on-chain settlement**: if a position’s settled amounts are not maintained (e.g. the maker never posts more than the base requirement while issued exposure grows), \(\text{settledUsd}(p)\) may be too small to compensate for declines in \(\text{signalUsd}(c)\) or increases in \(\text{issuedUsd}(p)\).
- **Signal staleness/expiry**: even if reserves exist off-chain, an expired signal is treated as $0$ backing.

## Issuance-time safety: mint/increase is gated by the invariant

The invariant is enforced at the moment LCCs would be issued (for example, on liquidity increases). The protocol validates backing and **reverts** if insufficient backing would result.

Intuition:

- Market makers cannot issue new LCC exposure for a position unless **that position** is backed by
  $\text{signalUsd}(c) + \text{settledUsd}(p)$ at that time.
- This is a _per-position_ gate; it does not allocate a “budget” of $\text{signalUsd}$ across positions.

## The commitment deficit mechanism (position-level insolvency gate)

When checkpointing with commitment checks, the protocol computes:

$$
\text{backingUsd}(p) = \text{signalUsd}(c) + \text{settledUsd}(p)
$$

If $\text{issuedUsd}(p) \le \text{backingUsd}(p)$, the position is considered backed. Any existing `commitmentDeficit` is reduced (or cleared) according to the surplus backing.

If $\text{issuedUsd}(p) > \text{backingUsd}(p)$, the shortfall is:

$$
\text{deficitUsd}(p) = \text{issuedUsd}(p) - \text{backingUsd}(p)
$$

and the protocol derives a deficit ratio in basis points:

$$
\text{deficitBps}(p) = \left\lfloor \frac{\text{deficitUsd}(p) \cdot 10000}{\text{issuedUsd}(p)} \right\rfloor
$$

It then sets a **position-level** `commitmentDeficit` in token units by applying that ratio to the position’s effective amounts:

$$
\text{commitmentDeficit0}(p) \approx \text{eff0}(p) \cdot \frac{\text{deficitBps}(p)}{10000}
$$

$$
\text{commitmentDeficit1}(p) \approx \text{eff1}(p) \cdot \frac{\text{deficitBps}(p)}{10000}
$$

### Non-additive by default

Unlike earlier “declaration-based” drafts, the current model does **not** require additive deficit accumulation across repeated declarations. The `commitmentDeficit` is recalculated (and can be reduced/cleared) on each checkpoint based on the _current_ relationship between issued value and backing.

## Consequences of a non-zero commitment deficit

### 1) RfS inflation (hardens the settlement requirement)

RfS is computed from:

- a base settlement requirement (via `VTS_base` / `baseVTSRate`),
- cumulative deficits attributable to swaps, and
- the insolvency gate `commitmentDeficit`.

When `commitmentDeficit` is non-zero, it **inflates** the required settlement (clamped by the position commitment maxima), which tends to keep RfS open until the backing gap is closed.

#### RfS computation (explicit mechanics)

RfS can be understood per token \(A \in \{0,1\}\) as:

1. **Base requirement**:

$$
\text{baseReq}_A = \text{commitmentMax}_A(p) \cdot \text{baseVTSRate}_A
$$

1. **Swap-attributed deficit requirement**:

$$
\text{defReq}_A = \min(\text{cumulativeDeficit}_A(p),\ \text{commitmentMax}_A(p))
$$

1. **Gate by base rate**:

$$
\text{req}_A = \max(\text{baseReq}_A,\ \text{defReq}_A)
$$

1. **Inflate by commitment deficit (insolvency gate)**, clamped by commitment:

$$
\text{req}_A = \min(\text{commitmentMax}_A(p),\ \text{req}_A + \text{commitmentDeficit}_A(p))
$$

1. **RfS delta**:

$$
\text{rfsDelta}_A = \text{req}_A - \text{settled}_A(p)
$$

If \(\text{rfsDelta}\_A > 0\) for either token, RfS is open and settlement is required. If \(\text{rfsDelta}\_A < 0\), the magnitude represents withdrawable excess settlement (subject to additional clamping by available market liquidity).

### 2) Immediate seizure eligibility

If `commitmentDeficit.token0 > 0` or `commitmentDeficit.token1 > 0`, the position is treated as **immediately seizable**, bypassing the “checkpoint open + grace period elapsed” path.

This is the replacement for the earlier “force grace periods to elapse” mechanism: **the deficit itself is the seizable condition**.

### 3) Withdrawal restrictions (settled collateral)

Withdrawals of settled collateral are only possible when:

- RfS is closed; and
- there is excess settlement above the computed requirement.

If RfS is open, withdrawals revert. If RfS is closed, withdrawals are clamped to the withdrawable amount implied by RfS (negative delta).

In addition, even when a withdrawal is “allowed” by RfS, the actual withdrawal is clamped by **available market liquidity**: if the vault cannot immediately satisfy the full withdrawal, the protocol retroactively adjusts settlement accounting to match what was actually available.

## How the deficit is extinguished (rectification)

There are two main ways to eliminate `commitmentDeficit`:

### 1) Increase on-chain settlement

Depositing settlement into the position consumes:

1. swap-attributed cumulative deficits, then
2. `commitmentDeficit`, then
3. any remainder increases settled balance.

This ordering ensures insolvency is addressed before the position becomes over-settled.

### 2) Renew the signal (prove higher reserves)

If the market maker replenishes reserves off-chain and proves that via a new signal, then $\text{signalUsd}(c)$ rises and backing improves for **all positions** under the commit. At the next checkpoint, `commitmentDeficit` will be reduced or cleared accordingly.

Renewal also resets expiry, preventing the “signalUsd becomes 0” cliff.

#### Renewal authorisation constraints

Signal renewals enforce key invariants:

- **Owner immutability**: the signal’s `mmState.owner` must match the existing commit owner.
- **Advancer authorisation**: renewals are restricted to the designated `mmState.advancer` (the “effective sender” passed by the router), reducing proof sniping and preventing arbitrary third parties from rotating the commit’s state.

### 3) Reduce issued exposure (decrease/burn positions)

Because \(\text{issuedUsd}(p)\) is driven by liquidity and price/range, a market maker can also restore backing by **reducing the position’s issued exposure**:

- decreasing liquidity (partially closing exposure), or
- burning/closing a position entirely.

In practice, if a position has a non-zero `commitmentDeficit`, RfS inflation tends to force additional settlement first; nonetheless, reducing issued exposure is a core rectification path as it directly lowers the left-hand side of the invariant.

## Single-commit, multi-market leverage: scenario elaboration

### Setup

Assume:

- **Fund size (off-chain reserves)**: $100k
- **Single commit signal**: proves $100k reserves (so $\text{signalUsd}(c) = 100k$)
- **Markets**: 10
- **Target per-market issued exposure**: $50k in LCC value per market (per position)
- **Base VTS rate**: 1% (100 bps)

Per market, the base settlement requirement is:

$$
50{,}000 \cdot 1\% = 500
$$

Across 10 markets, total on-chain settlement posted is $\approx 10 \cdot 500 = 5{,}000$.

### Why the strategy is viable on-chain

For each position $p_i$, issuance-time validation (and subsequent checkpoint backing checks) use:

$$
\text{issuedUsd}(p_i) \le \text{signalUsd}(c) + \text{settledUsd}(p_i)
$$

With:

- $\text{issuedUsd}(p_i) \approx 50{,}000$
- $\text{signalUsd}(c) = 100{,}000$
- $\text{settledUsd}(p_i) \approx 500$

each position individually satisfies:

$$
50{,}000 \le 100{,}000 + 500
$$

So the protocol allows **10 positions in parallel** under one commit, even though the aggregate issued exposure is $500k. This is the intended “shared signal backing” model: a single reserve base supports multiple markets, with solvency enforced through the insolvency gate and seizure mechanics when backing falls.

### What creates the cross-market risk (contagion)

Because $\text{signalUsd}(c)$ is **shared**, a major reserve drawdown (for any reason, including settlement needs in one market) reduces backing for _all_ positions once the commit is renewed (or if it expires).

Example shock:

- Market A requires $60k additional settlement, funded from off-chain reserves.
- After this event, the next signal renewal proves reserves are now $40k.

Then for any other market $p_j$ with only base settlement ($500):

$$
50{,}000 \nleq 40{,}000 + 500
$$

so `commitmentDeficit` becomes non-zero for those positions at checkpoint, inflates RfS, and makes them immediately seizable.

## Risk model requirements for market makers

This design is viable, but it imposes clear operational requirements on market makers.

### 1) Manage signal freshness (renewal cadence)

- **Never let the commit expire.** Expiry collapses $\text{signalUsd}$ to $0$ for checkpointing purposes.
- Renew signals on a schedule and also **event-driven** when reserves materially change.
- Treat renewal capacity (proof generation cadence / nonce advancement) as a first-class reliability dependency.

### 2) Maintain a solvency buffer (off-chain)

If you are running a leveraged multi-market strategy, you must keep a buffer that covers:

- plausible settlement spikes in any one market,
- adverse price moves that increase issued value, and
- the cost of keeping other markets backed while you move capital.

The “$50k committed / $50k buffer” framing is a reasonable internal policy; the protocol will simply reflect whatever reserves are provable in `mmState.reserves`.

### 3) Monitor commitment health per position (not just per commit)

Because `commitmentDeficit` is computed per position, the maker should actively track:

- estimated $\text{issuedUsd}(p)$ per market (given price and range),
- current $\text{settledUsd}(p)$,
- current $\text{signalUsd}(c)$ (as last proven on-chain),
- implied slack: $\text{signalUsd}(c) + \text{settledUsd}(p) - \text{issuedUsd}(p)$.

### 4) Be deliberate about withdrawing settled collateral

Withdrawing excess settlement can help keep off-chain reserves afloat (and thus improve future $\text{signalUsd}$), but:

- withdrawals are only possible when RfS is closed and there is genuine excess,
- pulling settlement increases dependence on $\text{signalUsd}$ for that market, and
- aggressive withdrawal in multiple markets increases the chance that a subsequent signal drawdown causes widespread underbacking.

A common approach is to:

- keep markets at (or slightly above) their base requirement during normal conditions, and
- only withdraw meaningfully when you are actively de-risking (reducing issued exposure, narrowing markets, or increasing reserves).

### 5) Throttle issuance when reserves are tight

Because issuance is gated per position but signal is shared, makers should implement off-chain controls that:

- cap the number of concurrent markets under one commit,
- cap per-market issued exposure as a function of current reserves, and
- pause new issuance when reserve volatility or settlement volatility rises.

## Summary

The protocol’s current “unbacked commitment” handling is:

- **Position-level**: insolvency manifests as `commitmentDeficit` on each position.
- **Permissionless to materialise**: anyone can checkpoint and cause deficits to be computed.
- **Hard to ignore**: deficits inflate RfS and enable immediate seizure.
- **Compatible with multi-market leverage** under a single commit, provided market makers operate with strong signal renewal discipline, adequate reserve buffers, and careful settlement withdrawal policies.

## Implementation specification

### Design goal (O(1) intervention)

The protocol deliberately avoids any “commit-wide iterate over all positions” mechanism. Instead:

- **Checkpointing is position-specific** (constant work), and
- insolvency is represented as a **position-level** `commitmentDeficit` in token units.

This yields O(1) intervention costs per position, regardless of how many positions are linked to a commit.

### Architecture overview

At a high level, a checkpoint does two things:

1. **RfS state tracking**: mark whether the position is currently open or closed for settlement (used for grace-period based seizure).
2. **Commitment backing verification** (optional): if `withCommitment=true`, compute whether the position is backed by the commit’s signal plus its settled liquidity, and update `commitmentDeficit` accordingly.

The logical call chain is:

```text
MMPositionManager / router
  └─ VTSOrchestrator.checkpoint(commitId, positionIndex, withCommitment)
       ├─ VTSPositionLib.calcRFS(...)              // computes RfS delta + rfsOpen
       ├─ CheckpointLibrary.markCheckpoint(...)    // stores/open-closes RfS checkpoint
       └─ if withCommitment:
            └─ VTSCommitLib.checkpointWithCommitment(...)
```

### Core data structures

#### RfS checkpoint (per position)

Each position stores a checkpoint struct recording transitions into/out of RfS-open states and any grace period extensions.

Conceptually:

```solidity
struct RFSCheckpoint {
    uint256 timeOfLastTransition;
    bool isOpen;
    uint256 gracePeriodExtension0;
    uint256 gracePeriodExtension1;
}
```

#### Commitment deficit (per position)

The insolvency gate is `PositionAccounting.commitmentDeficit`:

```solidity
struct PositionAccounting {
    // ...
    TokenPairUint commitmentDeficit; // token0/token1 deficit in raw token units
}
```

### Checkpoint modes

Checkpoint runs in two modes:

- **Basic** (`withCommitment=false`): only updates RfS checkpoint state.
- **Full** (`withCommitment=true`): updates RfS checkpoint state **and** updates `commitmentDeficit` via backing checks.

### Commitment backing verification uses stored signal state

Backing verification does **not** verify a fresh LiquiditySignal on every checkpoint. Instead:

- `commitSignal` / `renewSignal` verify the signal and store `Commit.mmState` on-chain.
- `checkpointWithCommitment` reads the stored `mmState` and computes \(\text{signalUsd}(c)\) from it.

This keeps checkpointing permissionless and cheap, while making signal renewal cadence an explicit operational responsibility for market makers.

### Effective issued exposure (issuedUsd)

Issued amounts are computed from the position’s **effective token amounts** at the current price (not commitment maxima):

```solidity
(uint160 sqrtPriceX96, int24 currentTick,,) = poolManager.getSlot0(pos.poolId);
(uint256 eff0, uint256 eff1) = LiquidityUtils.calculateEffectiveTokenAmounts(
    sqrtPriceX96, currentTick, pos.tickLower, pos.tickUpper, int256(pos.liquidity)
);
uint256 issuedUsd = OracleUtils.lccPairValue(oracleHelper, currency0, eff0, currency1, eff1);
```

This ensures the backing check reflects the position’s live exposure at the current price.

### Deficit calculation and update (two cases)

Let:

$$
\text{backingUsd}(p) = \text{signalUsd}(c) + \text{settledUsd}(p)
$$

#### Case 1: sufficient backing (deficit clawback)

If \(\text{issuedUsd}(p) \le \text{backingUsd}(p)\), backing is sufficient. If a deficit exists, it is reduced (or cleared) based on surplus:

$$
\text{surplusUsd}(p) = \text{backingUsd}(p) - \text{issuedUsd}(p)
$$

- If \(\text{surplusUsd} \ge \text{currentDeficitUsd}\): clear deficit.
- Otherwise: reduce `commitmentDeficit0/1` proportionally to the surplus.

This “clawback” behaviour allows recovery from temporary backing shortfalls without requiring the maker to eliminate the full deficit in a single action.

#### Case 2: insufficient backing (set new deficit)

If \(\text{issuedUsd}(p) > \text{backingUsd}(p)\), compute:

$$
\text{deficitUsd}(p) = \text{issuedUsd}(p) - \text{backingUsd}(p)
$$

$$
\text{deficitBps}(p) = \left\lfloor \frac{\text{deficitUsd}(p) \cdot 10000}{\text{issuedUsd}(p)} \right\rfloor
$$

and set token-unit deficits proportionally to effective amounts:

$$
\text{commitmentDeficit0}(p) \approx \text{eff0}(p) \cdot \frac{\text{deficitBps}(p)}{10000}
$$

$$
\text{commitmentDeficit1}(p) \approx \text{eff1}(p) \cdot \frac{\text{deficitBps}(p)}{10000}
$$

### Seizability determination (two paths)

A position becomes seizable by either:

1. **Immediate seizure via commitment deficit**: if `commitmentDeficit0 > 0 || commitmentDeficit1 > 0`, the position is immediately seizable (this is the insolvency gate).
2. **Grace-period based seizure**: otherwise, if the RfS checkpoint is open and the grace period has elapsed.

### Settlement and deficit consumption ordering

When settlements are posted, the accounting nets in this order:

1. net against swap-attributed cumulative deficits,
2. net against `commitmentDeficit`, and only then
3. increase the position’s settled amounts.

This ensures settlements address insolvency pressure before creating “excess settlement” that could later be withdrawn.

### Events (observability)

Operationally relevant events include:

- `Checkpointed(commitId, positionIndex, checkpoint, withCommitment)`
- `GracePeriodExtended(...)`
- `PositionSettled(...)`
