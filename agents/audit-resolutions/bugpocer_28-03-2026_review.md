# BugPoCer review — 28 March 2026

**Finding:** [4.1.1. Subscriber Dos On Burn](1.txt) (`agents/audit-findings/1.txt`)

**Classification:** False positive / mischaracterised operational risk — not a standalone exploitable vulnerability as written.

**Summary:** The report correctly notes that `notifyBurn` can revert if `DirectLPDeltaResolver -> MarketFactory.afterModifyLiquidity` reverts, and that Uniswap’s `Notifier` bubbles that up. It overstates impact: users can call `unsubscribe(tokenId)` while the pool manager is unlocked; `DirectLPDeltaResolver.notifyUnsubscribe` is a no-op, and the notifier deletes the subscriber before optional `notifyUnsubscribe` (which is wrapped in try/catch). So the claim that the subscriber “cannot be removed to unblock the burn” is incorrect.

**What is real:** Subscribed Direct LP flows depend on the resolver remaining correctly wired and protocol-bound so hook deltas can be cleared; admin removal of bounds or broken deployment can cause modify/burn reverts — a governance/operational failure mode, not a general external exploit.

**Inaccuracies in the original write-up:** “Factory unregistered” is a poor fit for `LiquidityHub.getFactory(lcc0,lcc1)` (per-LCC market wiring); “factory replaced” is not a realistic user-facing attack path in this callback chain.

**Suggested record:** FP, or “design/ops assumption” rather than vuln, unless rewritten with accurate preconditions and severity.

---

**Finding:** [4.1.2. Double Credit Same Balance](2.txt) (`agents/audit-findings/2.txt`)

**Classification:** False positive for the current implementation, with a valid design-warning component.

**Summary:** The report correctly observes that `DynamicCurrencyDelta.syncBalanceAsCredit()` is a generic primitive that reads `currency.balanceOf(owner)` and can increase a `target` delta without marking that owner balance as consumed. However, the current reachable protocol surfaces do not expose the dangerous shape assumed by the report. `sync()` and `syncPair()` are restricted to protocol-bound callers, and the actual call sites use the constrained pattern `owner = address(this)` and `target = msgSender()`. There is no current untrusted flow that lets a caller repeatedly sync the same balance to multiple arbitrary recipients.

**What is real:** In isolation, `syncBalanceAsCredit()` is a footgun. If a future bound endpoint exposes attacker-controlled `owner` or `target` parameters, or reuses this primitive outside the current `MMPM -> current locker` pattern, the same-balance double-credit issue could become real.

**Why this is not presently exploitable:** User-facing MM entrypoints only expose `SYNC(currency)`, which resolves to the current batch locker as the sole target. Withdrawal is also capped to the actual ERC20 balance held by `MMPositionManager`, and unresolved residual deltas cause the batch to revert via `assertNonZeroDeltas()`. That means the report’s sketched “credit user A, then credit user B, then settle both for real tokens” path is not reachable as written in the present code.

**Suggested record:** FP for current code; retain as a refactor hazard / latent design warning around `syncBalanceAsCredit()` and any future caller that broadens its parameter control.

---

**Finding:** [4.1.3. Missing Access Control](3.txt) (`agents/audit-findings/3.txt`)

**Classification:** False positive for the current intended execution model, with a latent design-warning component.

**Summary:** The report is correct at the primitive level that `VTSCurrencyDelta.take(currency, target, maxAmount)` is permissionless and can debit any target's positive delta. However, it overstates exploitability. In the current design, transient currency deltas are batch-scoped, must net to zero before batch end, and the reachable `MMPositionManager` flows execute synchronously for a single locker within one unlock context. There is no ordinary cross-user interleaving point where an arbitrary third party can observe a victim's live locker credit and front-run it with `take(...)` before the batch completes.

**What is real:** `take(...)` is a generic unauthorised primitive. If the protocol ever introduces a path where an untrusted contract can execute mid-batch with knowledge of a live target address and currency, that contract could consume another target's positive delta without being that locker. In that narrower sense, the lack of caller scoping is a real footgun.

**Why this is not presently exploitable as written:** User-facing MM batches run through `MMPositionManager.modifyLiquidities(...)` / `modifyLiquiditiesWithoutUnlock(...)`, which execute actions synchronously and only then call `assertNonZeroDeltas()`. Delta netting to zero does not itself prove authorisation, but under the current intended model there is no standalone adversarial execution slot between "credit created" and "batch finalised" unless the user is already routing through a malicious contract or interacting with a malicious token / callback surface. That is outside the ordinary protocol threat model assumed by the invariants and surrounding review notes.

**Key correction to the original write-up:** The finding should not be described as "any external caller can destroy any user's settlement claim" in the general case. The realistic risk is conditional on hostile same-transaction execution being introduced into the call chain; it is not a universal public drain on its own.

**Suggested record:** FP for current code, but retain as a design warning: if future refactors broaden mid-batch callback surfaces or expose delta targets/currencies to untrusted contracts, `take(...)` should be revisited and potentially scoped to the current locker / authorised caller.

---

**Finding:** [4.1.4. Double Credit Different Targets](4.txt) (`agents/audit-findings/4.txt`)

**Classification:** False positive for the current implementation, with the same design-warning component as [4.1.2](2.txt).

**Summary:** This finding is the “same owner, different targets” variant of the `syncBalanceAsCredit` issue already covered for 4.1.2. The report is correct that calling `syncBalanceAsCredit` with the same `owner` but different `target` addresses can credit each target’s delta up to `balanceOf(owner)` independently, without transferring or locking the underlying — so in a vacuum, total credited deltas can exceed the backing balance. `VTSCurrencyDelta.sync` / `syncPair` are generic in `owner` and `target`, and callers are only gated by `_assertBoundFactoryCaller` (bounds-approved addresses for the factory namespace).

**What is real:** The primitive behaviour and the generic `sync` surface are as described. Bounds-approved modules are trusted in the threat model; misconfiguration or a future bound caller that passes arbitrary `owner`/`target` pairs would reintroduce risk.

**Why this is not presently exploitable as “phantom credits then drain”:** Actual MM flows fix `owner = address(this)` (`MMPositionManager` / impl) and `target = msgSender()` (locker). `_take` caps payout to `currency.balanceOfSelf()` on `MMPositionManager` before debiting delta, so you cannot withdraw more real tokens than the router holds regardless of how many distinct addresses have positive transient credits from the same nominal balance. Residual router balance semantics match `INVARIANTS.md` DELTA-02 (FCFS dust, not per-user entitlement). Batch end still requires `assertNonZeroDeltas()` to clear transient accounting.

**Overlap with 4.1.2:** Same root (`syncBalanceAsCredit`); 4.1.4 emphasises multi-target credit inflation rather than “double credit” wording only. Verdict aligns with 4.1.2.

**Suggested record:** FP for current code; same refactor hazard note as 4.1.2 — keep `sync`/`syncPair` usage constrained to `owner = MMPM`, `target = locker`, and review any new bounds-approved caller that exposes `owner`/`target` to untrusted input.

---

**Finding:** [4.2.4. Balance Sync Overcrediting](8.txt) (`agents/audit-findings/8.txt`)

**Classification:** False positive for the current implementation, with a valid consistency / design-warning component.

**Summary:** The report correctly observes that the ERC20 unwrap-to-self path in `MMPositionManager` uses `_syncBalanceAsCredit(...)` rather than exact-crediting the measured `unwrapped` amount, while the native path uses `_creditExact(...)`. In isolation, that means the current locker can be credited against the contract's full ERC20 balance, not just the increment produced by this unwrap. However, this is not a protocol-breaking overcredit bug under the current model: `MMPositionManager` intentionally exposes balance-sync semantics via `SYNC`, payouts are capped to the router's actual balance, and transient deltas must net to zero by batch end.

**What is real:** There is a real asymmetry between native and ERC20 handling here. For ERC20 underlyings, unwrap-to-`address(this)` inherits the same balance-sync semantics as the generic router residue model. That is a legitimate refactor hazard and a UX / consistency sharp edge: future readers could wrongly assume this path credits only the just-unwrapped amount because `unwrapped` is computed immediately beforehand.

**Why this is not presently exploitable as a vuln:** The allegedly "extra" credit is only credit against tokens already sitting on `MMPositionManager`, and `INVARIANTS.md` explicitly states that residual balances on `MMPositionManager` are FCFS dust rather than persisted per-user entitlements. The next caller being able to sync/take residual router balance is therefore part of the documented model, not an unintended bypass. `_take(...)` also caps withdrawals to `currency.balanceOfSelf()`, so no caller can extract more real tokens than the contract actually holds, and `_afterBatch()` enforces `assertNonZeroDeltas()` so unresolved transient accounting cannot roll forward as a standing claim.

**Suggested record:** FP for current code. Retain as a design note: if the protocol ever wants unwrap-to-self to mean "credit exactly this operation's output", the ERC20 branch should be made explicit like the native branch. Until then, treat this as deliberate router-residue behaviour rather than a standalone exploit.

---

**Finding:** [4.2.5. Defensive Clamping Unbacked Supply](9.txt) (`agents/audit-findings/9.txt`)

**Classification:** False positive for the current implementation, with a narrow refactor-hazard note.

**Summary:** The report claims that `_finaliseBurns` clamps `targetToBurn` and `backingToBurn` to `min(expected, balanceOf(..., address(this)))`, so if Hub-held balances shrink before finalisation, minted target LCC can exceed what is burned in that step — violating value conservation. That misreads the protocol’s conservation model for `wrapWith`. Conservation is not “mint == burn in `_finaliseBurns` alone”; it is supply- and queue-aware: `marketToMint` may include queued, not-yet-redeemed exposure, and Hub-queue settlement can burn Hub-held LCC before `_finaliseBurns` runs. The library documents that `backingToBurn` only reflects what is redeemed immediately, while `marketToMint` can include the queued remainder.

**What is real:** Defensive clamping exists so that if queue state or Hub-held balances change between netting and finalisation (for example after `confirmTake` triggers `_processSettlementFor` for the Hub’s own queue during `useMarketLiquidity`), the final burn step does not double-burn tokens already settled. That is intentional interaction with `LiquidityHub.confirmTake`, not proof of an exploitable “silent mint” bug. A future refactor that introduced a new path shrinking Hub `balanceOf(lcc)` / `balanceOf(withLCC)` between context computation and `_finaliseBurns` without a matching queue or settlement effect could make clamping dangerous; that is not the present reachable graph.

**Why this is not presently exploitable as written:** `wrapWith` / `_wrapWith` are `nonReentrant`, so ordinary concurrent Hub mutators cannot interleave. During `_unwrapResidual`, `unwrapInternalLogic` may call `useMarketLiquidity` → vault → `confirmTake`; `confirmTake` may call `_processSettlementFor(lcc, address(this), amount)` and burn Hub-held LCC for queued obligations before `_finaliseBurns`, which is why balances can legitimately be lower than `ctx.*ToBurn` without unbacked minting. `confirmTake` is guarded by a balance-backed reserve invariant (`confirmTakeBalanceInvariant`). Intended conservation is also encoded in tests (for example `WRAPWITH-CONS-01` in `contracts/evm/test/fuzz/LiquidityHubWrapWithEchidnaTest.sol`: sum of LCC supplies moves with `totalQueued` on the backing leg when reserves are unchanged).

**Suggested record:** FP for current code. Optional note in the BugPoCer log: “not unbacked supply; domain conversion + queue semantics; see `LiquidityHubLib._unwrapResidual` / `_finaliseBurns` and `LiquidityHub.confirmTake`.”

---

**Finding:** [4.2.1. Bucket Accounting Desync On Exemption Transition](5.txt) (`agents/audit-findings/5.txt`)**Important qualification to the original write-up:** The report overstated impact by calling the balance "permanently stuck" in all cases. The issue was governance-controlled rather than permissionless, and an operator could sometimes recover by moving the holder back into an exempt role. So the strongest accurate characterisation was: real bug, but primarily an admin / role-transition footgun rather than a generic public exploit.

**Resolution implemented:** The protocol now enforces bound-role lifecycle on-chain in `src/modules/BoundRegistry.sol::_setBoundLevel`:

- `BOUND_EXEMPT` and `BOUND_DEX` are bootstrap-only roles, assignable only from `BOUND_NONE`.
- Once a `(factory, who)` pair is `BOUND_EXEMPT` or `BOUND_DEX`, that role is immutable.
- Post-bootstrap admin may only transition `BOUND_NONE <-> BOUND_ENDPOINT`.

This removes the `EXEMPT -> tracked` transition that made the desync reachable in normal admin flows, and also blocks later downgrades of privileged exempt/dex roles.

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` now records this explicitly under the bound-role lifecycle invariant (`MKT-04A`), making the bound lifecycle a structural precondition for the LCC bucket-accounting invariants rather than an off-chain governance note only.

**Suggested record:** TP in the original design, now resolved by on-chain lifecycle enforcement for bound roles. Residual risk is operational only in the sense that bootstrap role assignment must still be correct, but the problematic exempt-boundary transition is no longer available as a routine admin action.

---

**Finding:** [4.2.3. Exempt Status Transition Bucket Desync](7.txt) (`agents/audit-findings/7.txt`)

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

---

**Finding:** [4.2.6. Fee On Transfer Reserve Inflation](10.txt) (`agents/audit-findings/10.txt`)

**Classification:** True positive as a conditional unsupported-underlying bug / listing-policy gap; not resolved in code, but now explicitly scoped out by protocol invariants.

**Summary:** This finding is materially real if a fee-on-transfer, transfer-tax, deflationary, or similarly non-transfer-conservative ERC20 is ever admitted as a direct underlying. `LiquidityHub._wrap(...)` mints and credits `directSupply` / `reserveOfUnderlying.direct` from the nominal `amount`, not from an actual balance delta measured after transfer. The report is directionally correct that this can inflate direct reserve accounting relative to actual hub holdings. However, the right framing is not "the protocol should support these tokens by measuring actual received only at wrap" - that would be incomplete, because later Hub ↔ vault / issuer / settlement transfers are also amount-based and would still lose value on each hop.

**What is real:** The current contracts assume standard ERC20 transfer semantics for direct underlyings:

- `src/LiquidityHub.sol::_wrap(...)` increments direct reserve accounting and mints LCC from the requested amount after calling ERC20 `transferFrom`, without validating a pre/post received delta;
- `src/libraries/CurrencyTransfer.sol::transferFrom(...)` safely performs the transfer, but does not normalise for taxed / skimmed / rebasing behaviour; and
- other protocol legs (`prepareSettle`, vault settlement, underlying transfers) are likewise amount-based, so supporting fee-on-transfer assets safely would require broader architectural treatment than a local `_wrap` patch.

**Important qualification to the original write-up:** The report slightly overstates the right remediation if read as "just credit the actual received amount and the problem is solved". That would improve ingress accounting, but it would not make raw fee-on-transfer underlyings generally safe for the protocol. The real issue is that these token types do not fit the protocol's direct-underlying model.

**Action taken:** The protocol documentation and invariants have been updated to make the supported asset model explicit:

- `contracts/evm/INVARIANTS.md` now states that raw fee-on-transfer / transfer-tax / deflationary tokens are **not supported directly** as underlyings;
- it also records that raw rebasing assets are not preferred direct underlyings where they would break amount-based accounting assumptions; and
- it documents the intended support route for non-standard assets: use a deterministic wrapper/share token (for example an ERC-4626-style share token or a `wstETH`-style wrapper) as the listed underlying, rather than the raw token itself.

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` now includes a dedicated `Supported underlying asset model` section, and `HUB-01` now explicitly states that its 1:1 wrapping invariant for ERC20 underlyings assumes a standard, transfer-conservative underlying token model.

**Suggested record:** TP, conditional on admitting unsupported raw underlyings. Current action is protocol-scope clarification and wrapper-based support guidance, not a code-path fix for raw fee-on-transfer tokens.

---

**Finding:** [4.2.7. Stuck Eth In Payable Erc20 Wrap](11.txt) (`agents/audit-findings/11.txt`)

**Classification:** True positive; now resolved by rejecting stray ETH on ERC20-backed wrap flows.

**Summary:** This finding was materially real. `LiquidityHub.wrap*` entrypoints are `payable`, and before the fix `LiquidityHub._wrap(...)` only validated `msg.value` for native-underlying LCCs. For ERC20-backed LCCs, any attached ETH was silently accepted into the Hub while the function proceeded to pull ERC20 and mint LCC normally. Because ETH attached to a `payable` function call does not pass through `receive()`, the `receive()` sender validation did not protect this path.

**What was real:** Two issues existed:

- accidental ETH sent alongside an ERC20 wrap became stuck in `LiquidityHub`, because there was no matching recovery path for arbitrary users; and
- the Hub's native-balance-backed reserve check in `confirmTakeBalanceInvariant(...)` used raw `address(this).balance`, so unrelated stray ETH could make native reserve accounting appear more backed than it really was.

**Important qualification to the original write-up:** The report is directionally correct about reserve contamination risk, but it somewhat overstates exploitability if read as a generic public drain. The bug is best characterised as a real accounting-integrity and stuck-funds issue with conditional cross-lane impact on native-backed reserve checks, not as a standalone unrestricted theft primitive.

**Resolution implemented:** `src/LiquidityHub.sol::_wrap(...)` now rejects non-zero `msg.value` whenever the listed underlying is ERC20-backed, while preserving the existing strict equality check for native-backed wraps.

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` now makes the wrap guard explicit: native-backed wraps require `msg.value == amount`, and ERC20-backed wraps require `msg.value == 0`.

**Suggested record:** TP, now resolved by the `_wrap` guard hardening.

---

**Finding:** [4.2.9. Subscriber Dos On Modify Liquidity](13.txt) (`agents/audit-findings/13.txt`)

**Classification:** False positive / mischaracterised operational risk — not a standalone exploitable vulnerability as written.

**Summary:** The report correctly observes that Uniswap's `Notifier` bubbles subscriber callback failures on the `_notifyModifyLiquidity` path, and that in Fiet the subscribed `DirectLPDeltaResolver` ultimately calls `MarketFactory.afterModifyLiquidity(poolKey)`. If that callback chain reverts, subscribed direct-LP modify operations can revert. However, the write-up overstates this as a general vulnerability. The realistic preconditions are governance or deployment failures such as broken resolver wiring, bounds misconfiguration, or internal protocol settlement reverts, not a permissionless external exploit.

**What is real:** There is a genuine liveness dependency for subscribed direct-LP positions: the resolver must remain correctly protocol-bound and able to clear CoreHook hook deltas inside the same unlock session. If that path is broken, modify-liquidity operations that rely on it can fail.

**Important correction to the original write-up:** The suggested `unsubscribe(tokenId) -> modify` workaround is real in the narrow sense that users can remove a broken subscriber, but it is not a universal fix. `DirectLPDeltaResolver` exists specifically to clear non-zero hook deltas (`feeAdj`) for direct-LP flows; if a modification actually produces such deltas, removing the subscriber can still leave the batch reverting with `CurrencyNotSettled()`. So the correct framing is not "users can always safely bypass the issue by unsubscribing", but rather "subscriber removal may unblock some cases while disabling the resolver path that certain fee-adjusted flows depend on".

**Relationship to 4.1.1:** Same general callback-coupling family as the burn finding, but on the `_notifyModifyLiquidity` path rather than `_removeSubscriberAndNotifyBurn`. The operational dependency is real; the claim of an independently exploitable vuln is overstated for the same reason.

**Suggested record:** FP, or "design / ops assumption" rather than vuln. If retained, rewrite as: subscribed direct-LP modify flows depend on resolver/factory wiring remaining healthy; admin misconfiguration can cause liveness failures, and unsubscribe is only a partial escape hatch because some flows require same-batch hook-delta clearing.

---

**Finding:** [4.2.8. Transient Storage Seized Flag Leakage](12.txt) (`agents/audit-findings/12.txt`)

**Classification:** False positive / intended protocol behaviour, with an explicit same-batch seizure-context assumption.

**Summary:** The finding correctly observes that `TransientSlots.setSeizedPositionId(positionId)` is not cleared inside `_seizePosition(...)` itself and instead remains live until `PositionManagerEntrypoint._afterBatch()`. However, that is the intended execution model for seizure batches, not an accidental authorisation leak. The seizure context is deliberately scoped to the same `positionId` for the remainder of the current unlock batch so that the guarantor can complete follow-on settlement and take flows on that seized position before batch finalisation.

**Why this is intended in current code:**

- `_isSeizing(positionId)` is **position-scoped**, not global; it only returns true when the currently queried `positionId` matches the transient seized ID.
- `AUTH-01` in `contracts/evm/INVARIANTS.md` already states that settlement / modify actions require owner approval **except in seizure context**.
- The test suite intentionally exercises `SEIZE_POSITION -> SETTLE_POSITION_FROM_DELTAS -> TAKE` as a valid seizure flow, and separately tests that the transient context is cleared after batch completion so it cannot leak into a later batch in the same transaction.
- `VTSOrchestrator.onMMSettle(..., isSeizing=true)` re-checks seizability, and `VTSPositionLib._settleSeizing(...)` clamps settlement by RFS / required-settlement state, so the follow-on actions are still bounded by seizure-specific economics rather than becoming an unrestricted second drain primitive.

**Important correction to the original write-up:** The claim that this "violates the invariant that only the position owner/approved can perform settlement operations" is inaccurate for the current protocol model. The invariant is narrower: owner/approved is required **unless operating in the active seizure context for that same position within the current batch**.

**What would be a real bug instead:** If the seized-position context were usable for a different `positionId`, or if it persisted across batch boundaries / later unlock sessions, that would be a genuine approval-bypass issue. The current code clears the transient slot in `_afterBatch()`, and the existing tests explicitly cover that boundary.

**Spec / invariant update:** `contracts/evm/INVARIANTS.md` should state this more explicitly: same-batch follow-on actions on the seized position are intentional, but the seizure context must remain both **position-scoped** and **batch-scoped** and be cleared at batch end.

**Suggested record:** FP for current code; retain only as a design note that future refactors must not broaden seizure context beyond the current same-position, same-batch model.

---

**Finding:** [4.2.10. Missing Source Contract Validation](14.txt) (`agents/audit-findings/14.txt`)

**Classification:** False positive as an exploitable vulnerability in the current deployment / trust model; valid defence-in-depth hardening note only.

**Summary:** The finding correctly observes an inconsistency in `HubRSC`: `_handleSettlementQueued(...)`, `_handleLiquidityAvailable(...)`, and `_handleMoreLiquidityAvailable(...)` do not explicitly check `log._contract`, while neighbouring handlers do. However, the report overstates exploitability. `HubRSC.react(...)` is `vmOnly`, so arbitrary users cannot feed forged `LogRecord`s on-chain, and the Reactive subscription layer already binds each observed topic to a specific source contract (`liquidityHub` or `hubCallback`). Under the intended model, those subscription filters are the primary trust boundary for which logs can reach these handlers.

**What is real:** There is a real asymmetry / hardening gap in the code:

- `src/HubRSC.sol` subscribes to `LCCCreated` and `LiquidityAvailable` specifically from `liquidityHub`, and to `Settlement*Reported` / `MoreLiquidityAvailable` specifically from `hubCallback`;
- `src/HubCallback.sol` additionally validates callback origin and expected spoke-per-recipient before emitting `SettlementQueuedReported`; but
- three `HubRSC` handlers still rely on the subscription layer rather than re-validating `log._contract` locally, unlike the guarded handlers and unlike the more uniform style in `SpokeRSC`.

**Why this is not presently a real vuln:** The report's exploit path requires the Reactive VM or subscription service to deliver logs that do **not** satisfy the exact `(chainId, contract, topic)` subscription registered by `HubRSC`. That is not a user-triggerable smart-contract exploit against the protocol contracts themselves; it is a failure of a trusted middleware assumption. In the current design, `HubRSC` is not intended to defend against arbitrary fabricated `LogRecord` input from untrusted callers.

**Important qualification to the original write-up:** The note about `_markLogProcessed(...)` including `log._contract` is technically true, but it does not by itself create an exploit. It only matters if an invalid-source log can reach `HubRSC` in the first place, and current contract wiring assumes the Reactive system enforces that boundary.

**Suggested record:** FP for current code as a standalone vulnerability. Keep as a defence-in-depth recommendation: add explicit `log._contract` checks to the three unguarded handlers for consistency and future-proofing, but do not treat the current state as a proven public exploit against the protocol.

---

**Finding:** [4.3.1. Unrecorded Token Transfer To Custodian](15.txt) (`agents/audit-findings/15.txt`)

**Classification:** False positive for the current implementation — not a real exploitable vulnerability; valid latent hardening note only.

**Summary:** The report correctly observes that `MMPositionActionsImpl._forwardQueuedLccToCustodian(...)` transfers LCC to `MMQueueCustodian` before calling `custodian.record(...)`, and that `record` is skipped when `tokenId == 0`. If that branch were ever hit, custody accounting would not track the slice and `release` keyed by `(tokenId, lcc, beneficiary)` would not return those tokens. However, commitment NFT token IDs are assigned starting at `1` (`VTSCommitLib._commitSignalInternal` uses `commitId = ++s.nextCommitId`), and every path that reaches `_modifySyntheticLiquidity(..., tokenId, ...)` first validates the commitment: normal flows use `MMHelpers.assertApprovedOrOwner`, which calls `ownerOf(tokenId)` and reverts for non-existent IDs; seizure and other flows load position state via `VTSOrchestrator.getPosition` / equivalent checks. There is no reachable caller that passes `tokenId == 0` for queued LCC forwarding under the current call graph.

**What is real:** The `if (tokenId > 0)` guard is a footgun for future refactors. If a new code path ever invoked `_forwardQueuedLccToCustodian` with `0` without the same invariants, tokens could be sent to the custodian without a matching `record`, stranding them relative to `MMQueueCustodian.queued` / `release`.

**Important correction to the original write-up:** Framing this as "irreversibly lost with no mechanism to track" overstates present risk. The custodian still holds the ERC20 balance; the failure mode is **untracked custody** relative to the protocol's keyed accounting, not automatic burn. The practical issue is inability to release via the normal `record`/`release` path until governance or an upgrade intervenes — and that scenario does not arise today because `tokenId == 0` is not a valid commitment id.

**Suggested record:** FP for current code. Optional hardening: `require(tokenId != 0)` (or always `record` and revert if custodian recording fails) before transfer so the invariant "forward implies recorded slice" cannot be broken by a future mistake.
