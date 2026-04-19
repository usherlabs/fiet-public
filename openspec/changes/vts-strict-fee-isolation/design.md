## Context

`tasks/TASK-25-remove-feelib-rebase-fee-isolation` is now replayed onto `origin/develop`, including the Medusa fuzz migration and the Phase 1 fee-capability quarantine. The replay kept `VTSFeeStorage` split out of base `VTSStorage`, but the ownership boundary is still too weak for the target architecture:

- `VTSOrchestrator` still owns `feeS`.
- `VTSOrchestrator` still exposes fee getters and `incrementCoverage`.
- `MarketFactory` still routes market-liquidity coverage through `VTSOrchestrator`.
- Base libraries still thread fee storage directly instead of going through a capability surface.

At the same time, the rebased branch now has constraints that the earlier carveout plan did not need to absorb:

- The default product line is explicitly quarantined when `coverageFeeShare == 0`.
- Medusa/FuzzEntry is the supported fuzz workflow on `develop`.
- Test harnesses and invariant docs already encode the replayed intermediate boundary and need a clean follow-up target.

## Goals / Non-Goals

**Goals:**
- Move all fee-era ownership behind a standalone `VTSFeeEngine` that implements `IVTSCapabilityEngine`.
- Reduce `VTSOrchestrator` to base VTS orchestration/state ownership only.
- Provide a stable `VTSStateLibrary` for fee-era reads of base denominators and position/pool state.
- Preserve current settlement ordering and default-quarantine behavior while changing the architectural boundary.
- Produce an implementation order that keeps the rebased Medusa/quarantine tree workable during the refactor.

**Non-Goals:**
- Reworking the economics of DICE/CISE/CSI, fee sharing, or quarantine policy.
- Changing the replayed branch’s current behavior in this proposal phase.
- Replacing the linked-library model wholesale or redesigning unrelated settlement/VRL features.
- Re-enabling fee capability by default on the conservative v1 path.

## Decisions

### 1. Fee ownership moves to a standalone `VTSFeeEngine`

`VTSFeeEngine` will own `VTSFeeStorage` and implement `IVTSCapabilityEngine`. `VTSOrchestrator` will stop owning `feeS` entirely.

Why this design:
- It gives the strictest separation between base VTS state and fee-era state.
- It avoids turning `MarketFactory` into a mixed routing/state-owner contract.
- It makes future fee-era quarantine or replacement easier because capability ownership is isolated.

Alternatives considered:
- Keep `feeS` on `VTSOrchestrator` and only hide it behind new methods.
  Rejected because the orchestrator would still be the fee owner, which is the exact boundary this task is trying to remove.
- Put fee storage directly on `MarketFactory`.
  Rejected because `MarketFactory` should route and configure markets, not become the storage owner for fee-era position/pool accounting.

### 2. Base reads flow through `VTSStateLibrary`

Introduce `VTSStateLibrary` as a narrow, stateless read layer over `VTSStorage` for fields such as `totalDeficitPrincipal`, `totalSettled`, `settled`, `cumulativeDeficit`, growth snapshots, and cumulative outflows.

Why this design:
- Fee-era logic still needs base denominators and snapshots, but that dependency should be read-only and explicit.
- A dedicated state library gives libraries and engines a stable surface instead of ad hoc storage-field reach-through.

Alternatives considered:
- Let `VTSFeeLib` and the new engine read `VTSStorage` directly everywhere.
  Rejected because it recreates the same tight coupling under a different owner.

### 3. `MarketFactory` routes coverage through capability hooks, not the orchestrator

`MarketFactory.useMarketLiquidity(...)` and related coverage entrypoints will call `IVTSCapabilityEngine.incrementCoverage(...)`. The capability engine will delegate to `VTSFeeLib`, which will use `VTSStateLibrary` for base denominator reads when needed.

Why this design:
- It removes the last direct fee-era ownership signal from `VTSOrchestrator`.
- It makes quarantine/feature-gating explicit at the capability boundary.

Alternatives considered:
- Keep `incrementCoverage` on `VTSOrchestrator` and forward internally.
  Rejected because it leaves the orchestrator as the fee-era ingress and preserves the wrong public contract.

### 4. Fee-aware lifecycle ordering stays explicit via pre/post hooks

The strict boundary will preserve current ordering by splitting capability hooks into explicit lifecycle phases:
- `onSettleGrowthsPreDeficit`
- `onPrincipalIncrease`
- `onSettleGrowthsPostDeficit`
- `onTouchPosition`

Why this design:
- The current fee semantics depend on ordering around deficit growth, DICE settlement, and touch processing.
- A single opaque callback would make ordering regressions easy to introduce and hard to audit.

Alternatives considered:
- Collapse everything into one generic “fee hook”.
  Rejected because it hides ordering-sensitive behavior and weakens reviewability.

### 5. The refactor must preserve Medusa/quarantine compatibility at every phase

The implementation sequence will update harnesses, fuzz surfaces, and docs alongside the architectural changes instead of treating them as cleanup.

Why this design:
- The replay already proved the main conflict surface is Medusa/fuzz and invariant documentation.
- Leaving harness/docs until the end would make verification misleading during the refactor.

Alternatives considered:
- Refactor protocol code first, then repair tests/docs.
  Rejected because the change is large enough that intermediate validation would become unreliable.

## Risks / Trade-offs

- [Boundary drift] The refactor could leave “temporary” fee helpers or getters on `VTSOrchestrator`, recreating the old ownership boundary under new names. -> Mitigation: spec explicit removals; reject partial compatibility shims unless they are time-boxed in tasks.
- [Ordering regressions] Moving fee hooks out of direct library calls can change CISE/deficit/DICE sequencing. -> Mitigation: explicit phased hooks plus targeted fee/position/quarantine tests before broad suite runs.
- [Harness churn] Medusa/FuzzEntry and harness callers can regress while signatures move. -> Mitigation: keep harness migration in the critical path; validate fuzz smoke commands on the rebased tree.
- [Deployment complexity] Two-engine wiring adds constructor and ownership complexity. -> Mitigation: document constructor responsibilities and deployment order in the design/spec/tasks, and update scripts as a first-class task.
- [Quarantine confusion] Engineers may infer that strict fee isolation re-enables fee capability by default. -> Mitigation: keep `coverageFeeShare == 0` default behavior explicit in specs and tasks.

## Migration Plan

1. Add the new interface and engine scaffolding without deleting the old behavior yet.
2. Introduce `VTSStateLibrary` and re-home `incrementCoverage` behind the capability engine.
3. Migrate lifecycle/touch hooks one library cluster at a time while preserving validation gates.
4. Remove residual fee ownership from `VTSOrchestrator` only after all callers route through the capability engine.
5. Update deployment wiring, docs, and harnesses, then run replay-targeted verification and Medusa smoke coverage.

Rollback strategy:
- Because this is a code refactor rather than a live deployment migration in this task, rollback is branch-level: revert to the replayed post-rebase branch state before the strict-isolation implementation commits.

## Open Questions

- Should `VTSFeeEngine` read base state via immutable orchestrator reference, inherited immutable state helper, or a narrower adapter contract?
- Which fee-era getters, if any, need a compatibility surface after `VTSOrchestrator` stops exposing them directly?
- Do any existing deployment or test environments assume orchestrator-only ownership in ways that require transitional tooling?
