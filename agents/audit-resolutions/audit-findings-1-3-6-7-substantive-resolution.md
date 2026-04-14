# Audit findings #1, #3, #6, and #7 — substantive resolution

**Last updated:** 2026-04-13

This note records how the current implementation addresses **only** the following items under `agents/audit-findings/`:

1. [Finding #1 — path-dependent `commitmentMax`](../audit-findings/1__critical-path-dependent-commitmentmax-tracking-in-vtspositionlib-trackcommitment-causes-premature-rfs-closure-and-reduce.md)
2. [Finding #3 — weak decommit / stranded inactive `settled`](../audit-findings/3__high-weak-decommit-check-in-mmpositionmanager-decommitsignal-causes-permanent-fund-lock-from-inactive-positions.md)
3. [Finding #6 — overly strict signal validity with `requireLiveSignal=false`](../audit-findings/6__high-overly-strict-signal-validity-check-in-vtsorchestrator-requirelivesignal-false-still-requires-non-empty-reserves-ca.md)
4. [Finding #7 — boundary tick / `processSwap` tick reconstruction](../audit-findings/7__high-price-derived-tick-reconstruction-at-boundaries-in-vtsswaplib-processswap-causes-misattributed-growth-and-fee-cover.md)

**Conclusion (substance):** On the issues described in those four reports, the present codebase is **substantively resolved** as summarised below.

---

## Finding #1 — path-dependent `commitmentMax`

### Original issue

Incremental add/subtract of per-delta rounded commitment maxima could drift from the true maxima for **remaining live** Uniswap v4 position liquidity, with downstream effects on RFS, settlement gating, and related accounting.

### Resolution

`pa.commitmentMax` is derived **directly from live position liquidity** and the position tick range via a single `LiquidityUtils.calculateCommitmentMaxima(tickLower, tickUpper, liveLiquidity)` evaluation.

- **Implementation:** [contracts/evm/src/libraries/VTSPositionLib.sol](../../contracts/evm/src/libraries/VTSPositionLib.sol) — internal **`_trackCommitment`**, invoked from liquidity-changing touch paths (new position, increase, decrease) and other resynchronisation points that supply post-modify (or authoritative) live liquidity.
- **Invariant:** [contracts/evm/INVARIANTS.md](../../contracts/evm/INVARIANTS.md) — **COMMIT-00** documents the live-liquidity rule.

### Regression coverage

- [contracts/evm/test/libraries/VTSPositionLib.t.sol](../../contracts/evm/test/libraries/VTSPositionLib.t.sol) — dedicated **`_trackCommitment`** / `trackCommitmentFromLiveLiquidity` harness coverage, including narrow-range remaining-liquidity and fuzz `nonZeroThenZero` style cases.
- [contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol](../../contracts/evm/test/libraries/VTSPositionLib.mutation.unit.t.sol) — single-shot vs sequential live-liquidity totals aligned with formula maxima.
- **Harness:** [contracts/evm/test/libraries/harnesses/VTSPositionLibHarness.sol](../../contracts/evm/test/libraries/harnesses/VTSPositionLibHarness.sol) — **`trackCommitmentFromLiveLiquidity`** exposes **`VTSPositionLib._trackCommitment`** for tests.

### Verification (suggested)

From `contracts/evm`:

```bash
forge test --match-path test/libraries/VTSPositionLib.t.sol
forge test --match-path test/libraries/VTSPositionLib.mutation.unit.t.sol
```

---

## Finding #3 — weak decommit / inactive `settled` remnants

### Original issue

`_decommitSignal` could burn the commitment NFT when **`activePositionCount == 0`** while inactive positions still held withdrawable **`pa.settled`**, stranding value because MM paths require NFT-based authorisation.

### Resolution

1. **Commit-level counter:** [contracts/evm/src/types/Commit.sol](../../contracts/evm/src/types/Commit.sol) stores **`inactiveRemnantCount`** on the commit aggregate.
2. **O(1) maintenance:** [contracts/evm/src/libraries/VTSPositionLib.sol](../../contracts/evm/src/libraries/VTSPositionLib.sol) updates the counter via **`_syncInactiveRemnantAfterActiveTransition`** and **`_syncInactiveRemnantAfterSettledPairChange`** (no commit-wide scan).
3. **Decommit guard:** [contracts/evm/src/MMPositionManager.sol](../../contracts/evm/src/MMPositionManager.sol) **`_decommitSignal`** reads commit metadata (including **`inactiveRemnantCount`**, surfaced on **`IVTSOrchestrator.getCommit`**) and reverts **`Errors.CommitNotDrained`** when remnants remain, after **`CommitNotEmpty`** when any position is still active.

### Regression / integration coverage

- Unit and integration tests around inactive settled remainders and decommit expectations live in **`VTSPositionLib.t.sol`**, **`MMPositionManager.t.sol`**, and related MM action tests (see repository search for **`CommitNotDrained`** / **`inactiveRemnantCount`**).

### Verification (suggested)

From `contracts/evm`:

```bash
forge test --match-path test/MMPositionManager.t.sol
forge test --match-path test/libraries/VTSPositionLib.t.sol
```

---

## Finding #6 — empty reserves with `requireLiveSignal=false`

### Original issue

`isSignalValid` (and aligned lifecycle checks) treated **empty `mmState.reserves`** as invalid even when **`requireLiveSignal == false`**, which could brick renewal and recovery flows after a renewal that stored empty reserves.

### Resolution

Empty **reserves** are rejected **only** when a **live** signal is required.

- [contracts/evm/src/VTSOrchestrator.sol](../../contracts/evm/src/VTSOrchestrator.sol) — **`isSignalValid`** gates the non-empty reserves requirement on **`requireLiveSignal`**.
- [contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol](../../contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol) — shared validity helper aligned with the same semantics for MM / lifecycle entry points that use **`requireLiveSignal`**.

### Regression coverage

- [contracts/evm/test/VTSOrchestrator.t.sol](../../contracts/evm/test/VTSOrchestrator.t.sol) — empty-reserve **renewal** and **recovery-path** regressions (see tests that exercise **`requireLiveSignal`** and empty reserves).

### Verification (suggested)

From `contracts/evm`:

```bash
forge test --match-path test/VTSOrchestrator.t.sol
```

---

## Finding #7 — boundary tick / `processSwap` attribution

### Original issue

Deriving the pre-swap tick from **`sqrtPrice` alone** is ambiguous at Uniswap boundary states, and skipping the **final** boundary flip when a swap ends exactly on an initialised tick could desynchronise **`outside`** growth from canonical pool semantics, mis-attributing inside growth and downstream settlement / coverage.

### Resolution

1. **Authoritative pre-swap tick:** [contracts/evm/src/CoreHook.sol](../../contracts/evm/src/CoreHook.sol) snapshots **`slot0.tick`** before the swap and stores it in transient storage keyed by **`TransientSlots.TICK_BEFORE_SLOT`** ([contracts/evm/src/libraries/TransientSlots.sol](../../contracts/evm/src/libraries/TransientSlots.sol)).
2. **Plumbing:** [contracts/evm/src/VTSOrchestrator.sol](../../contracts/evm/src/VTSOrchestrator.sol) **`afterCoreSwap`** receives **`tickBefore`** from the hook and forwards it into swap processing.
3. **Swap processing:** [contracts/evm/src/libraries/VTSSwapLib.sol](../../contracts/evm/src/libraries/VTSSwapLib.sol) **`processSwap`** uses that **`tickBefore`** (documented on **`IVTSOrchestrator.afterCoreSwap`**) and applies the **final boundary flip** when the swap ends exactly on an initialised tick, matching intended Uniswap boundary behaviour.

### Regression coverage

- [contracts/evm/test/libraries/VTSSwapLib.t.sol](../../contracts/evm/test/libraries/VTSSwapLib.t.sol) — boundary / final-flip regression (see tests referencing boundary or **`tickBefore`** semantics).

### Verification (suggested)

From `contracts/evm`:

```bash
forge test --match-path test/libraries/VTSSwapLib.t.sol
```

---

## Cross-cutting verification

From `contracts/evm`, a full suite run is the strongest regression signal for interactions between hooks, orchestrator, lifecycle, and libraries:

```bash
forge test
```

---

## Note on superseded resolution drafts

An earlier draft, [scan-16-finding-1-commitmentmax-live-recompute-resolution.md](./scan-16-finding-1-commitmentmax-live-recompute-resolution.md), used naming that has since been normalised back to **`_trackCommitment`** while preserving the **live-liquidity recomputation** semantics described here. **Finding #1** should be read against this document and the current **`VTSPositionLib`** / **`INVARIANTS.md`** text.
