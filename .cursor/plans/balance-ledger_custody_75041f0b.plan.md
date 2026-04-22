---
name: Balance-Ledger Custody
overview: "Supersede shadow-ledger semantics: `MMQueueCustodian` is a beneficiary-scoped custody wallet whose real balances plus Hub queue are the sole MM receivable state; collect is a normative manager-mediated pull; policy for unsolicited balances and ProxyHook deficit routing is explicit; commitment NFTs do not gate queue custody."
todos:
  - id: lock-custody-model
    content: Lock source-of-truth, unsolicited-balance policy, and ProxyHook deficit rules in docs/spec before code changes.
    status: completed
  - id: refactor-custodian
    content: Remove durable `_queuedLcc` / `record` / shadow `totalQueuedLcc`; custodian release reads real balances only.
    status: completed
  - id: rewrite-collect
    content: Implement normative ordered collect in MMPositionManager; exact locker credit; no `entitled = totalQueuedLcc` gate.
    status: completed
  - id: decouple-commit-lifecycle
    content: Strip owner-custodian prerequisites from decommit/grace; gates only for inactive settled remnants.
    status: completed
  - id: refresh-tests-docs
    content: Update INVARIANTS, tests, fuzz harnesses, and cross-reference beneficiary plan as superseded by this doc.
    status: completed
isProject: false
---

# Balance-Ledger Custody (Canonical Follow-Up)

This document **supersedes** the shadow-ledger wording still implied by [`.cursor/plans/beneficiary_custodian_redesign_a2270032.plan.md`](.cursor/plans/beneficiary_custodian_redesign_a2270032.plan.md) for custodian accounting. Implementation should treat **this** file as the source of truth for the custodian / collect end-state.

## 1. Target outcome

- [`contracts/evm/src/MMQueueCustodian.sol`](contracts/evm/src/MMQueueCustodian.sol) is a **beneficiary-scoped custody wallet** bound to one `MMPositionManager` and one immutable `beneficiary()`.
- **MM receivable state** for collect is derived only from:
  - `LiquidityHub.settleQueue(lcc, custodian)`
  - **actual** custodian-held LCC balance (`ILCC.balancesOf(custodian)` / `balanceOf` as appropriate)
  - **actual** custodian-held underlying balance (native balance or `IERC20(underlying).balanceOf(custodian)`)
- [`contracts/evm/src/MMPositionManager.sol`](contracts/evm/src/MMPositionManager.sol) implements a **normative, ordered** `COLLECT_AVAILABLE_LIQUIDITY` reconciliation: settle live Hub queue when possible, then release pre-settled underlying already on the custodian, credit the **locker** on the manager by **exact amounts**, and require outward withdrawal via **`TAKE`** only.
- Commitment NFTs are **decoupled** from queue custody once value sits on the beneficiary custodian; remaining NFT gates apply only to **inactive settled remnants** (`CommitNotDrained` / SETTLE-03 style), not to Hub queue or custodian balances.

## 2. Source-of-truth rule (non-negotiable)

**Positive rule:** Collectable MM queue custody for a beneficiary is fully described by the tuple:

1. `hubQ = LiquidityHub.settleQueue(lcc, custodian)`
2. `lccOnCustodian` = custodian’s live LCC position (market-derived + wrapped components as needed for Hub settlement caps)
3. `uOnCustodian` = custodian’s underlying balance for that LCC’s underlying asset

**Negative rule:** No internal mapping (`_queuedLcc`, counters, or “entitlement” structs) may authorise release **beyond** what reconciling `hubQ`, real LCC balance, Hub reserves, and real underlying balance allows. If a helper view exists (e.g. a renamed `totalQueuedLcc`), it must be **purely derived** from (1)–(3) and documented as non-authoritative.

This explicitly replaces the current pattern:

```text
entitled = custodian.totalQueuedLcc(lcc)   // shadow ledger — must go
```

with balance-first caps in [`contracts/evm/src/MMPositionManager.sol`](contracts/evm/src/MMPositionManager.sol).

## 3. Policy decisions (locked in this plan)

### 3.1 Unsolicited balances on the beneficiary custodian

**Chosen policy:** Any **LCC** or **underlying** tokens held by a given `MMQueueCustodian` instance are treated as **that custodian’s beneficiary’s receivable state** for MM collect / release purposes, subject only to:

- Hub settlement accounting (`processSettlementFor`, reserves, queue caps), and
- protocol bounds / manager-only entrypoints on the custodian.

Rationale: with one custodian per beneficiary and no shadow ledger, there is no on-chain distinction between “protocol placed” vs “externally transferred” value without adding a second book. Griefing via unsolicited transfer is accepted as **beneficiary windfall** (same class of issue as donating to an EOA wallet).

If product later requires “protocol-only collectible”, that becomes a **new** admission-filter workstream (not dual-book): e.g. tag deposits via transient allowlist or separate vault contract — **out of scope** for balance-as-ledger v1.

### 3.2 `INITIALISE` only

Keep explicit [`INITIALISE`](contracts/evm/src/libraries/MMActions.sol) as the sole custodian provisioning path; do not reintroduce auto-deploy on `transferFrom` / `commitSignal`.

### 3.3 ProxyHook deficit recipients and custodians

**Chosen policy:** An [`MMQueueCustodian`](contracts/evm/src/MMQueueCustodian.sol) **may** appear as `deficitRecipient` on the [`ProxyHook`](contracts/evm/src/ProxyHook.sol) deficit path (`transfer` + [`LiquidityHub.queueForTransferRecipient`](contracts/evm/src/LiquidityHub.sol)). Under §3.1, LCC and eventual underlying that land on that custodian are **beneficiary-global receivable** for that beneficiary’s collect surface once Hub rules are satisfied.

This closes **`31_7`-style** “queue without custodian ledger row” ambiguity: there is **no** row — the balance **is** the ledger.

If governance ever wants to forbid targeting custodians from public swap surfaces, that is a **policy tighten** on `ProxyHook` / Hub admission, not a return to `_queuedLcc`.

## 4. Custodian refactor (remove shadow-ledger ambiguity)

Update:

- [`contracts/evm/src/MMQueueCustodian.sol`](contracts/evm/src/MMQueueCustodian.sol)
- [`contracts/evm/src/interfaces/IMMQueueCustodian.sol`](contracts/evm/src/interfaces/IMMQueueCustodian.sol)
- All call sites of `record` / `totalQueuedLcc` (e.g. [`contracts/evm/src/MMPositionActionsImpl.sol`](contracts/evm/src/MMPositionActionsImpl.sol), tests, fuzz mocks)

**Required:**

- **Delete** `_queuedLcc` and the **`record(...)`** write path.
- **Delete** durable **`totalQueuedLcc(...)`** as an entitlement source; if a view remains for ergonomism, implement it only as `return IERC20(lcc).balanceOf(address(this));` (or equivalent) and name it so it cannot be mistaken for queued principal separate from balance (or remove entirely).
- **`releaseSettledUnderlyingToManager`** must transfer out up to `min(requested, uOnCustodian)` for that underlying, without consulting a shadow mapping.
- **`unwrapLccViaHub`:** stop incrementing internal ledger on `queuedDelta`; after unwrap, custodian LCC balance + `hub.settleQueue` reflect state. Optionally assert canonical hub via `ILCC(lcc).hub()` instead of caller-supplied `hub` if not already enforced.
- Preserve **manager-only** mutators, native/WETH fallback payout to `positionManager`, and empty `receive()` for Hub native settlement.

**Forbidden:** a “transition period” where both `_queuedLcc` and balances authorise release. Migrations must be **single-book** (see §9).

## 5. Collect algorithm (normative, ordered)

Update [`contracts/evm/src/MMPositionManager.sol`](contracts/evm/src/MMPositionManager.sol): `_collectAvailableLiquidity`, `_collectSettleHubQueueForCustodian`, `_releasePreSettledCustodianUnderlying` (or their successors) must implement **exactly** this order:

1. **Identify custodian:** `locker = msgSender()`, `custAddr = custodianFor[locker]`, assert `IMMQueueCustodian(custAddr).beneficiary() == locker` and factory-bound custodian rules ([`MMHelpers.assertQueueCustodianForRecipient`](contracts/evm/src/libraries/MMHelpers.sol)).
2. **Measure Hub queue:** `hubQ = LiquidityHub.settleQueue(lcc, custAddr)`.
3. **Measure custodian LCC:** use `ILCC(lcc).balancesOf(custAddr)` (and `balanceOf` if needed) for settlement caps consistent with Hub.
4. **Measure custodian underlying:** `uBal` on `custAddr` for `ILCC(lcc).underlying()` (native: `custAddr.balance`).
5. **Measure reserve:** `reserveMarket` from [`reserveOfUnderlyingTuple`](contracts/evm/src/LiquidityHub.sol) (and direct leg if ever relevant) — match Hub settlement caps.
6. **Live settlement slice:**  
   `settleLive = min(maxAmount, hubQ, lccOnCustodian components per Hub rules, reserveMarket)`  
   If `settleLive > 0`: call `liquidityHub.processSettlementFor(lcc, custAddr, settleLive)`, then pull resulting underlying from custodian to manager **only up to what Hub actually delivered to custodian** (typically `settleLive` in underlying units after burn — implementation must use measured delta or Hub-documented behaviour to avoid double count).
7. **Pre-settled release slice:** with remaining `maxAmount` budget, release `min(remaining, uOnCustodian)` from custodian to manager (native vs ERC20 paths unchanged).
8. **Credit locker:** credit the locker on `MMPositionManager` by **exact released underlying amounts** per step (avoid balance-wide `_syncBalanceAsCredit` unless the amount is proven equal to the intentional release).
9. **Outward withdrawal:** user completes wallet payout only via **`TAKE`** in the same or a later batch.

**Replaces:** any `entitled = custodian.totalQueuedLcc(lcc)` or `preSettledLcc = entitled - hubQLive` logic that assumes a shadow book.

## 6. Commitment lifecycle decoupling (tightened language)

- **`DECOMMIT_SIGNAL` / `EXTEND_GRACE_PERIOD`:** remove [`assertQueueCustodianForCommitToken`](contracts/evm/src/libraries/MMHelpers.sol) / owner-custodian coupling if still present. Queue custody on the **beneficiary** custodian must not block burning the NFT once VTS drain rules for inactive settled remnants are satisfied.
- **`transferFrom`:** must not reintroduce `CommitCustodyNotDrained`-style checks tied to queue custodian buckets.
- **Keep** `CommitNotDrained` / inactive remnant counters where they reflect **VTS `pa.settled`** economics, not Hub queue on the MM custodian.

## 7. Queue producers and deficit-routing audit

Re-verify under balance-as-ledger:

- [`contracts/evm/src/MMPositionActionsImpl.sol`](contracts/evm/src/MMPositionActionsImpl.sol) — `_queueSettleRecipient`, `_forwardQueuedLccToCustodian`, hook queue recipient keyed to acting beneficiary / locker.
- [`contracts/evm/src/modules/PositionManagerImpl.sol`](contracts/evm/src/modules/PositionManagerImpl.sol) — custody forward + `planCancelWithQueue` recipient.
- [`contracts/evm/src/MMPositionManager.sol`](contracts/evm/src/MMPositionManager.sol) — `_unwrapToQueueForward`.
- [`contracts/evm/src/ProxyHook.sol`](contracts/evm/src/ProxyHook.sol) — deficit recipient + `queueForTransferRecipient` when recipient is `MMQueueCustodian` (§3.3).

**Remove** any producer dependence on `record(...)` side effects. Comments referencing `qCommitted` should read as `settleQueue(lcc, queueOwner)` with `queueOwner == custodianFor[actingBeneficiary]`.

## 8. Tests and documentation

### Tests (non-exhaustive)

- [`contracts/evm/test/MMQueueCustodian.t.sol`](contracts/evm/test/MMQueueCustodian.t.sol)
- [`contracts/evm/test/MMPositionManager.t.sol`](contracts/evm/test/MMPositionManager.t.sol)
- [`contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`](contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol)
- [`contracts/evm/test/fuzz/FuzzMMQ01.sol`](contracts/evm/test/fuzz/FuzzMMQ01.sol)
- [`contracts/evm/test/fuzz/harnesses/PositionManagerImplQueueCustodyHarness.sol`](contracts/evm/test/fuzz/harnesses/PositionManagerImplQueueCustodyHarness.sol)
- [`contracts/evm/test/fuzz/mocks/FuzzQueueCustodyMocks.sol`](contracts/evm/test/fuzz/mocks/FuzzQueueCustodyMocks.sol)

### Regressions to add or refresh

- Exact-amount ERC20 credit on collect (no ambient sync over-credit).
- Collect after permissionless `processSettlementFor` (pre-settled underlying on custodian).
- Collect after NFT transfer / decommit (queue remains on beneficiary custodian).
- Seizure queue routed to **seizer** custodian.
- Fresh recipient must `INITIALISE` before queue paths.
- **Deficit routed to custodian:** queue + later collect under §3.1 / §3.3.
- **Unsolicited transfer** to custodian becomes collectible under §3.1 (document expected behaviour).

### Documentation

- [`contracts/evm/INVARIANTS.md`](contracts/evm/INVARIANTS.md) — MM queue custody section: balance-as-ledger, §2 negative rule, collect order, §3 policies.
- [`agents/spec/MMPositionManager.md`](agents/spec/MMPositionManager.md) if it describes collect / custody.
- [`.cursor/plans/beneficiary_custodian_redesign_a2270032.plan.md`](.cursor/plans/beneficiary_custodian_redesign_a2270032.plan.md) — add a one-line banner at top: **“Custodian accounting: see `balance-ledger_custody_75041f0b.plan.md`.”** (when editing that file is allowed in the same change set).

## 9. Risks and migration

### Risk A — Commitment vs beneficiary semantic drift

Once queue value sits on the beneficiary custodian, **do not** assume it follows `tokenId` ownership. Re-audit any helper that inferred entitlement from NFT owner rather than locker / beneficiary.

### Risk B — Protocol-originated vs arbitrary custodian balances

Under §3.1, **any** token landing in the custodian affects collectable surface. Mitigation is social / product (do not publish custodian as generic payment address) or a future admission-filter design — not a second shadow ledger.

### Migration — forbid dual-book transitions

If any deployment ever stored `_queuedLcc`-style state:

- **Do not** run a long-lived mode where both shadow mapping and balances can authorise release.
- One-shot migration: either clear shadow state on upgrade and rely on balances + Hub queue only, or freeze custodian and redeploy — pick explicitly in the implementation PR for that environment.

## 10. Still-relevant PR #220–style hygiene

- Validate deployed custodian addresses in [`contracts/evm/src/MMPositionManager.sol`](contracts/evm/src/MMPositionManager.sol) before writing `custodianFor`.
- Optional: deployment observability on [`contracts/evm/src/MMQueueCustodianFactory.sol`](contracts/evm/src/MMQueueCustodianFactory.sol).
- Canonical Hub usage in custodian unwrap path.
- Reject reintroducing NFT-owner-domain queue custody; beneficiary-global model stands.
