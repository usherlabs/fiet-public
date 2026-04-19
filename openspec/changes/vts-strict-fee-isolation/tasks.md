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
