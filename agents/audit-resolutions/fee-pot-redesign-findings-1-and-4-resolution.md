# Resolution: Fee Pot Redesign (Findings #1 and #4)

## Scope

This resolution covers the internal audit themes addressed by the **fee-pot redesign**:

1. **Finding #1 (capped positive fee materialisation / queued bonus source of truth)** — Removing reliance on a separate pool-level queued pot (`protocolFeeAccrued`) for bonus allocation, and anchoring CSI bonus economics on the **materialised** `slashedPot` after Phase 1 positive materialisation in `_processPositionFees`.
2. **Finding #4 (MM decrease routing vs fee slice)** — Preserving **SETTLE-03**: on liquidity **decreases**, positive `pendingFeeAdj` materialisation remains **capped per leg** to the informational `feesAccrued` slice; MM principal routing stays based on **`callerDelta - feesAccrued`** (pool principal only), as documented in `INVARIANTS.md` and `VTSPositionMMOpsLib` comments.

## Design summary

- **Removed** `protocolFeeAccrued` from `PoolAccounting` and removed **`getProtocolFeeAccrued`** from `IVTSOrchestrator` / `VTSOrchestrator`.
- **Two-phase ordering** inside `_processPositionFees`: fund `slashedPot` from positive pending **before** bonus allocation; allocate bonuses only against the materialised pot; then pay negative pending from `slashedPot`.
- **MM decrease safety** unchanged: positive materialisation caps on decreases remain the protection that hook-reported `feeAdj` stays aligned with the **fee** slice without redefining MM principal staging.

## Verification

- Unit / scenario tests: `VTSFeeLib.t.sol`, `VTSFeeLib.scenario.t.sol`, `VTSFeeLib.index.t.sol`, fuzz invariants `FEE01` / `FEE02`, MM min-out integration.
- Spec / invariants: `contracts/evm/INVARIANTS.md` (FEE-01), `agents/spec/FeeAdj-Flow-Pot-Accrual-And-Delta-Settlement.md`, `agents/spec/Fee-Pot-Materialisation-And-DirectLP-Policy.md`.

## Status

**Mitigated** by design + implementation as above; MM routing invariant (finding #4) explicitly retained under SETTLE-03.
