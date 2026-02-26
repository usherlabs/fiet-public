# MEV and Adversarial Ordering — Risk Posture (Fiet Protocol)

## Summary

Fiet’s core pool is a standard Uniswap v4 concentrated-liquidity pool (CLMM). As a result, **Fiet inherits the same MEV/adversarial-ordering risks as a typical Uniswap-style AMM**: block producers and searchers can reorder transactions, insert swaps, and sandwich “victim” actions. This affects any mechanism that depends on **spot price paths** and **range-based accounting**.

This protocol version **does not include native MEV mitigation mechanisms** (eg in-protocol auctions, enforced private routing, or enforced batching). Instead, it:

- treats the resulting risks as execution-environment realities (especially on public-mempool chains),
- bounds them by requiring real swaps (fees + price impact) to influence spot-derived accounting, and
- provides operational levers such as **grace periods** and (optionally) **externally verified attestations** to extend grace during adverse execution conditions.

This document explains:

- **what an adversary can and cannot do** to Fiet’s VTS mechanics via ordering,
- **why “every swap runs accounting” is true but not sufficient** to eliminate ordering impacts,
- practical **downside impacts for market makers (MMs)**, and
- **mitigation approaches** ranging from “execution-layer” protections (private routing) to optional protocol-level dampeners (TWAP gating for specific triggers).

## Threat model (what we assume)

- **Adversarial ordering exists**: transactions can be reordered, withheld, or surrounded by other transactions within a block.
- **Sandwiching exists**: an adversary can insert swaps before and after a victim action if the action is publicly visible pre-inclusion.
- **Adversaries can trade**: influence is exerted by executing real swaps against the core CLMM, paying fees and price impact (sometimes partially recapturable if the adversary is also an LP).
- **The core pool remains the sole execution curve for proxy-originated swaps** under `MKT-05` (proxy AMM execution is neutralised). This document focuses on MEV impacts on the **core** pool and VTS mechanics.

## What’s actually MEV-sensitive in Fiet

### Code touchpoints (where to look in the implementation)

- **Swap hook → global growth accrual**
  - `contracts/evm/src/CoreHook.sol` (`_afterSwap`)
  - `contracts/evm/src/VTSOrchestrator.sol` (`afterCoreSwap`)
  - `contracts/evm/src/libraries/VTSSwapLib.sol` (`processSwap`)

- **Position “touch” → crystallise growth into per-position state**
  - `contracts/evm/src/libraries/VTSPositionLib.sol` (`settlePositionGrowths`, `calcRFS`, `getRFS`)
  - `contracts/evm/src/VTSOrchestrator.sol` (`checkpoint`, MM settlement entrypoints)

- **Grace / seizure gating**
  - `contracts/evm/src/libraries/Checkpoint.sol` (`isSeizable`, `extendGracePeriod`)

- **Settlement-proof / attestation channel for grace extension**
  - `contracts/evm/src/VRLSettlementObserver.sol` (`verifySettlementProof`)
  - `contracts/evm/src/interfaces/ISettlementVerifier.sol` (verifier interface)

### 1) Swap accounting is deterministic per swap, but *position state* is realised on “touch”

Every swap on the core pool triggers VTS swap processing (`CoreHook.afterSwap → VTSOrchestrator.afterCoreSwap → VTSSwapLib.processSwap`), accruing **global** deficit and inflow growth along the realised price path.

However, global accrual is only **realised into an individual position’s accounting** when that position is “touched” (eg checkpointing, settlement, or liquidity modification flows that call `settlePositionGrowths`). This is the key ordering sensitivity:

- MEV cannot stop the swap hook from running, but it can **choose which swaps occur immediately before a victim touch**, changing the interval of growth that is crystallised into that victim’s position.

This is analogous to Uniswap fee accrual: fees accrue continuously, but what a position “realises” depends on when it interacts and whether it was in-range during the accrual interval.

### 2) Range-based attribution is inherently sensitive to price paths

Fiet uses Uniswap-style “inside growth” accounting to attribute deficit/inflow growth to positions only while they are in-range. Because “in-range” depends on the tick during the accrual interval, an adversary that can move tick across a position’s bounds around a victim touch can change:

- how much deficit/inflow growth becomes “inside” for the victim, and
- which positions bear/receive the realised growth over that interval.

This does not mean the accounting is incorrect — it is faithful to the realised path — but it does mean an adversary can **engineer** the realised path around a sensitive action.

### 3) Which VTS mechanics can be influenced by ordering

Ordering can influence VTS outcomes whenever a call path both:

- settles or consumes growth (`settlePositionGrowths`), and/or
- computes and records state transitions using those freshly settled values (eg RfS open/close checkpoints, grace timing).

Key examples:

- **`checkpoint()`**: settles growth then computes RfS state and marks the position’s checkpoint from that snapshot.
- **MM settlement flows** (`onMMSettle` and related): settle growth, compute RfS clamps, then apply settlement deltas subject to position state and available liquidity.
- **Liquidity modification**: by design, growth is checkpointed *before* liquidity changes so new liquidity cannot claim historical accrual. This is correct, but it also means “touch timing” matters.

## Downside impacts for MMs (practical, not theoretical)

### 1) RfS can remain open longer than expected (and can be re-opened)

If an MM attempts to settle to close RfS, an adversary can sandwich by inserting swaps that crystallise additional deficit into the MM’s position at the next touch. Operationally, this can mean:

- the MM needs to settle more than expected to close RfS, or
- RfS closes briefly but is later re-opened by subsequent adverse-ordered touches.

Grace windows reduce the “seizure immediacy” impact, but they do not remove the execution risk: they **buy time**.

### 2) Capital efficiency degradation / “buffer settlement”

To reduce the probability of RfS being re-opened under adverse ordering, MMs may choose to maintain larger settled buffers (closer to their maxima), reducing capital efficiency.

### 3) Operational and UX risk

- **Keeper churn**: more frequent retries/checkpoints/settlement attempts.
- **Non-deterministic UX** in public mempools: “I settled, why is RfS still open?” is a plausible user experience if the transaction was sandwiched or otherwise adversely ordered.

### 4) Cost recapture / externalities (fees are not a complete antidote)

It is true that influencing accounting requires real swaps (fees + price impact). However:

- the **entity paying swap fees** need not be the same entity bearing the **realised deficit growth**, because deficit growth is attributed to in-range positions over the engineered path; and
- adversaries can sometimes **subsidise** manipulation costs if they are also LPs (fee recapture), or if the execution environment provides rebates or other incentives.

In short: “manipulation is not free” is correct, but “fees fully neutralise incentives” is not always true.

## Current posture (this version)

- **We inherit standard Uniswap-style MEV/adversarial ordering surfaces** (sandwiching around sensitive actions in a public mempool).
- **We do not yet incorporate native MEV mitigation** (no in-protocol auction/batching, no enforced private routing, no protocol-level TWAP gating for RfS decisions).
- We rely on:
  - real manipulation costs (fees + price impact),
  - operational grace windows, and
  - execution-layer best practice (private routing) where available.

## Mitigation approaches

Mitigations fall into two categories: **execution-layer protections** (reduce adversarial ordering) and **protocol-level dampeners** (reduce sensitivity when adversarial ordering exists).

### A) Execution-layer protections (recommended on public mempools)

- **Private transaction routing for sensitive actions** (checkpointing, settlement, liquidity modifications that crystallise growth).
  - This reduces or removes the sandwich surface by eliminating public pre-trade visibility.
- **Solver/auction execution for sensitive actions** (optional).
  - Instead of submitting directly to a public mempool, MMs can route via an auction/solver layer that can batch execution and reduce toxic ordering.

These mitigations are external to the protocol but are the most direct way to address sandwiching in adversarial mempools.

### B) Protocol-level dampeners (optional, with semantic/UX trade-offs)

- **TWAP gating for specific triggers**:
  - Keep realised-path growth accounting, but use TWAP-derived signals for specific risk gates (eg when opening/closing RfS, or when enabling certain sensitive flows).
  - Trade-off: introduces lag and new parameters; can be gamed over longer windows.

- **Sequencing constraints for sensitive actions**:
  - Examples include minimum-delay guards, action-specific cool-downs, or restricting when checkpoints can be marked relative to swaps.
  - Trade-off: reduces composability and can create “liveness” constraints.

- **Bounded per-touch crystallisation** (advanced):
  - Cap the amount of growth that can be realised into position state in a single touch.
  - Trade-off: more complex accounting, potential new incentives, and “deferred” state that can surprise integrators.

### C) Grace extension via externally verified attestations (settlement-proof channel)

Fiet already supports grace extension via externally verified settlement proofs (see `CheckpointLibrary.extendGracePeriod` and `VRLSettlementObserver.verifySettlementProof`).

This can be re-used as an **attestation channel** to extend grace in adversarial scenarios (eg where a credible data source observed sandwiching around an MM action). One practical design is:

- an external prover (eg zkTLS-enabled) queries reputable data sources with mempool observability,
- produces an attestation that encodes a specific condition (eg “MM settle was sandwiched in the same block”),
- an allowlisted on-chain verifier validates the attestation and returns `true`, and
- the protocol extends the grace period for the relevant settlement token.

Important notes:

- this is an **oracle/attestation trust model**, not a trustless on-chain proof of mempool facts;
- allowlisting and non-replay protection exist at the settlement observer layer; and
- the condition should be narrowly specified to avoid abuse (eg rate limiting, scope binding to pool/token/position, and conservative extensions).

## Recommended integrator guidance (short-form)

On public-mempool chains:

- assume adversarial ordering exists,
- submit sensitive MM actions via private routing where possible,
- treat grace extensions as an operational tool (especially if integrating attestation-based extensions),
- do not assume `checkpoint()` deterministically flips RfS in a hostile ordering environment; treat it as “best effort based on the realised path up to that inclusion”.

## Appendix: glossary

- **MEV**: Maximal/Maximum Extractable Value; profit from transaction ordering/manipulation.
- **Sandwich**: attacker trades before and after a victim to move price and profit (or to induce a victim-side state change).
- **Touch**: any protocol interaction that realises global growth into per-position state (eg settlement, checkpoint, liquidity modifications).

