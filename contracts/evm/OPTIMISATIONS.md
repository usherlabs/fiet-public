# Fiet EVM Protocol Gas Optimisations

This document captures known gas optimisations, trade-offs, and future improvement opportunities for the EVM contracts under `contracts/evm/src`. It complements `INVARIANTS.md` by focusing on performance while preserving correctness and the protocol's economic/security model.

It is intended for developers, auditors, and anyone optimising the core swap, MM, settlement, and liquidity paths.

## Status of Audit Finding 33_9 (Duplicated Per-Tick Growth Accounting)

**Finding summary (from agents/audit-findings/33_9__...md)**:  
After `CoreHook.afterSwap` → `VTSOrchestrator.afterCoreSwap` → `VTSSwapLib.processSwap`, the library iterates initialised ticks crossed by the swap and performs `_onTickCross` / `_flipOutside` for both deficit and inflow growth on every crossed tick. An attacker can front-run by initialising many adjacent ticks with dust liquidity, forcing the victim swap to pay heavy zero→nonzero SSTORE costs (plus Uniswap's own per-tick work). This creates transaction-order-dependent gas grief/DoS, especially for large one-shot swaps on the core pool or proxy-routed swaps.

**Current implementation status (as of 2026-04-22)**: **Largely mitigated**.

### Key mitigation already in place

The expensive first-write of per-tick outside-growth state has been moved from swap time to **liquidity-add time**:

```871:896:contracts/evm/src/libraries/VTSPositionLib.sol
function _seedOutsideGrowthForNewlyInitializedTicks(...) private { ... }
```

This runs in `touchPosition` / `_seedOutsideGrowthForNewlyInitializedTicks` before position registration. When a new tick is initialised by an add-liquidity operation:

```907:910:contracts/evm/src/libraries/VTSPositionLib.sol
_seedOutsideAtInitializedTick(...) {
    if (tick > tickCurrent) return;
    s.deficitGrowthOutside[poolId][tick].token0 = paPool.deficitGrowthGlobal.token0;
    // ... same for token1, inflowGrowthOutside
}
```

Subsequent swaps that cross the tick now only perform nonzero→nonzero flips in `_flipOutside`, which is significantly cheaper.

See:
- `contracts/evm/src/libraries/VTSPositionLib.sol:_seedOutsideGrowthForNewlyInitializedTicks`
- `contracts/evm/src/libraries/VTSPositionLib.sol:_seedOutsideAtInitializedTick`
- `contracts/evm/test/libraries/VTSSwapLib.t.sol` (tests for zero-liquidity gaps, multi-tick crossing, and seeding behaviour)

**Residual cost**: Swaps that cross many initialised ticks still incur per-cross `_onTickCross` / `_flipOutside` overhead (two storage reads + two writes per tick per growth type). This is **by design** to maintain `VTS-02` (outside-flip invariant) and `VTS-03` (segment-based accrual). It is not "duplicated" accounting — it is the canonical Uniswap-style mechanism adapted for deficit + inflow growth.

This is now best classified as a **known gas trade-off** rather than a medium vulnerability. Dense-tick griefing remains possible but is much less severe than the original first-touch DoS.

### Recommended next steps for this path

1. **Micro-optimise `_onTickCross` / `_flipOutside`** (low effort, high impact on dense paths):
   - Collapse the two calls into a single function that operates on both growth types / both tokens in one storage pass.
   - Cache `paPool` lookup.
   - Consider a packed struct for outside growth if storage layout allows.

2. **Add explicit gas regression tests** for dense-tick scenarios in `test/libraries/VTSSwapLib.t.sol` and fuzz harnesses.

3. **Document acceptable gas bounds** for core swaps in `INVARIANTS.md` or this file (e.g. "a swap crossing N ticks should stay under X gas even in worst-case initialised-tick density").

4. **Consider proxy-pool safeguards** (MKT-05 already forbids proxy curve execution, but confirm proxy-routed swaps do not inadvertently amplify tick-cross costs).

## Other Gas Improvement Opportunities

### High-Impact / Low-Risk

- **MMPositionActionsImpl.sol**: The plain `MINT_POSITION` / `INCREASE_LIQUIDITY` paths still lack a `_validateMaxIn` equivalent in some flows (see audit 33_9 related notes). Adding consistent slippage guards can prevent over-spend without adding much runtime cost.
- **VTSSwapLib.sol**: The current `_processMultiTickSwap` loop has good forward-progress guarantees but still performs multiple `getSlot0` / tick calculations. Some values could be cached from the pre-swap snapshot passed from `CoreHook`.
- **LiquidityHub.sol / LiquidityHubLib.sol**: Several `_assert*` functions perform repeated bound-level lookups. Consider caching bound level for the common `(lcc, recipient)` tuple inside a transaction.
- **PositionManagerImpl.sol**: `_getLiquidityFromDeltas` reads `getSlot0` live. For "from deltas" paths this is acceptable, but ensure it cannot be manipulated in a way that causes excessive gas in `_mintPositionInternal`.

### Medium-Impact

- Use Solady's `FixedPointMathLib` or custom Q128 libraries more aggressively where `FullMath.mulDiv` is called in hot paths (swap accrual, seizure sizing, RFS calculations).
- Storage layout review: many `GrowthPair` and `PositionAccounting` structs could benefit from tighter packing.
- Transient storage usage in `CoreHook` and `PositionManagerEntrypoint` is already good — expand it to more intermediate values in MM batch flows.

### Monitoring / Testing

- Expand fuzz invariants in `test/fuzz/invariants/` to include gas bounds on critical paths (swap, MM increase/decrease, seizure, settlement).
- Add a gas snapshot test suite using Foundry's `gas` cheatcode or `forge test --gas-report`.
- Benchmark "worst-case dense tick" swaps regularly as the protocol matures.

## Status of Audit Finding 36_8 (Spot-dependent public commitment checkpointing)

**Finding summary (from agents/audit-findings/36__usherlabs-fiet-protocol-2026-04-23-analysis.md and 36_8 variant)**:  
Public `checkpoint(commitId, positionIndex, true)` reads live `slot0` / current tick to compute effective token amounts via `LiquidityUtils.calculateEffectiveTokenAmounts`, then writes `pa.commitmentDeficit`, `commitmentDeficitBps`, and `commitmentDeficitSince`. A third party can manipulate spot via swaps then checkpoint to force or clear deficits. This can temporarily freeze non-seizing MM liquidity changes (`CommitmentDeficitMMFreezeLib.blocksNonSeizingMMLiquidityChange`) or influence RFS inflation and seizure timing (`getRFS`, `validateSeize`).

**Current implementation status (as of 2026-04-23)**: **Accepted as MEV-driven griefing vector**.

The protocol's explicit premise is that `checkpoint(withCommitment)` must remain fully permissionless. Live spot valuation for solvency enforcement (`COMMIT-02`) is intentional and deliberately distinct from the conservative worst-case endpoint valuation used for admission (`COMMIT-01`). 

The griefing surface exists but is bounded:
- Attacker must pay real swap costs to move price.
- Makers can counter with their own checkpoint, settlement, or signal renewal.
- `COMMIT-02A` narrows the MM modify freeze to **material** deficits only (bps > 0 or configured per-token thresholds).
- Seizure path has partial hardening: `validateSeize` recomputes when a stored deficit already exists.

This is treated as an acceptable availability / timing risk under the current design rather than a core security vulnerability.

**Residual risk**: Sophisticated MEV participants or competitors can temporarily disrupt MM operations or delay seizure on targeted positions (especially in thinner pools). The economic cost to the attacker is non-zero and the maker retains recovery paths.

**Recommended next steps**:
- Monitor incidence of checkpoint griefing on live markets.
- If it becomes material, consider introducing a reference-tick / TWAP mode for commitment checkpoints (while keeping the entrypoint permissionless).
- Add regression tests for adversarial checkpoint + swap sequences in `test/libraries/VTSCommitLib.t.sol` and fuzz harnesses.
- Document explicit grief cost / timing bounds in this file or `INVARIANTS.md`.

## General Guidelines

- **Correctness first**: Never optimise at the expense of `INVARIANTS.md` guarantees (especially VTS-02, VTS-03, COMMIT-01, DELTA-01, SETTLE-03).
- **Pre-seed where possible**: The tick-seeding pattern is a good template for moving one-time costs out of hot paths.
- **Measure before changing**: Always compare gas before/after using Foundry profiles (`FOUNDRY_PROFILE=debug` from evm-scripts).
- **Solady preference**: Where gas is critical and OpenZeppelin patterns exist, prefer Solady equivalents (e.g. for math, ERC20 ops, Merkle proofs).
- **Proxy vs Core**: Keep proxy pool as a pure routing/no-op layer (MKT-05). Any gas spent in proxy should be minimal.

---

**Last updated**: 2026-04-23 (following review of audit finding 36_8 — accepted as MEV-driven griefing vector under the permissionless `checkpoint(withCommitment)` premise).

Future sections will be added as more optimisations are identified or implemented (e.g. specific PR numbers, gas delta measurements, benchmark results).
