# BugPoCer review — 28 March 2026

**Finding:** [4.1.1. Subscriber Dos On Burn](1.txt) (`agents/audit-findings/1.txt`)

---

## Review verdict (protocol review)

**Classification:** False positive / mischaracterised operational risk — not a standalone exploitable vulnerability as written.

**Summary:** The report correctly notes that `notifyBurn` can revert if `DirectLPDeltaResolver -> MarketFactory.afterModifyLiquidity` reverts, and that Uniswap’s `Notifier` bubbles that up. It overstates impact: users can call `unsubscribe(tokenId)` while the pool manager is unlocked; `DirectLPDeltaResolver.notifyUnsubscribe` is a no-op, and the notifier deletes the subscriber before optional `notifyUnsubscribe` (which is wrapped in try/catch). So the claim that the subscriber “cannot be removed to unblock the burn” is incorrect.

**What is real:** Subscribed Direct LP flows depend on the resolver remaining correctly wired and protocol-bound so hook deltas can be cleared; admin removal of bounds or broken deployment can cause modify/burn reverts — a governance/operational failure mode, not a general external exploit.

**Inaccuracies in the original write-up:** “Factory unregistered” is a poor fit for `LiquidityHub.getFactory(lcc0,lcc1)` (per-LCC market wiring); “factory replaced” is not a realistic user-facing attack path in this callback chain.

**Suggested record:** FP, or “design/ops assumption” rather than vuln, unless rewritten with accurate preconditions and severity.

---

**Finding:** [4.1.2. Double Credit Same Balance](2.txt) (`agents/audit-findings/2.txt`)

---

## Review verdict (protocol review)

**Classification:** False positive for the current implementation, with a valid design-warning component.

**Summary:** The report correctly observes that `DynamicCurrencyDelta.syncBalanceAsCredit()` is a generic primitive that reads `currency.balanceOf(owner)` and can increase a `target` delta without marking that owner balance as consumed. However, the current reachable protocol surfaces do not expose the dangerous shape assumed by the report. `sync()` and `syncPair()` are restricted to protocol-bound callers, and the actual call sites use the constrained pattern `owner = address(this)` and `target = msgSender()`. There is no current untrusted flow that lets a caller repeatedly sync the same balance to multiple arbitrary recipients.

**What is real:** In isolation, `syncBalanceAsCredit()` is a footgun. If a future bound endpoint exposes attacker-controlled `owner` or `target` parameters, or reuses this primitive outside the current `MMPM -> current locker` pattern, the same-balance double-credit issue could become real.

**Why this is not presently exploitable:** User-facing MM entrypoints only expose `SYNC(currency)`, which resolves to the current batch locker as the sole target. Withdrawal is also capped to the actual ERC20 balance held by `MMPositionManager`, and unresolved residual deltas cause the batch to revert via `assertNonZeroDeltas()`. That means the report’s sketched “credit user A, then credit user B, then settle both for real tokens” path is not reachable as written in the present code.

**Suggested record:** FP for current code; retain as a refactor hazard / latent design warning around `syncBalanceAsCredit()` and any future caller that broadens its parameter control.

---

**Finding:** [4.1.3. Missing Access Control](3.txt) (`agents/audit-findings/3.txt`)

---

## Review verdict (protocol review)

**Classification:** False positive for the current intended execution model, with a latent design-warning component.

**Summary:** The report is correct at the primitive level that `VTSCurrencyDelta.take(currency, target, maxAmount)` is permissionless and can debit any target's positive delta. However, it overstates exploitability. In the current design, transient currency deltas are batch-scoped, must net to zero before batch end, and the reachable `MMPositionManager` flows execute synchronously for a single locker within one unlock context. There is no ordinary cross-user interleaving point where an arbitrary third party can observe a victim's live locker credit and front-run it with `take(...)` before the batch completes.

**What is real:** `take(...)` is a generic unauthorised primitive. If the protocol ever introduces a path where an untrusted contract can execute mid-batch with knowledge of a live target address and currency, that contract could consume another target's positive delta without being that locker. In that narrower sense, the lack of caller scoping is a real footgun.

**Why this is not presently exploitable as written:** User-facing MM batches run through `MMPositionManager.modifyLiquidities(...)` / `modifyLiquiditiesWithoutUnlock(...)`, which execute actions synchronously and only then call `assertNonZeroDeltas()`. Delta netting to zero does not itself prove authorisation, but under the current intended model there is no standalone adversarial execution slot between "credit created" and "batch finalised" unless the user is already routing through a malicious contract or interacting with a malicious token / callback surface. That is outside the ordinary protocol threat model assumed by the invariants and surrounding review notes.

**Key correction to the original write-up:** The finding should not be described as "any external caller can destroy any user's settlement claim" in the general case. The realistic risk is conditional on hostile same-transaction execution being introduced into the call chain; it is not a universal public drain on its own.

**Suggested record:** FP for current code, but retain as a design warning: if future refactors broaden mid-batch callback surfaces or expose delta targets/currencies to untrusted contracts, `take(...)` should be revisited and potentially scoped to the current locker / authorised caller.

---

**Finding:** [4.1.4. Double Credit Different Targets](4.txt) (`agents/audit-findings/4.txt`)

---

## Review verdict (protocol review)

**Classification:** False positive for the current implementation, with the same design-warning component as [4.1.2](2.txt).

**Summary:** This finding is the “same owner, different targets” variant of the `syncBalanceAsCredit` issue already covered for 4.1.2. The report is correct that calling `syncBalanceAsCredit` with the same `owner` but different `target` addresses can credit each target’s delta up to `balanceOf(owner)` independently, without transferring or locking the underlying — so in a vacuum, total credited deltas can exceed the backing balance. `VTSCurrencyDelta.sync` / `syncPair` are generic in `owner` and `target`, and callers are only gated by `_assertBoundFactoryCaller` (bounds-approved addresses for the factory namespace).

**What is real:** The primitive behaviour and the generic `sync` surface are as described. Bounds-approved modules are trusted in the threat model; misconfiguration or a future bound caller that passes arbitrary `owner`/`target` pairs would reintroduce risk.

**Why this is not presently exploitable as “phantom credits then drain”:** Actual MM flows fix `owner = address(this)` (`MMPositionManager` / impl) and `target = msgSender()` (locker). `_take` caps payout to `currency.balanceOfSelf()` on `MMPositionManager` before debiting delta, so you cannot withdraw more real tokens than the router holds regardless of how many distinct addresses have positive transient credits from the same nominal balance. Residual router balance semantics match `INVARIANTS.md` DELTA-02 (FCFS dust, not per-user entitlement). Batch end still requires `assertNonZeroDeltas()` to clear transient accounting.

**Overlap with 4.1.2:** Same root (`syncBalanceAsCredit`); 4.1.4 emphasises multi-target credit inflation rather than “double credit” wording only. Verdict aligns with 4.1.2.

**Suggested record:** FP for current code; same refactor hazard note as 4.1.2 — keep `sync`/`syncPair` usage constrained to `owner = MMPM`, `target = locker`, and review any new bounds-approved caller that exposes `owner`/`target` to untrusted input.

---

**Finding:** [4.2.4. Balance Sync Overcrediting](8.txt) (`agents/audit-findings/8.txt`)

---

## Review verdict (protocol review)

**Classification:** False positive for the current implementation, with a valid consistency / design-warning component.

**Summary:** The report correctly observes that the ERC20 unwrap-to-self path in `MMPositionManager` uses `_syncBalanceAsCredit(...)` rather than exact-crediting the measured `unwrapped` amount, while the native path uses `_creditExact(...)`. In isolation, that means the current locker can be credited against the contract's full ERC20 balance, not just the increment produced by this unwrap. However, this is not a protocol-breaking overcredit bug under the current model: `MMPositionManager` intentionally exposes balance-sync semantics via `SYNC`, payouts are capped to the router's actual balance, and transient deltas must net to zero by batch end.

**What is real:** There is a real asymmetry between native and ERC20 handling here. For ERC20 underlyings, unwrap-to-`address(this)` inherits the same balance-sync semantics as the generic router residue model. That is a legitimate refactor hazard and a UX / consistency sharp edge: future readers could wrongly assume this path credits only the just-unwrapped amount because `unwrapped` is computed immediately beforehand.

**Why this is not presently exploitable as a vuln:** The allegedly "extra" credit is only credit against tokens already sitting on `MMPositionManager`, and `INVARIANTS.md` explicitly states that residual balances on `MMPositionManager` are FCFS dust rather than persisted per-user entitlements. The next caller being able to sync/take residual router balance is therefore part of the documented model, not an unintended bypass. `_take(...)` also caps withdrawals to `currency.balanceOfSelf()`, so no caller can extract more real tokens than the contract actually holds, and `_afterBatch()` enforces `assertNonZeroDeltas()` so unresolved transient accounting cannot roll forward as a standing claim.

**Suggested record:** FP for current code. Retain as a design note: if the protocol ever wants unwrap-to-self to mean "credit exactly this operation's output", the ERC20 branch should be made explicit like the native branch. Until then, treat this as deliberate router-residue behaviour rather than a standalone exploit.

---

**Finding:** [4.2.1. Bucket Accounting Desync On Exemption Transition](5.txt) (`agents/audit-findings/5.txt`)

---

## Review verdict (protocol review)

**Classification:** True positive as an accounting / governance-surface bug in the pre-fix design; resolved by bound-lifecycle hardening.

**Summary:** The original report is directionally correct. In the pre-fix model, an address could receive bucketless ERC20 balance while `BOUND_EXEMPT`, later become bucket-tracked, and then accumulate partial bucket state such that `balanceOf(account) > wrappedBalances + marketDerivedBalances`. At that point, transfer and unwrap paths would reason over bucket totals rather than raw ERC20 balance, stranding the exempt-era portion for the now non-exempt holder.

**What was real:** `LiquidityCommitmentCertificate.mint(...)` intentionally skips bucket bookkeeping for exempt recipients, while transfer / unwrap accounting for non-exempt holders depends on `wrappedBalances + marketDerivedBalances`. The dangerous edge was not minting alone, but crossing the exempt boundary after exempt-era balance already existed.

**Important qualification to the original write-up:** The report overstated impact by calling the balance "permanently stuck" in all cases. The issue was governance-controlled rather than permissionless, and an operator could sometimes recover by moving the holder back into an exempt role. So the strongest accurate characterisation was: real bug, but primarily an admin / role-transition footgun rather than a generic public exploit.

**Resolution implemented:** The protocol now enforces bound-role lifecycle on-chain in `src/modules/BoundRegistry.sol::_setBoundLevel`:

- `BOUND_EXEMPT` and `BOUND_DEX` are bootstrap-only roles, assignable only from `BOUND_NONE`.
- Once a `(factory, who)` pair is `BOUND_EXEMPT` or `BOUND_DEX`, that role is immutable.
- Post-bootstrap admin may only transition `BOUND_NONE <-> BOUND_ENDPOINT`.

This removes the `EXEMPT -> tracked` transition that made the desync reachable in normal admin flows, and also blocks later downgrades of privileged exempt/dex roles.

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` now records this explicitly under the bound-role lifecycle invariant (`MKT-04A`), making the bound lifecycle a structural precondition for the LCC bucket-accounting invariants rather than an off-chain governance note only.

**Suggested record:** TP in the original design, now resolved by on-chain lifecycle enforcement for bound roles. Residual risk is operational only in the sense that bootstrap role assignment must still be correct, but the problematic exempt-boundary transition is no longer available as a routine admin action.

---

**Finding:** [4.2.3. Exempt Status Transition Bucket Desync](7.txt) (`agents/audit-findings/7.txt`)

---

## Review verdict (protocol review)

**Classification:** True positive in the pre-fix design; same root cause family as [4.2.1](5.txt), now resolved by the same bound-lifecycle hardening.

**Summary:** This write-up is a more explicit execution variant of the same exempt-boundary bug. In the pre-fix model, an exempt holder could carry bucketless ERC20 balance, later become non-exempt, and then receive additional tracked balance so that `balancesOf(account)` stopped using its bucketless fallback and exposed only the newly tracked slice. From that point, transfer / unwrap / burn-style paths reasoned over bucket totals rather than full ERC20 balance, leaving the exempt-era portion unusable while the address remained non-exempt.

**What was real:** The report correctly identified that:

- `LCC.mint(...)` and exempt-recipient transfer paths skip bucket bookkeeping for exempt holders,
- `balancesOf(...)` only falls back to `(fullBalance, 0)` while the holder is exempt or while bucket sum is zero, and
- non-exempt transfer and unwrap accounting rely on `wrappedBalances + marketDerivedBalances`, not raw `balanceOf(...)`.

That combination made `EXEMPT -> tracked` transitions unsafe once exempt-era balance already existed.

**Relationship to 4.2.1:** This is not a distinct root cause from [4.2.1](5.txt); it is the same underlying governance / role-transition bug shown through a slightly different state progression. `4.2.1` used "mint while exempt, then mint again after becoming tracked". `4.2.3` uses "mint/hold while exempt, then flip to tracked, then receive an additional tracked transfer". Both rely on the same forbidden exempt-boundary crossing.

**Important qualification to the original write-up:** The impact was real, but the phrase "cannot be corrected through any on-chain mechanism" was too absolute for the pre-fix system. The transition was governance-controlled rather than permissionless, and operators could sometimes recover serviceability by restoring the holder to an exempt role. So the most accurate framing was: real admin-surface accounting bug, not a public arbitrary-user exploit.

**Resolution implemented:** The protocol now hardens bound-role lifecycle so the dangerous transition is no longer available through the exposed factory/admin surface:

- `src/modules/BoundRegistry.sol::_setBoundLevel` now reverts `Errors.InvalidBoundLevelTransition(oldLevel, newLevel)` when:
  - an address already at `BOUND_EXEMPT` / `BOUND_DEX` is moved to a different level, or
  - `BOUND_EXEMPT` / `BOUND_DEX` is assigned from any level other than `BOUND_NONE`.
- In the current factory design, the exposed post-bootstrap admin surface remains `BOUND_NONE <-> BOUND_ENDPOINT` only (`MarketFactory.addBounds` / `removeBounds`), while exempt/dex assignment occurs in factory-controlled bootstrap paths (`initialise`, `createMarket`).

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` now captures this as `MKT-04A`, explicitly tying bound-role lifecycle to bucket-accounting soundness and queue/serviceability assumptions.

**Suggested record:** TP in the original design, now resolved. Mark as duplicate-root / same-fix family as [4.2.1](5.txt) rather than as a separate unresolved issue.

---

**Finding:** [4.2.2. Balance Accounting Inconsistency](6.txt) (`agents/audit-findings/6.txt`)

---

## Review verdict (protocol review)

**Classification:** True positive in the pre-fix design; resolved by the same bound-lifecycle hardening now enforced on-chain.

**Summary:** This finding is materially real for the pre-fix model and is best understood as the more specific "partial bucket state" manifestation of the broader exempt-boundary bug captured in 4.2.1. The dangerous shape was: an address first accumulates bucketless ERC20 balance while `BOUND_EXEMPT`, then later becomes non-exempt, and only afterwards receives a bucket-tracked inflow. At that point, `balancesOf(account)` could report only the newly tracked portion while `balanceOf(account)` still included the older exempt-era balance, so downstream accounting would reason over a strict subset of the holder's ERC20 balance.

**What was real:** The report correctly identified that the fallback in `LiquidityCommitmentCertificate.balancesOf(...)` only handled the fully bucketless case. Once the holder crossed into a mixed state (`balanceSum > 0` but `< balanceOf(account)`), the function returned the raw bucket mappings, and transfer / settlement flows that rely on bucket totals rather than raw ERC20 balance could under-report or reject actions against the exempt-era residue.

**Important qualification to the original write-up:** As with 4.2.1, this was not a permissionless public exploit. The inconsistent state depended on a governance-controlled role transition across the exempt boundary. So the right severity framing is an admin / configuration-induced accounting and liveness bug, not a universal user-triggerable drain.

**Resolution implemented:** The protocol now prevents the problematic state from becoming reachable through normal admin flows:

- `src/modules/BoundRegistry.sol::_setBoundLevel` enforces that `BOUND_EXEMPT` and `BOUND_DEX` are bootstrap-only (assignable only from `BOUND_NONE`) and immutable once assigned.
- Routine post-bootstrap bounds management is therefore restricted to `BOUND_NONE <-> BOUND_ENDPOINT`.
- Disallowed transitions now revert `Errors.InvalidBoundLevelTransition(oldLevel, newLevel)`.

This matters because the reported "partial bucket state" specifically required `EXEMPT -> non-exempt` after exempt-era balance already existed. That transition is no longer available as a routine admin action, so the inconsistent `balancesOf < balanceOf` state described by the report is no longer reachable under the intended lifecycle.

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` now records this under `MKT-04A`, explicitly stating that exempt/dex roles are bootstrap-only and that the mutable admin lifecycle is limited to `BOUND_NONE <-> BOUND_ENDPOINT`.

**Suggested record:** TP in the original design, now resolved. Keep the record distinct from 4.2.1 if you want to preserve the narrower "partial bucket accounting inconsistency" symptom, but note that both findings share the same root cause and the same fix.
