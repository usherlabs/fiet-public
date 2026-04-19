## 1. Engine Boundary

- [ ] 1.1 Add `IVTSCapabilityEngine` with the explicit fee lifecycle and coverage hook surface required by the strict boundary.
- [ ] 1.2 Add `VTSFeeEngine` and move `VTSFeeStorage` ownership into it.
- [ ] 1.3 Add `VTSStateLibrary` for base `VTSStorage` reads needed by fee-era logic.

## 2. Coverage and Routing

- [ ] 2.1 Move `incrementCoverage` implementation into `VTSFeeLib` behind the capability engine.
- [ ] 2.2 Update `MarketFactory` to call `IVTSCapabilityEngine.incrementCoverage(...)`.
- [ ] 2.3 Remove `incrementCoverage` and fee-era ownership/getters from `VTSOrchestrator` and `IVTSOrchestrator`.

## 3. Library Decoupling

- [ ] 3.1 Refactor `VTSPositionLib` to call capability hooks instead of direct fee-library/state threading.
- [ ] 3.2 Refactor `VTSCommitLib`, `VTSPositionMMOpsLib`, and `VTSLifecycleLinkedLib` to depend on the capability engine/state-library boundary.
- [ ] 3.3 Ensure `VTSOrchestrator` only routes base lifecycle/state operations after the decoupling is complete.

## 4. Harnesses, Docs, and Verification

- [ ] 4.1 Update fee/position/quarantine harnesses and Medusa fuzz callers to the new boundary.
- [ ] 4.2 Update invariants, isolation docs, and deployment notes to describe the strict owner split.
- [ ] 4.3 Run `forge build`, targeted fee/position/quarantine tests, and Medusa/fuzz smoke validation on the refactored branch.

## Implementation Notes

- 2026-04-19: The active source of truth changed away from this capability-engine proposal. Current implementation follows `origin/refactor/disable-feelib` plus `.cursor/plans/fee_disablement_plan_4ed47903.plan.md`, with the newer tip commit `41b8a60a` treated as authoritative on top of `f5856ec4`.
- 2026-04-19: The branch was refreshed against Linear `FIET-773` / TASK-25 context. The ticket was already `In Progress` rather than `Backlog`, so no state transition was applied.
- 2026-04-19: Absorbing upstream disable-feelib work is being done by merging `origin/refactor/disable-feelib` into `tasks/TASK-25-remove-feelib-rebase-fee-isolation`, preserving branch-local Medusa/CI work where still relevant. The absorbed upstream commit sequence is:
  - `c7b32149` `do some quarantine on fee-path activation first.`
  - `26627ece` `disabling via stubs so far.`
  - `8e7227d7` `include final disable plan`
  - `f5856ec4` `massive culling of vtsfeelib`
  - `41b8a60a` `file/test cleanup`
- 2026-04-19: Conflict resolution policy for the merge:
  - core source and fee-surface deletions follow `origin/refactor/disable-feelib`
  - deleted fee-era tests/harnesses/invariants stay deleted
  - surviving Medusa/FuzzEntry files are deliberately woven to the new fee-less APIs instead of reverting to older Echidna-linked shapes
  - branch-local CI sharding (`3fefbead`) and Medusa/FuzzEntry migration work stay preserved
- 2026-04-19: The main conflict clusters were `VTSOrchestrator` / `IVTSOrchestrator` / `VTSCommitLib` / `VTSLifecycleLinkedLib` / `VTSPositionLib` / `VTSPositionMMOpsLib`, fee-era tests and harnesses (`VTSFeeLib*`, `VTSFeeLibHarness`, `MMPositionMinOutFeeAdjIntegration`, `COV01`, `COV03`, `COV04`, `FEE01`, `FEE02`), and the Medusa aggregators/harnesses (`FuzzVTSCoreTail`, `FuzzVTSPosition`, `FuzzMMSettle`, `VTSPositionLibFuzzHarness`, `SETTLE01`, `SETTLE02`, `SEIZE03_04`, `VTS01`, `SettleBeforeModifyHarness`).
- 2026-04-19: The authoritative upstream anchor advanced again and this branch now absorbs the full disable-feelib tail through:
  - `f54edc46` `next refactor around cleanup and docs adjustments`
  - `e8ef35fa` `disable MMCoverage for now.`
- 2026-04-19: The `f54edc46..e8ef35fa` merge was deliberately woven rather than taken blindly. Exact conflict/override decisions:
  - `contracts/evm-scripts/script/e2e/MMCoverage.s.sol`: took upstream retirement stub from `e8ef35fa`; the previous fee-pot scenario is intentionally gone.
  - `contracts/evm/Justfile`: kept the branch-local Medusa/FuzzEntry entrypoints over the upstream Echidna-oriented rewrite so `just fuzz`, `just fuzz-deep`, `just fuzz-invariants`, and `just medusa-entry` remain the supported workflow.
  - `contracts/evm/test/fuzz/invariants/MMQ01.sol`: restored the upstream thin compatibility wrapper so older `contract MMQ01` / Echidna-targeted workflows still resolve, while Medusa continues to target `FuzzEntry`.
  - `contracts/evm/test/fuzz/README.md`: manually rewrote the matrix to drop deleted fee-era surfaces (`COV-01`, `COV-03`, `COV-04`, `FEE-01`, `FEE-02`, `VTSFeeLib.index.t.sol`, `MMCoverage.s.sol`) and keep the supported Medusa/FuzzEntry path as the source of truth.
- 2026-04-19: Upstream deployment/periphery cleanup from `f54edc46` was taken as-is outside those conflict points, including the `DirectLPDeltaResolver` move into `src/periphery/`, evm-scripts deploy/config cleanup, and deletion of fee-era spec/docs under `agents/spec/`.
