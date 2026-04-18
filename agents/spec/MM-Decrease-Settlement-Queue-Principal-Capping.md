# MM Decrease Settlement Queue Principal Capping & Shortfall > Principal Cases

> **Module**: `VTSPositionLib`, `LiquidityHub`, `MarketVault`  
> **Author**: Grok (research synthesis)  
> **Last Updated**: 12 April 2026  
> **Status**: Research complete. Design decision documented. No code change required.  
> **Related**: Audit finding 4, `Currency-Delta-Accounting.md`, `INVARIANTS.md` (SETTLE-03, DELTA-01, HUB-02)

This note consolidates the research that led to the current implementation of `_previewLiquidityDecreaseRouting` / `_computeLiquidityDecreaseRoutingSplit` in `VTSPositionLib.sol`.

It explains:
- Why `settleable + queued` can be < `requiredSettlementDelta` (shortfall > principal)
- The exact scenarios where this occurs
- Why the smart contracts avoid exploitable paths even though the deviation is possible

---

## 1. Core Principle (as clarified by the user)

When a decrease occurs, routing is a **two-step** story (see **SETTLE-03** in `contracts/evm/INVARIANTS.md`):

1. **Clamp live `pa.settled` (and pool `totalSettled`) only by what is actually routed in this step** — namely `settleableDelta + queuedDelta` (`exportedForSettlementClamp`), not necessarily the full `requiredSettlementDelta` when `shortfall > principal` on a lane.
2. **Export ONLY the vault-immediate slice** (`settleableDelta`) as the positive owner underlying delta on `DynamicCurrencyDelta`. Any remainder that cannot be Hub-queued under the principal cap **stays in live `pa.settled`**, not on transient underlying delta (avoids double-count and **DELTA-01** violations).

The queue should absorb everything that can be backed by same-lane **principal returned on this decrease path**. Fees are deliberately excluded from queueing because fee management is handled separately via the MMPM balance sync path.

### Distinction: VTS queue principal vs MMPM decrease/burn min-out

- **VTS / cancel-with-queue principal** for routing caps remains hook-time **`callerDelta - feesAccrued`** (pool principal for the modify), unchanged by materialised `feeAdj` in `processMMOperations` — see `VTSPositionMMOpsLib` and regression tests (e.g. Scan 21 / `SETTLE-03`).
- **User-facing `amount0Min` / `amount1Min`** on `DECREASE_LIQUIDITY` and `BURN_POSITION` is a floor on the per-leg **immediate post-`feeAdj` non-fee LCC** (`LiquidityUtils.forwardedNonFeeLccAmount`), i.e. the same split as `PositionManagerImpl._handleLccBalanceIncrease`. For **commit buckets** (`tokenId > 0`), only the Hub-queued slice `qCommitted` is physically forwarded to `MMQueueCustodian`; any surplus `nonFee - qCommitted` stays as **locker transient LCC credit** (cleared via `TAKE` / `UNWRAP_LCC`). Do not conflate VTS queue principal with min-out in product docs or integrator expectations.

---

## 2. How the routing split is implemented today

```1418:1444:contracts/evm/src/libraries/VTSPositionLib.sol
        uint256 principalAmount0 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount0());
        uint256 principalAmount1 = LiquidityUtils.safeInt128ToUint256(principalDelta.amount1());
        int128 req0 = requiredSettlementDelta.amount0();
        int128 req1 = requiredSettlementDelta.amount1();

        {
            BalanceDelta availableDelta = ctx.marketVault.dryModifyLiquidities(requiredSettlementDelta);
            BalanceDelta rawShortfall = requiredSettlementDelta - availableDelta;
            int128 shortfall0 = rawShortfall.amount0();
            int128 shortfall1 = rawShortfall.amount1();
            if (shortfall0 < 0) shortfall0 = 0;
            if (shortfall1 < 0) shortfall1 = 0;

            settleableDelta = toBalanceDelta(req0 - shortfall0, req1 - shortfall1);

            uint256 shortfallAmount0 = LiquidityUtils.safeInt128ToUint256(shortfall0);
            uint256 shortfallAmount1 = LiquidityUtils.safeInt128ToUint256(shortfall1);
            retainedPrincipal0 = shortfallAmount0 > principalAmount0 ? principalAmount0 : shortfallAmount0;
            retainedPrincipal1 = shortfallAmount1 > principalAmount1 ? principalAmount1 : shortfallAmount1;
        }

        queuedDelta = LiquidityUtils.safeToBalanceDelta(retainedPrincipal0, retainedPrincipal1, false, false);
        underlyingDeltaSettlement = settleableDelta;   // only the immediate vault slice
        exportedForSettlementClamp = settleableDelta + queuedDelta;
```

Key points:
- `principalDelta` = `callerDelta - feesAccrued` (pool principal only; **not** net of `feeAdj` — fee slash/bonus is reconciled when MMPM takes LCC and classifies fee vs non-fee; see `VTSPositionMMOpsLib.processMMOperations`).
- `retainedPrincipal` (what becomes queued) is **capped by same-lane principal**.
- `underlyingDeltaSettlement` = `settleableDelta` only (the vault-immediate slice).
- The clamp on `pa.settled` uses `settleable + queued`, **not** the full `requiredSettlementDelta`.

---

## 3. When shortfall > principal (the deviation case)

This occurs precisely when:

```text
shortfall on lane X > fee-excluded principal returned on lane X
```

### Concrete scenarios

**Scenario A – Opposite-lane principal (most common)**

- Position has large historical settled excess on `token0`.
- Decrease is out-of-range on `token1` side → `principalDelta0 ≈ 0`, `principalDelta1` is large.
- `requiredSettlementDelta0 = 100`, `vaultAvailable0 = 10`.
- `shortfall0 = 90`, `principal0 = 5` → `queued0 = 5`, `settleable0 = 10`.
- `settleable0 + queued0 = 15 < 100`.

The remaining 85 stays in live `settled`.

This is the key semantic distinction:
- The **cancel-with-queue** dynamic is only about the `5` LCC of same-lane principal actually touched by this decrease path.
- It is therefore correct that `queued0` is `5`, not `90`, under the current `planCancelWithQueue` primitive.
- The remaining `85` is still an MM-owned settled excess claim, but it is **not** part of this decrease path's principal-backed queue.
- That remainder must instead remain accessible via the normal MM settlement / withdrawal surface (for example, a later direct `SETTLE` withdrawal when serviceable), rather than being force-materialised into the queue.

**Scenario B – Heavy fees on the same lane**

- Gross `callerDelta0 = 80`.
- `feesAccruedAfterAdj0 = 45` (large fee accrual or feeAdj slash).
- `principalDelta0 = 35`.
- `requiredSettlementDelta0 = 70`, `vaultAvailable0 = 10`.
- `shortfall0 = 60 > 35` → `queued0 = 35`, `settleable0 = 10`.
- `settleable + queued = 45 < 70`.

**Scenario C – Seizure path**

The seizure branch currently passes `requiredSettlementDelta` as the second argument to `_handleLiquidityDecrease`, so it can queue up to the full required amount (not capped by principal). This is intentional and documented in the seizure comment.

---

## 4. Why this is safe (no exploitable path)

Even though `settleable + queued < requiredSettlementDelta` is possible, the system avoids exploitable liveness or accounting issues for the following reasons:

1. **The remainder stays in live `settled`** (see `exportedForSettlementClamp = settleable + queued`).
   It is **not** turned into positive MMPM underlying delta. Therefore it does **not** create uncleared transient delta at batch end.

2. **The queue is intentionally principal-backed**.
   `planCancelWithQueue` enforces `queueAmount <= principalAmount`. This is a deliberate design choice so that queued settlement is always backed by actual LCC principal being cancelled on that transfer path. This prevents “phantom queue” that could be gamed.

   Importantly, this does **not** mean the MM loses access to any residual settled excess that was not queued. It means only that:
   - `cancelWithQueue` handles the LCC principal touched by this decrease path, and
   - any remaining settled excess must still be realised through the protocol's ordinary settlement / withdrawal path rather than by over-extending the queue.

3. **MarketVault `dryModifyLiquidities` + `modifyLiquidities` are deterministic within a batch**.
   The same vault state is seen by both the decrease routing and any same-batch `onMMSettle`. There is no race that would let a later settle suddenly discover more liquidity than was visible at decrease time.

4. **Seizure path uses a different routing** (`requiredSettlementDelta` as both arguments) and is explicitly allowed to queue the full amount.

5. **Tests explicitly cover the deviation case**.
   `test_touchPosition_existingDecrease_currentLiqZero_MM_principalCappedQueue_retainsUnqueuedInSettled()` asserts that the unqueueable remainder correctly remains in `settled` and is not forced onto underlying delta.

6. **No invariant is violated**.
   - `SETTLE-03` (updated) now states that the non-queueable remainder may legitimately remain in live `settled`.
   - `DELTA-01` is satisfied because only the immediately serviceable slice becomes transient underlying delta.
   - `HUB-02` (queue semantics) is respected because queue never exceeds principal.

---

## 5. Relation to fees

Fees are one important trigger (they shrink `principalDelta`), but not the only one.

The fundamental driver is the **decoupling** between:
- `requiredSettlementDelta` (driven by historical settled excess and commitment math), and
- `principalDelta` (driven by what this specific liquidity modification actually returns after fees).

When those two quantities diverge on a lane, `shortfall > principal` occurs.

The design deliberately chooses to:
- queue only what can be backed by same-lane principal touched by this decrease, and
- leave the remainder in live `settled` rather than creating potentially uncleared positive underlying delta.

That remaining live `settled` amount should be understood as still withdrawable through the MM's ordinary `SETTLE`-driven withdrawal path once serviceable; it is not intended to be stranded merely because it was not queue-backed by this specific decrease.

This matches the clarified intent.

---

## 6. Conclusion & Recommendation

The current implementation correctly implements the clarified principle.

- `settleable + queued` can legitimately be < `requiredSettlementDelta`.
- The excess remainder stays in live `settled` (not turned into transient delta).
- This avoids the original finding-4 liveness issue while preserving single-representation accounting.
- No further code change is required.
- The new regression test and updated `INVARIANTS.md` (SETTLE-03) document this behaviour.

**Status**: Design accepted. No exploitable paths identified.

---

**Related documents**:
- `agents/spec/Currency-Delta-Accounting.md` (especially the 10 April 2026 amendment)
- `contracts/evm/INVARIANTS.md` (SETTLE-03, DELTA-01, HUB-02)
- `contracts/evm/src/libraries/VTSPositionLib.sol` (lines ~1418–1444 and ~1277–1313)
- `contracts/evm/test/libraries/VTSPositionLib.t.sol` (the principal-capped regression test)

Last reviewed: 12 April 2026
