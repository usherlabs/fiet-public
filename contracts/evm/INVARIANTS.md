# Fiet EVM Protocol Invariants

This document describes **protocol-level invariants** enforced by the EVM contracts under `contracts/evm/src`.
It is intended for auditors, integrators, and test authors.

Wherever possible, each invariant is anchored to the **enforcement point** (the exact revert/guard) rather than
being an informal “should”.

## Scope and terminology

- **Invariant taxonomy**: headings in this file are **base / conservative v1** guarantees. Optional label: treat these as **`BASE-*`** when you need a stable prefix in new prose or tooling. Legacy capability-specific annex material (fee-sharing / coverage-index economics) was removed with fee disablement; see repository history if you need the old text.
- **Underlying**: the “real” token (ERC20 or native ETH represented as `address(0)` internally).
- **LCC**: `LiquidityCommitmentCertificate` (`src/LCC.sol`), a protocol-bound ERC20 that represents claims across
  multiple liquidity domains.
- **Core pool**: Uniswap v4 pool whose currencies are **LCCs**.
- **Proxy pool**: Uniswap v4 pool whose currencies are **underlyings**.
- **VTS**: “Value-to-Signal” accounting and settlement system coordinated by `src/VTSOrchestrator.sol`.
- **Commit (commitId)**: a VRL-verified reserve signal stored in VTS state (`VTSCommitLib.commitSignal`).
- **Position (positionId)**: a VTS-tracked liquidity position keyed like Uniswap positions.
- **RfS / RFS**: “Required for Settlement”; when open, withdrawals are restricted.
- **Deficits**:
  - **cumulativeDeficit**: swap-driven outflow shortfall accumulated per position; it feeds pool-level deficit
    principal aggregates (`totalDeficitPrincipal`) alongside growth settlement.
  - **commitmentDeficit**: position-level insolvency gate derived from commitment backing checks; used for
    RFS/seizability hardening and distinct from swap-attributed pool deficit principal (`totalDeficitPrincipal`).
- **Settlement buckets (`PositionAccounting`)**:
  - **`settled`**: live settled amount per lane, **capped** by `commitmentMax` for that lane.
  - **`settledOverflow`**: deferred positive settlement that does not fit under the current `commitmentMax` headroom
    (economic value is still tracked; it is not discarded). Together they form **effective settled** per lane for
    RFS, commitment-backing USD checks, and pool `totalSettled` aggregates. `getPositionSettledAmounts` returns **effective**
    settled (live + overflow). For the lane split, use `getPositionSettledOverflowAmounts` and subtract from effective per lane,
    or read live `pa.settled` via internal storage layouts off-chain only when appropriate.

## Supported underlying asset model

- **Protocol assumption / listing precondition**:
  - Direct protocol underlyings are assumed to have **deterministic transfer semantics** for protocol accounting
    windows:
    - transferring `amount` to the Hub / vault / settlement path must result in the receiver controlling `amount`,
    - transfers must not silently burn / tax / skim value in-flight, and
    - balances must not rebase unpredictably during accounting-critical flows.
  - Therefore, raw **fee-on-transfer / transfer-tax / deflationary** tokens are **not supported directly** as
    underlyings.
  - Raw **rebasing** assets are also **not preferred direct underlyings** where their balance model would break
    amount-based accounting assumptions across Hub / vault / settlement flows.
- **Support model for non-standard assets**:
  - If the protocol wishes to support such assets, it should do so via a **deterministic wrapper/share token** whose
    own transfer semantics are standard and whose deposit/withdraw path internalises the non-standard behaviour.
  - In practice this means the protocol should treat the **wrapper/share token** as the underlying (for example an
    ERC-4626-style share token, or a `wstETH`-style non-rebasing wrapper), rather than the raw fee-on-transfer or
    rebasing asset itself.
- **Why this matters**:
  - Large parts of `LiquidityHub`, `MarketVault`, and settlement accounting are **amount-based**, not
    balance-delta-measured on every hop.
  - Making only `wrap()` actual-received-aware would not by itself make fee-on-transfer assets safe, because
    subsequent Hub ↔ vault / issuer / settlement transfers could still lose value and desynchronise reserves.
- **Current code status**:
  - Native ETH ingress is explicitly exact (`msg.value == amount`) on wrap paths; plain ETH to `LiquidityHub.receive`
    is restricted to authorised vault senders (see **HUB-01A**).
  - Native ETH settlement egress: EOAs receive raw ETH first, then WETH on transfer failure; contracts receive raw ETH
    only if they EIP-165 support `INativeSettlementReceiver` (for example `MMQueueCustodian`); all other contracts
    receive ERC20 WETH directly so payable sinks such as WETH9 cannot credit `msg.sender` instead of the nominal recipient.
  - ERC20 ingress currently assumes standard ERC20 transfer behaviour; this assumption should be treated as part of the
    market-listing policy unless and until explicit on-chain rejection / normalisation is added.

## LCC backing and liquidity domains

### LCC-BACKING-01: Every LCC mint must correspond to a specific backing domain (no “free mint”)

- **Statement**: Any increase in LCC supply must be attributable to **exactly one** of the protocol’s backing domains
  (or a domain-preserving conversion), and must only be reachable through the protocol’s authorised mint surfaces.
  Concretely, LCCs represent **claims on liquidity** in one of these domains:

  - **Domain A — Wrapped / out-of-market (Hub-reserved underlying)**:

    - LCC is minted **1:1** against underlying deposited into `LiquidityHub`.
    - This corresponds to the `directSupply` / `wrappedBalances` notion for non-protocol holders.
    - The backing asset is _immediately_ reflected in `LiquidityHub.reserveOfUnderlying(underlying)`.
    - **Direct-backed** mints (`directAmount > 0` on `LCC.mint`) must **not** target **bucket-exempt** (`BOUND_EXEMPT`)
      endpoints: exempt holders skip per-address bucket maps, which would desynchronise Domain A from holder buckets and
      allow exempt→non-protocol transfers to reclassify liquidity as market-derived without the wrapped-only DEX ingress
      path (`prepareMarketLiquidity` / **LCC-03**).

  - **Domain B — In-market (market-derived liquidity claims, including queued settlement claims)**:

    - LCC is minted by an **issuer** (eg ProxyHook, VTSOrchestrator) to represent liquidity that exists (or is being
      routed) _inside the market system_ (PoolManager / MarketVault), rather than as Hub-held underlying reserves.
    - Where immediate underlying is not available for redemption, the claim is represented explicitly via the
      `LiquidityHub` settlement queue (`settleQueue` / `totalQueued`) rather than by pretending Hub reserves back it.

  - **Domain C — Signal-materialised (VRL-backed MM issuance)**:

    - LCC is minted for MM position increases only when the position’s issued commitment value is backed by the sum of:
      - on-chain settled value, and
      - verified VRL signal value,
        i.e. \(issuedUsd \le settledUsd + signalUsd\).

  - **Domain conversion — LCC↔LCC wrapWith (domain-preserving re-expression)**:
    - `wrapWith` must conserve value by converting one LCC claim into another without creating net backing; it may
      reclassify between “wrapped” and “market-derived” buckets, but must not mint value from nothing.
    - **Step-2 Hub queue netting (backing LCC)**: when market-derived balance nets against
      `settleQueue[withLCC][address(this)]`, the implementation must **eagerly** decrement the same durable triple as
      other queue paths (`settleQueue`, `totalQueued`, `queueOfUnderlying` for the shared underlying). This keeps
      `unfundedQueueOfUnderlying` and vault funding logic aligned with economically outstanding queue debt (no separate
      shadow “lazy claim” overlay in live logic; the `nettedLCCsAsUnderlying` storage slot is deprecated and retained
      only for layout compatibility).

- **Enforced by (authorised mint surfaces)**:

  - **Domain A**: `src/LiquidityHub.sol::_wrap` transfers underlying in, increments
    `directSupply[lcc]` and `reserveOfUnderlying[underlying]`, then mints LCC; user-facing `_wrap` / `_wrapWith` reject
    protocol-bound recipients (`Errors.MintToNotAllowedRecipient`); `src/LCC.sol::mint` rejects `directAmount > 0` to
    `BOUND_EXEMPT` where applicable (`Errors.MintToNotAllowedRecipient`). `issue` uses DEX-only rejection
    (`_assertRecipientNotDexSink`) so issuer mints to exempt endpoints (eg ProxyHook) remain valid for pure market-derived balance.
  - **Domain B**: `src/LiquidityHub.sol::issue` is `onlyIssuer(lcc)` and mints market-derived amount via the LCC hub
    mint path; issuer gating is enforced by `LiquidityHub._onlyIssuer` (valid LCC + issuer allowlist).
  - **Domain C**: `src/libraries/VTSPositionMMOpsLib.sol::_handleLiquidityIncrease` calls
    `src/libraries/VTSCommitLib.sol::validateMmIncreaseLiquidityDelta(..., revertIfInsufficientBacking=true)`, which
    enforces **post-add** endpoint-max backing \(issuedPost \le settledUsd + signalUsd\) and a **marginal** cap on the
    oracle-valued actual minted principal for this step:
    \(mintDeltaUsd \le issuedAdmission(postL) - issuedAdmission(preL)\). On failure it reverts
    `Errors.InvalidLiquiditySignal(...)` (global shortfall) or `Errors.InvalidAdmissionMintDelta(...)` (marginal mint
    vs admission delta).
  - **Domain conversion**: `src/LiquidityHub.sol::_wrapWith` delegates to `LiquidityHubLib.wrapWithPrepare` /
    `LiquidityHubLib.wrapWithContext` and then mints the target LCC split as `(directToMint, marketToMint)`; any
    mismatch is treated as a library logic bug (see inline comments).

- **Enforced by (supply strictness / cannot bypass domain accounting)**:
  - LCC token minting is callable only by the Hub (`src/LCC.sol::mint` is `onlyHub`).
  - Issuer-only issuance/cancellation paths are additionally guarded against invalid/uninitialised LCCs
    (`src/LiquidityHub.sol::_onlyIssuer` calls `LiquidityHubLib.assertValidLcc(...)`).

## Liquidity, LCC, and “protocol-bounded” transfer semantics

### LCC-01: User-to-user LCC transfers are disallowed unless one endpoint is protocol-bound

- **Statement**: A transfer of LCC must be either mint/burn, or have **at least one** endpoint that is a protocol-bound
  address.
- **Enforced by**:
  - `src/LCC.sol::_isProtocolTransfer` (logic)
  - `src/LCC.sol::_beforeTransfer` (reverts `Errors.TransferNotAllowed()` when neither endpoint is protocol-bound)
  - Protocol-bound endpoints are determined by `IMarketFactory.bounds(address)`.
- **Why**: LCCs are _market compatibility primitives_, not freely transferable assets. This prevents bypassing
  settlement/queue semantics and reduces misclassification risk for downstream integrations.

### LCC-02: LCC bucket accounting must remain consistent with transfer flow

- **Statement**: For non-protocol → protocol transfers, queued-settlement ownership must be annulled before bucket
  decrement to prevent “bleeding” into the queue.
- **Enforced by**:
  - `src/LCC.sol::_beforeTransfer` calls `LiquidityHub.annulSettlementBeforeTransfer(...)` for non-protocol → protocol
    transfers.
  - `src/LiquidityHub.sol::annulSettlementBeforeTransfer` adjusts `settleQueue` / `totalQueued` if a transfer would
    implicitly consume queued claims.

### LCC-03: Nested ingress settlement preserves canonical `sync(lcc) -> transfer -> settle()` windows

- **Statement**:
  - During `LCC -> PoolManager` ingress reporting, `MarketFactory.prepareMarketLiquidity(...)` must not leave the active
    PoolManager sync context corrupted for the outer payment flow.
  - Wrapped (direct-backed) DEX ingress must run only inside an **active** `sync(lcc)` window on `PoolManager`. If the
    manager is unlocked but no currency is synced (`syncedCurrency == address(0)`), ingress must **not** call Hub→vault
    settlement: doing so would strand LCC on `PoolManager` without matching synced reserves and could brick later
    canonical `sync(lcc) -> transfer -> settle()` flows.
  - If `prepareMarketLiquidity` executes while the active synced currency is this same `lcc`, it must:
    - allow only the first unpaid ingress transfer in that sync window, and
    - restore `sync(lcc)` after nested settlement side-effects.
  - For native-underlying lanes, the temporary clear of ERC20 sync context (native reset) is allowed only inside this
    controlled same-`lcc` branch, followed by restoring `sync(lcc)`.
- **Enforced by**:
  - `src/MarketFactory.sol::prepareMarketLiquidity`
    - Reads PoolManager transient slots (`Currency`, `ReservesOf`) through `exttload`.
    - Reverts when there is no active sync window for ingress (`Errors.IngressRequiresActiveSync`), via
      `src/libraries/MarketLiquidityRouterLib.sol::prepareMarketLiquidityIngress`.
    - Reverts when sync currency is different (`Errors.NestedIngressSyncCurrencyMismatch`).
    - Reverts when a prior unpaid ingress already exists (`Errors.NestedIngressUnpaidTransferExists`).
    - Reverts on invalid snapshot ordering (`Errors.NestedIngressInvalidSyncSnapshot`).
    - Re-syncs `lcc` after nested ingress handling.
- **Supported payment shape**:
  - Canonical Uniswap v4 ERC20 settlement window:
    - `sync(lcc)`
    - one `LCC -> PoolManager` transfer
    - `settle()`
- **Non-goal**:
  - Non-canonical flows that perform multiple unpaid `LCC -> PoolManager` transfers inside one active `sync(lcc)`
    window are unsupported and intentionally revert.
- **Ingress amount**: `prepareMarketLiquidity` is invoked with the **wrapped (direct-backed) slice** of the transfer only;
  market-derived balance does not trigger Hub→vault mobilisation on that hop. Domain A liquidity must therefore remain in
  bucket-tracked holders until ingress if that mobilisation is required.

### HUB-01: Wrapping mints 1:1 and increases Hub reserves

- **Statement**: `wrap`/`wrapTo` must:
  - transfer `amount` underlying into the hub, and
  - increment `directSupply[lcc]` and `reserveOfUnderlying[underlying]` by `amount`, and
  - mint `amount` LCC to the recipient.
- **Enforced by**: `src/LiquidityHub.sol::_wrap`.
- **Notable guard**:
  - native-asset wrap requires `msg.value == amount`, otherwise `Errors.InvalidAmount`.
  - ERC20-backed wrap requires `msg.value == 0`, otherwise `Errors.InvalidAmount`.
  - User-facing wrap recipients must not be protocol-bound (`Errors.MintToNotAllowedRecipient`), covering endpoint, exempt,
    and DEX roles in one check; issuer-only `issue` remains the path to protocol sinks (DEX mints still revert via the same
    error). See **LCC-BACKING-01** Domain A.
- **Asset-model assumption**:
  - For ERC20 underlyings, this invariant assumes the listed underlying is a **standard, transfer-conservative token**
    whose received amount equals the nominal transfer amount.
  - Raw fee-on-transfer / transfer-tax / deflationary tokens are therefore outside the supported direct-underlying
    model for this invariant.
  - If support is needed for a non-standard asset, the supported route is to list a deterministic wrapper/share token
    as the underlying and let that wrapper absorb the raw asset's non-standard deposit / withdrawal semantics.

### HUB-01A: Inbound plain ETH (`receive`) is sender-gated (factory-scoped canonical vault only)

- **Statement**: Plain ETH sent to `LiquidityHub` outside of `wrap` must come only from the factory-scoped canonical
  vault address: `msg.sender` must expose `marketFactory()` such that `LiquidityHub.isFactory(marketFactory)` holds and
  `IMarketFactory(marketFactory).canonicalVault() == msg.sender` (the concrete type may be minimal; tests use mocks that
  only implement `marketFactory()` plus whatever the guard reads).
- **Enforced by**: `src/LiquidityHub.sol::_assertValidEthSender` (used by `receive()`).
- **Why**: Market liquidity mobilisation sends native ETH from `CanonicalVault` to the Hub before `confirmTake`; Hub
  ingress must bind to that custody address, not to arbitrary contracts or per-market facades.

### HUB-02: Unwrapping cannot exceed liquid (bucketed) balance; only market-derived shortfall may queue

- **Statement**: Unwrap requires `0 < amount <= availableToUnwrap`, where `availableToUnwrap` is the caller’s live
  bucketed balance (`wrappedBalance + marketDerivedBalance` for `msg.sender`) minus any existing settlement queue for
  the same `(lcc, queueTo)` key: `max(0, fromBalance - settleQueue[lcc][queueTo])`. The wrapped / direct-backed slice
  (`min(amount, wrappedBalance)`) must redeem **in full** against `directSupply` in the same transaction or the call
  reverts (`Errors.InvalidAmount`); it must **not** degrade into queued external settlement. Only the **market-derived**
  slice may record a new queue entry when `useMarketLiquidity` returns less than the market-derived remainder (see
  `LiquidityHubLib.unwrapInternalLogic` and market-derived-only redemption in `processSettlementLogic` for external
  recipients).
- **Enforced by**:
  - `src/LiquidityHub.sol::_unwrap` reverts `Errors.InvalidAmount(amount, availableToUnwrap)` when out of bounds.
  - `LiquidityHubLib.unwrapInternalLogic(...)` reverts when the wrapped slice exceeds `directSupply`, when the
    market-derived remainder is positive but `marketDerivedBalance == 0`, and only calls `queueSettlement` for
    unsatisfied **market-derived** remainder after `useMarketLiquidity`.
  - Queue state is observable via `LiquidityHub.settleQueue(lcc, recipient)` and `LiquidityHub.totalQueued(lcc)`.
- **Why**: External settlement queues are **market-derived claims**; allowing wrapped/direct shortfall to queue would
  desynchronise queue ownership from what `processSettlementFor` can redeem. Headroom netting against
  `settleQueue[lcc][queueTo]` remains correct because both the liquid balance and the queue refer to the same economic
  slice for the beneficiary.

### HUB-02A: MM queue custody uses custodian self-unwrap (`unwrap`); Hub has no `unwrapTo`

- **Statement**: `LiquidityHub` only exposes public unwrap entrypoints `unwrap(address,uint256)` and
  `unwrap(address,bytes32,uint256)` (resolved LCC). There is **no** split “payout recipient ≠ queue owner” API on the Hub.
  For MM queued settlement, `MMPositionManager` moves beneficiary LCC onto the per-recipient `MMQueueCustodian`, which calls
  `hub.unwrap(lcc, amount)` **as itself**. Hub shortfalls therefore accrue to `settleQueue[lcc][custodian]`, while any
  immediate underlying is received by the custodian and forwarded to `forwardUnderlyingTo` (native: typically
  `MMPositionManager` for exact delta credit; ERC20: locker or manager per routing). `MarketFactory` dynamic “bind
  custodian endpoint” registration is not required for this flow.
- **Enforced by**:
  - `src/MMQueueCustodian.sol::unwrapLcc` (unwrap + `settleQueue` delta + forward underlying; canonical Hub via `ILCC(lcc).hub()`),
  - `src/MMPositionManager.sol::_unwrapToQueueForward`,
  - `src/LiquidityHub.sol::unwrap` / `_unwrap` / `_unwrapAndPay`.
- **Collect (manager-mediated pull)**: `COLLECT_AVAILABLE_LIQUIDITY` decodes **`(lcc, maxAmount)`** only (two 32-byte words; legacy three- or four-word encodings are rejected). The action is scoped to the batch locker’s custodian (`custodianFor[msgSender()]`) and requires `IMMQueueCustodian.beneficiary() == msgSender()`. Collect reconciles **`LiquidityHub.settleQueue(lcc, custodian)`**, **actual custodian LCC balance** (`ILCC.balancesOf` / `ERC20.balanceOf`), **Hub reserves**, and **actual custodian underlying balance** — **no shadow ledger**: nothing may authorise release beyond those signals. Settlement runs in order (live Hub settlement then pre-settled underlying flush); the locker is credited via **`creditExact`** for known released amounts (**native** or **ERC20 underlying**); **wallet payout** is completed only through a subsequent **`TAKE`** (same or later batch).
- **Post-shortfall custody (`UNWRAP_LCC`)**: Queued shortfall does not burn LCC at queue time; LCC held on the **acting beneficiary’s** custodian plus Hub queue state constitute receivable custody — principal is not unscoped router residue on `MMPositionManager` (**DELTA-02**). For `payerIsUser` flows, measure the delta **after**
  pulling LCC into the manager (`transferFrom`), because non-protocol → protocol transfer can annul prior queue entries
  (**LCC-02**) before the custodian unwrap runs.
- **Native-backed `UNWRAP_LCC` (underlying `address(0)`)**: `LiquidityHub` pays native to the custodian during `unwrap`
  (`MMQueueCustodian` EIP-165 opts in via `INativeSettlementReceiver`); the custodian immediately forwards to
  `MMPositionManager` so the locker’s `receive()` does not run inside the Hub call. The locker withdraws native via
  `TAKE(ADDRESS_ZERO, ...)` in the same batch.
- **Rationale**: A public Hub `unwrapTo` surface duplicated queue-owner vs payout semantics and required endpoint-only
  admission. Collapsing unwrap actor and queue owner onto the custodian preserves HUB-02 headroom netting while keeping
  split payout handling in MM composition code (custodian forward), not as a generic unwrap variant.

### MM-QUEUE-01: Beneficiary-scoped queue custodians; explicit `INITIALISE`; balance-as-ledger receivables

- **Statement**:
  - `MMPositionManager.custodianFor[beneficiary]` maps **at most one** `MMQueueCustodian` per **beneficiary** (MM batch locker / acting party). Each deployed custodian stores an **immutable** `beneficiary()` equal to that address; internal custody is **not** further keyed by commitment NFT id.
  - **`MMQueueCustodian` is a beneficiary-scoped custody wallet**, not a separate entitlement book: **actual** LCC and underlying token balances on the custodian, together with **`LiquidityHub.settleQueue(lcc, custodian)`**, are the MM receivable surface for collect. **Unsolicited** LCC or underlying sent to a custodian is treated as that **beneficiary’s** receivable for MM collect / release purposes (subject to Hub settlement rules and manager-only custodian entrypoints); distinguishing “protocol-placed” vs arbitrary donation would require a separate admission-filter design.
  - Custodian creation is **explicit** via the utility action **`INITIALISE`** (`MMActions.INITIALISE`), which calls `_deployQueueCustodian(msg.sender)` and is **idempotent** when a custodian already exists. **`commitSignal` and `transferFrom` do not auto-deploy** queue custodians; any flow that forwards or collects queued principal for a party must therefore ensure that party has called `INITIALISE` first, or it reverts fail-closed (`Errors.QueueCustodianNotDeployed`, and related guards). There is **no** `LiquidityHub.unwrapTo` and **no** `MarketFactory` dynamic custodian binding for this model.
  - Queued principal **after forwarding** to the beneficiary custodian is **not** commitment-scoped property on the router: **`transferFrom` does not gate** draining that receivable (no `CommitCustodyNotDrained`-style checks tied to queue custody). **`DECOMMIT_SIGNAL` / `EXTEND_GRACE_PERIOD`** must not require the NFT owner to have deployed a queue custodian; remaining commitment NFT gates apply only to **inactive settled remnants** (`CommitNotDrained` / SETTLE-03), not Hub queue or custodian balances.
  - **Seizure / multi-party routing**: Hub queue entries route to the **acting beneficiary’s** custodian (for example the **seizer’s** address for seizure-queued principal), not a synthetic “owner domain + internal bucket” split on a single custodian contract.
  - **`ProxyHook` deficit paths** may target an `MMQueueCustodian` as deficit recipient; LCC / underlying that land on that custodian follow the same balance-as-ledger semantics once Hub rules are satisfied.
- **Enforced by**:
  - `src/MMPositionManager.sol::_deployQueueCustodian`, `_handleUtilityAction` (`INITIALISE`),
  - `src/libraries/MMHelpers.sol::assertQueueCustodianForRecipient`,
  - `src/MMQueueCustodian.sol` (`unwrapLcc`, `release`; optional view `totalQueuedLcc` = on-chain LCC balance only),
  - `src/MMPositionManager.sol::_unwrapToQueueForward`, `_collectAvailableLiquidity`.
- **Native ETH to `MMPositionManager`**: immediate native forwarded from a bound `MMQueueCustodian` after Hub `unwrap`
  is accepted in `FietNativeWrapper.receive` only when `MMPositionManager._isCustodian(msg.sender)` holds: `msg.sender` must
  be exactly `custodianFor[beneficiary]` for the beneficiary reported by `IMMQueueCustodian.beneficiary()` on that contract,
  distinct from canonical Hub payouts.

### HUB-02B: Unwrap immediate payout recipients must be serviceable (not Hub, exempt, or DEX)

- **Statement**: On every unwrap path, the immediate underlying payout address `to` must not be `address(0)`, the Hub
  itself, any `BOUND_EXEMPT` address, or any `BOUND_DEX` address. This is independent of queue-owner validation on
  `queueTo`: the Hub may still attribute queued settlement to `address(this)` where Hub-internal queue semantics apply,
  but underlying must never be pushed to unserviceable protocol sinks (for example proxy-hook/facade).
- **Enforced by**: `src/LiquidityHub.sol::_assertValidUnwrapPayoutRecipient` inside `_unwrap` before `_pay`.
- **Why**: Exempt endpoints are not unwrap payout targets; paying them strands underlying outside durable custody and
  settlement accounting.
- **Implementation note**: `MarketVaultFacade.receive()` is fail-closed and reverts **all** plain ETH ingress
  (`Errors.InvalidEthSender`), including for `ProxyHook`. Native market liquidity is accounted via `CanonicalVault` /
  `PoolManager` claims, not unbooked ETH balance on the facade.

### HUB-02C: Native external settlement payout shape (EOA, opt-in contracts, WETH fallback)

- **Statement**: For native-underlying settlements on the external recipient path, `processSettlementFor(...)` must
  remain serviceable and must not strand value on the Hub when the nominal recipient is a contract that does not
  implement the protocol’s explicit native-receiver capability.
- **Enforced by**:
  - `src/libraries/LiquidityHubLib.sol::transferUnderlying` for `underlying == address(0)`:
    - **EOAs** (`recipient.code.length == 0`): attempt raw native transfer first; on failure, wrap via
      `LiquidityHub.weth9()` and transfer WETH as ERC20 (counterfactual / non-payable contract after queue time).
    - **Contracts** that EIP-165 support `INativeSettlementReceiver` (for example `src/MMQueueCustodian.sol`): same
      raw-first, WETH-on-failure behaviour as EOAs.
    - **All other contracts** (including canonical WETH9): skip raw native push; wrap and transfer WETH as ERC20 to
      the nominal recipient **only when that recipient is a valid non-sink external payout target** (see **HUB-02D**;
      canonical `WETH9` must not be used as the queued settlement owner / nominal payout address for reserve-funded
      external settlement).
- **Why**:
  - Queue-time checks cannot guarantee future native payability for counterfactual addresses; EOAs and opt-in contracts
    still need the raw-then-WETH failure path.
  - Payable contracts that accept ETH but credit wrapped assets to `msg.sender` (not the nominal recipient) would
    otherwise clear queues while mis-delivering value; WETH-first for unsupported contracts closes that class.

### HUB-02D: External reserve-funded settlement recipients (issuer deficit queue + cancel-with-queue + runtime)

- **Statement**:
  - Issuer-created external reserve-funded settlement queues (`queueForTransferRecipient`, and the queued leg of
    `cancelWithQueue` / planned cancel-with-queue) must not target **protocol-bound** recipients in the factory
    namespace (`boundLevelOfLcc != BOUND_NONE`, i.e. `BOUND_ENDPOINT`, `BOUND_EXEMPT`, or `BOUND_DEX`).
  - The same policy is revalidated at `processSettlementFor(...)` entry for external recipients (`recipient != Hub`) so
    legacy or regressed queued state cannot spend reserves against forbidden recipients.
  - Objective sink addresses are also rejected for those external paths: `recipient == weth9()` when the LCC underlying
    is native (`address(0)`), and `recipient == underlying` when the LCC underlying is an ERC20.
  - Hub self-queue (`recipient == address(this)`) remains valid where existing Hub-internal semantics apply.
  - For **non-bound** recipients, the Hub remains agnostic about EOA vs contract; **callers / integrators** engaging the
    protocol must nominate recipients capable of receiving and handling **ERC20-compatible** settlement assets (native
    lanes may still deliver WETH to unsupported contracts per **HUB-02C**).
- **Enforced by**:
  - `src/LiquidityHub.sol::_assertExternalReserveFundedSettlementRecipient` (delegates sink checks to
    `LiquidityHubLib::_assertUnderlyingPayoutRecipientNotSink`; used from `_assertQueueRecipientServiceable`,
    `_cancelWithQueue` when `queueAmount > 0`, and `_processSettlementFor`).
  - Defence in depth at payout: `src/libraries/LiquidityHubLib.sol::_assertUnderlyingPayoutRecipientNotSink` inside
    `transferUnderlying` before reserve mutation.
- **Why**: Protocol-bound endpoints and exempt/DEX sinks are not durable external settlement owners for reserve-funded
  payout; canonical `WETH9` and the underlying ERC20 contract are objective blackholes as nominal queue/payout owners.

### HUB-03: Issuer-gated issuance/cancellation must never operate on invalid LCCs

- **Statement**: Any issuer-only path must first validate that the target `lcc` is a valid, initialised LCC.
- **Enforced by**:
  - `src/LiquidityHub.sol::_onlyIssuer` calls `LiquidityHubLib.assertValidLcc(...)` and checks issuer status, otherwise
    reverts `Errors.NotApproved`.

### HUB-04: LCC pairs must be from the same market factory

- **Statement**: Operations that treat an LCC pair as a market must ensure both LCCs belong to the same factory.
- **Enforced by**: `src/LiquidityHub.sol::getFactory` reverts `Errors.InvariantViolated("LCCs are not from the same market")`.

### HUB-05: `confirmTake` is balance-backed (reserves cannot be fabricated)

- **Statement**: `LiquidityHub.confirmTake(lcc, amount, ...)` must never increase
  `reserveOfUnderlying(underlying(lcc))` beyond the Hub’s **actual underlying balance**.
  This invariant must hold even if `confirmTake` is reached during nested call flows (including callback-style paths).
- **Enforced by**:
  - `src/LiquidityHub.sol::confirmTake` reverts `Errors.InsufficientBalance(actualBalance, reserveAfter)` if
    `reserveOfUnderlying[underlying] > actualUnderlyingBalanceHeldByHub`.
- **Why**:
  - `confirmTake` is intentionally _not_ guarded by `nonReentrant` so that future flows can safely allow
    `useMarketLiquidity → ... → confirmTake()` callback patterns.
  - The balance-backed check ensures this flexibility cannot be abused to “mint” reserves via re-entrancy.

### HUB-06: `prepareSettle` must preserve direct-liquidity accounting consistency

- **Statement**: Preparing direct liquidity for vault settlement must reduce both:

  - shared-underlying direct reserve (`reserveOfUnderlying[underlying].direct`), and
  - per-LCC direct inventory (`directSupply[lcc]`),
    by the same `amount`.

  This prevents a drift where `directSupply[lcc]` overstates immediately serviceable direct liquidity after a settle
  preparation step.

- **Enforced by**:
  - `src/LiquidityHub.sol::prepareSettle` computes `maxSettleableDirect = min(reserveDirect, directSupply[lcc])`,
    reverts `Errors.InvalidAmount(amount, maxSettleableDirect)` when exceeded, then decrements both counters by
    `amount`.
- **Why**:
  - `unwrap` direct-path eligibility uses `directSupply[lcc]` (`LiquidityHubLib.unwrapInternalLogic`), while payout
    direct serviceability enforces direct reserve availability (`LiquidityHubLib.transferUnderlying`).
  - Keeping these counters synchronised avoids invalid intermediate states where direct unwrap appears available but is
    not currently payable.

## Swap attribution and growth accounting (economic correctness)

### VTS-01: “Settle growths before modify liquidity” (no retroactive accrual capture)

- **Statement**: Before a position’s liquidity changes, any owed growth (fees/deficit/inflow/coverage indices) must be
  settled against the **pre-modification** liquidity.
- **Enforced by**:
  - `src/CoreHook.sol::_beforeAddLiquidity` and `_beforeRemoveLiquidity` call
    `VTSOrchestrator.settlePositionGrowths(...)`.
  - `src/VTSPositionLib.sol::settlePositionGrowths` performs the settlement sequencing and explicitly notes this as a
    fairness requirement.
- **Why**: Without this, new liquidity could capture historical growth by increasing the multiplier in
  \((growthInsideNow - growthInsideLast) \* liquidity\).

### VTS-02: Tick-cross “outside flip” must preserve inside-growth queryability

- **Statement**: On each tick cross, the “outside” growth values must be flipped as `outside := global - outside`.
- **Enforced by**:
  - `src/libraries/VTSSwapLib.sol::_flipOutside` implements the Uniswap-style flip.
  - `src/libraries/VTSPositionLib.sol::_growthInsideSingle` relies on this invariant to compute inside growth using
    (global, outsideLower, outsideUpper, tickCurrent).

### VTS-03: Swap outcomes must be reflected via segment-based deficit/inflow growth

- **Statement**: Swaps accrue:
  - **deficit growth** on the output token per segment, and
  - **inflow growth** on the input token net of fees per segment.
  - Settled against positions, this flow updates `cumulativeDeficit` (swap-incurred principal). It does not create
    `commitmentDeficit`, which is only checkpoint/backing derived.
- **Enforced by**:
  - `src/VTSOrchestrator.sol::afterCoreSwap` → `src/libraries/VTSSwapLib.sol::processSwap`
  - `VTSSwapLib._accrueSegmentGrowth`, `_accrueDeficitGlobalGrowth`, `_accrueInflowGlobalGrowth`.
- **Implementation note**: `CoreHook` snapshots the authoritative pre-swap `slot0.tick` (with `sqrtPBefore` and
  liquidity) into transient storage for `processSwap`. Tick-indexed attribution must not reconstruct the pre-swap
  tick from `sqrtPBefore` alone, because at exact tick boundaries Uniswap may store `tick = T - 1` while
  `getTickAtSqrtPrice(sqrtPrice) == T`.
- **Remainder carry (path independence)**: Per-position crystallisation of deficit/inflow growth uses `CarryQ128Lib`
  in `src/types/Carry.sol` (semantic `GrowthCarryQ128` wrapper in `VTS.sol`) tied to `PositionAccounting.deficitGrowthCarry` / `inflowGrowthCarry` so repeated `settlePositionGrowths` calls
  preserve the same attributed totals as a single settlement over the same aggregate inside-growth delta (sub-Q128
  remainders are carried, not discarded on each checkpoint). Snapshot rebases (`_initDeficitSnapshot` /
  `_initInflowSnapshot` / `_checkpointTickIndexedSnapshots`) zero these carries together with `*GrowthInsideLast`.

## Commitment backing, signals, and insolvency gates

### COMMIT-ROLE-01: Commitment owner and advancer are intentionally distinct roles

- **Operating model / protocol assumption**:
  - `mmState.owner` is the durable identity for the market maker's signalled state and is expected to correspond to the
    operator's high-security custody / approval authority.
  - `mmState.owner` may therefore be a smart contract / hardened custody wallet; it is **not** required to be an EOA.
  - `mmState.advancer` is the lower-friction operational identity used to renew VRL-backed MM state (renew proof
    principal) and, on-chain, is the required **locker** for ordinary non-seizing MM operations (`locker == advancer`).
  - **`mmState.advancer` is account-shape agnostic**: the protocol does not require a plain EOA or any particular bytecode
    at `advancer`. Proof inclusion and `ISignalVerifier` govern whether a signal is accepted; the advancer address is part
    of the signed Merkle leaf and stored state, not a runtime EOA/7702 classification.
  - **Relay caveat**: `VRLSignalManager.verifyLiquiditySignalRelayed` still authenticates relay payloads with
    **`ECDSA.recover(...) == sender`** on the EIP-712 digest. That path is therefore usable only by accounts that can
    satisfy ECDSA recovery to `sender` (typically EOAs or EIP-7702-delegated accounts that present as EOAs for signing).
    It does **not** implement ERC-1271 / `SignatureChecker`. Contract-shaped advancers may still verify via the direct
    submitter path (`verifyLiquiditySignal`) or through a **factory-bound** orchestrator caller that submits on behalf
    of the advancer per `VTSCommitLib._resolveRenewProofPrincipal`.
  - **Fresh-commit custody**: On the direct `MMPositionManager` fresh-commit path, the commitment NFT is minted to
    `mmState.owner`. On the relayed fresh-commit path, EIP-712 `RelayAuth` includes a `sender` field: either an
    explicit recipient (must equal the batch locker) or `address(0)` meaning custody to the proof principal (`mmState.owner`).
    Renew relay: EIP-712 `RelayAuth.sender` is `address(0)` (legacy) or `mmState.advancer`; `MMPositionManager` requires the
    batch locker (`msgSender()`) to match the signed sender when non-zero, or to be the advancer when the signed sender is zero.
    The EIP-712 domain uses `VRLSignalManager`
    version `"1"` (the `RelayAuth` struct adds fields without bumping the domain version).
  - These roles are intentionally **not** interchangeable, but they are expected to remain under the control of the
    same real-world operator / coordinated trust domain.
- **Practical consequence**:
  - A plain ERC-721 transfer of the commitment NFT is **not**, by itself, an on-chain handover of MM operational control.
  - `transferFrom(...)` changes NFT ownership only; it does not rotate the stored advancer or rewrite the committed MM
    identity.
  - Therefore, a live commitment NFT should not be treated as a freely saleable / independently operable position object
    unless the transfer is accompanied by off-chain coordination of the advancer / owner operating model.
- **Why**:
  - The protocol intentionally separates:
    - custody / approval authority (`ownerOf(tokenId)` / `mmState.owner`-anchored MM identity), and
    - hot-path MM execution / proof-submission authority (`mmState.advancer`).
  - This lets operators keep asset custody and approval flows on a more secure key while using a lighter operational key
    for maker actions and prover-facing workflows.
  - Relayed signal authorisation remains **ECDSA-only** (`recover` on the typed-data digest); it does not broaden relay
    auth to ERC-1271 or `SignatureChecker` verifiers.
- **Expressed by**:
  - `src/VRLSignalManager.sol` verifies signals via `ISignalVerifier` and nonce/expiry checks; it does not classify
    `mmState.advancer` by bytecode.
  - `src/libraries/VTSCommitLib.sol::_renewSignalInternal` preserves `mmState.owner` across renewals and authorises
    renewals via `mmState.advancer`.
  - `src/types/Commit.sol` stores `authorisedRelayer`, set at initial commit creation from the `VTSOrchestrator` caller
    (for example `MMPositionManager`). CoreHook MM operations require `processPosition(owner)` to match this address so
    `factory.bounds(owner)` alone cannot authorise a different bound endpoint to operate under another party's commit.
  - `src/libraries/VTSLifecycleLinkedLib.sol::validateMMOperation` requires the MM batch locker to equal the stored
    advancer for non-seizure MM operations, and (when `authorisedRelayer` is non-zero) requires the CoreHook position
    `owner` to equal that stored relayer.
  - `src/libraries/MMHelpers.sol::assertApprovedOrOwner` separately enforces ERC-721 owner / approval authority on the
    relevant `MMPositionManager` entrypoints.
- **Non-goal**:
  - The protocol does **not** guarantee that transferring an active commitment NFT alone transfers full MM operating
    authority to the recipient.

### SIG-00: VRL root signatures are deployment-agnostic (cross-chain syndication)

- **Statement**: The `ECDSASignatureSignalVerifier` root attestation signs `(nonce, rootStateHash)` under `eth_sign` without `chainId` or verifying-contract binding. **This is intentional:** VRL state is treated as a single source of truth off-chain; the same signed proof may verify on multiple Market Chain deployments as **state synchronisation**, not as accidental cross-deployment replay. Per-deployment freshness is `mmNonce[mmState.owner]` in **each** `VRLSignalManager` instance only.
- **Enforced by (signature shape)**: `src/verifiers/ECDSASignatureSignalVerifier.sol::verifyProof`.
- **Enforced by (local replay floor)**: `src/VRLSignalManager.sol::_verifyLiquiditySignalInternal` and optional `seedMMNonce` / `seedSubmitAuthNonce` for replacement deployments.
- **Authoritative note**: `agents/spec/VRL-Cross-Chain-Proof-Syndication.md` (amendment 2026-04-19).

### SIG-01: VRL nonce must be strictly monotonically increasing per MM

- **Statement**: A new signal for an MM must have `signal.nonce > mmNonce[mmState.owner]`.
- **Enforced by**: `src/VRLSignalManager.sol::_verifyLiquiditySignalInternal` reverts
  `Errors.InvalidNonce(newNonce, prevNonce)` otherwise.

### SIG-02: Signal verification must succeed (or revert when requested)

- **Statement**: When a call requests revert-on-invalid, an invalid proof must revert.
- **Enforced by**: `src/VRLSignalManager.sol::verifyLiquiditySignal(address,bytes,bool)` reverts `Errors.InvalidProof()` when
  `revertOnInvalid && !ok`.

### COMMIT-00: `commitmentMax` must match live position liquidity (no path-dependent drift)

- **Statement**: `PositionAccounting.commitmentMax` for each token must equal the rounded-up CLMM maxima for the
  position’s tick range evaluated at the position’s **current live** Uniswap v4 position liquidity. It must not be
  maintained by incremental add/subtract of per-delta maxima alone, because per-delta `roundUp` amounts are not
  additive and can understate the true maxima for the remaining liquidity after partial removes.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_trackCommitment`, invoked from
  `touchPosition` after liquidity-changing modifies (new position, increase, decrease) and on active zero-delta
  touches to resynchronise against live `PoolManager` liquidity.

### COMMIT-01: Commitment backing must satisfy `issuedUsd <= settledUsd + signalUsd` (per-position, per-commit)

- **Statement**: Any MM liquidity increase that would cause the issued commitment value to exceed (settled + signalled)
  backing must revert. Additionally, the **oracle-valued** principal minted on this increase must not exceed the
  **marginal** endpoint-max admission budget for the same add:
  \(mintDeltaUsd \le issuedAdmission(postL) - issuedAdmission(preL)\).
- **Admission valuation (anti-manipulation)**: MM increase admission uses `VTSCommitLib::validateMmIncreaseLiquidityDelta`,
  which reuses `_issuedAdmissionValueForLiquidity` (same endpoint-max rule as `validateLiquidityDelta`): commitment
  maxima at the position ticks are valued at the **upper** and **lower** tick endpoint compositions in USD (via
  `OracleUtils::lccPairValue`), and the **maximum** of those two endpoint valuations is used per liquidity level. This
  deliberately avoids relying on pool `slot0` / current tick for admission, so same-transaction spot games cannot
  understate required backing. The protocol does **not** treat “arbitrage will restore the price” as a security
  invariant for admission.
- **Marginal mint gate**: `mintDeltaUsd` is `OracleUtils.lccPairValue` over the **actual** minted LCC amounts for the
  step (`preL` / `postL` are position liquidity immediately before and after the modify). This bounds spot-shaped minting
  against the incremental endpoint-max admission budget and complements the **global** post-add check
  \(issuedAdmission(postL) \le settledUsd + signalUsd\).
- **Checkpoint valuation (live state)**: `checkpointWithCommitment` / `_checkpointWithCommitment` continue to measure
  **current** issued exposure from live `slot0` and effective token amounts (`LiquidityUtils::calculateEffectiveTokenAmounts`)
  because that path answers solvency and `commitmentDeficit` state, not whether new liquidity may be admitted.
  `commitmentDeficit` and grace/bypass timers are **enforcement** after admission; they are not substitutes for
  conservative admission.
- **Enforced by**:
  - `src/libraries/VTSCommitLib.sol::validateMmIncreaseLiquidityDelta` computes `issuedPost`, settled, signal, admission
    at `preL` and `postL`, and reverts `Errors.InvalidLiquiditySignal(issuedPost, signalValue, settledValue)` when the
    global inequality fails, or `Errors.InvalidAdmissionMintDelta(mintValueUsd, admissionDeltaUsd)` when the marginal
    inequality fails.
  - `src/libraries/VTSCommitLib.sol::validateLiquidityDelta` remains the shared helper for other callers that only need
    the global post-add admission check (same `_issuedAdmissionValueForLiquidity` semantics).
  - Called during MM increases by `src/libraries/VTSPositionMMOpsLib.sol::_handleLiquidityIncrease` with
    `revertIfInsufficientBacking = true` (after non-zero mint amounts are known, before `liquidityHub.issue`).
  - MM increases pass **post-add total position liquidity** as `LiquidityDeltaParams.liquidityDelta` (not the incremental
    Uniswap modify delta alone), so repeated adds cannot each pass on a per-slice global check while cumulative post-add
    issuance exceeds `(settled + signal)` backing. The incremental modify delta is used only to recover `preL` from
    stored post-add liquidity for the marginal gate.

### COMMIT-02: Checkpointing with commitment updates `commitmentDeficit` as an insolvency gate

- **Statement**: A commitment checkpoint must set (or reduce/clear) `PositionAccounting.commitmentDeficit` in token
  units based on the USD backing shortfall.
- **Enforced by**: `src/libraries/VTSCommitLib.sol::checkpointWithCommitment`.
- **Ordering (growth before commitment)**: `checkpointWithCommitment` values backing from **effective** settled amounts
  (`pa.settled + pa.settledOverflow` per leg, via `VTSCommitLib`) together with effective issued amounts. Therefore `src/VTSOrchestrator.sol::checkpoint(..., withCommitment: true)` must settle
  position growths **before** delegating to `VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment` / `VTSCommitLib.checkpointAfterGrowthWithCommitment` (commitment path uses `VTSCommitLib.checkpointWithCommitment`), so
  uncrystallised deficit/inflow growth cannot make the commitment gate read stale-high `settled`. While the pool
  (or VTS globally) is paused, public `VTSOrchestrator.settlePositionGrowths` remains restricted to the canonical
  `CoreHook` for that market; the orchestrator-only helper `_settleGrowthsBeforeCheckpoint` performs the same
  `VTSPositionLib.settlePositionGrowths` work for paused commitment checkpoints only, without widening arbitrary
  third-party refresh on the public entrypoint.
- **Consequence**: Positions with non-zero `commitmentDeficit` can bypass normal grace only when the configured
  token-lane bypass age/severity gates in `SEIZE-01` are satisfied.
- **Separation invariant**: `commitmentDeficit` is a checkpoint-derived solvency gate and is not the pool swap-attributed
  deficit principal bucket. `totalDeficitPrincipal` tracks swap-incurred `cumulativeDeficit` at the pool level only.

### COMMIT-02A: Non-seizure MM liquidity changes blocked on **material** stored commitment deficit

- **Statement**: Any MM `touchPosition` with `liquidityDelta != 0` must revert unless the operation is a seizure
  (`hookData.seizure.isSeizing == true`), or the stored commitment deficit is not **material** for this gate.
  **Material** means any of:
  - `PositionAccounting.commitmentDeficitBps > 0`, or
  - for token lane `i` in `{0,1}`, `commitmentDeficit` for that lane is at least
    `pools[poolId].vtsConfig.token{i}.unbackedCommitmentGraceBypassThreshold` when that threshold is non-zero
    (the same per-token fields used in seizure bypass; `0` disables the threshold arm).
- **Not material (does not block MM add/remove)**: non-zero raw `commitmentDeficit` token units alone when
  `commitmentDeficitBps == 0` and every configured threshold is `0` or the lane is strictly below its threshold
  (e.g. sub-1 bps USD shortfall with exact proportional write and bps floored to 0). Checkpoint still persists the
  storage snapshot; seizure/risk policy uses `commitmentDeficit` / `SEIZE-01` separately.
- **Enforced by**: `src/libraries/CommitmentDeficitMMFreezeLib.sol::blocksNonSeizingMMLiquidityChange` (called from
  `src/libraries/VTSPositionLib.sol` on non-seizing MM path) reverts `Errors.CommitmentDeficitBlocksLiquidityChange`.
- **Rationale**: The checkpoint path records **exact** per-lane token deficits; treating every 1-wei residual like a
  full insolvency block would over-restrict ordinary MM flow. The gate is narrowed to bps severity and optional
  token thresholds, while **COMMIT-02** storage and `CheckpointLibrary` seizure path remain unchanged.
- **Rationale (continued)**: Closing live RFS (via settlement) does not necessarily clear stored `commitmentDeficit`;
  allowing MM add/remove while a **material** insolvency condition persists would desynchronise commitment context
  from checkpoint-derived state. MM no-ops (`liquidityDelta == 0`) and settlement / checkpoint paths remain
  available to cure or formalise backing.

### COMMIT-02B: Full liquidity mirror deactivation clears commitment-deficit storage

- **Statement**: When `positionLiquidityMirror` transitions from a value `> 0` to `0`, `commitmentDeficit` (both
  tokens), `commitmentDeficitSince`, and `commitmentDeficitBps` are reset to zero.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyLiquidityMirrorTransition`.
- **Rationale**: Issued commitment is zero after a full unwind; retaining token deficit amounts without a coherent age
  vector would be stale and could interact badly with deficit-age bypass logic. **COMMIT-02A** remains in force: MM
  still cannot change liquidity while a **material** stored commitment deficit would block the modify path, so this
  reset is not a way to “MM-remove past” the gate—it is the bookkeeping cleanup once deactivation is actually
  reached (including non-MM and seizure paths).

### COMMIT-03: “Advancer” binding for checkpoint-with-commitment must hold

- **Statement**: A checkpoint-with-commitment must only accept signals where:
  - the new signal’s owner matches the old owner, and
  - the `sender` equals `mmState.advancer`, and
  - `advancer != owner`.
- **Enforced by**: `VTSCommitLib.checkpointWithCommitment` reverts `Errors.InvalidSender()` when violated.

## Settlement, RFS, and seizure safety

### SETTLE-00: `settled`, `settledOverflow`, and **effective** settled

- **Statement**: **Effective** settled per lane is `pa.settled + pa.settledOverflow`. After every relevant mutation
  (positive/negative settlement and commitment-max refresh), the protocol **re-splits** canonically:
  `pa.settled = min(effectiveSettled, commitmentMax)` and `pa.settledOverflow = effectiveSettled - pa.settled`. Positive
  growth/MM settlement first nets **cumulative** then **commitment** deficits, then adjusts effective settled and applies
  that split. Negative settlement reduces effective settled (drawing **`settledOverflow` before** live `pa.settled` is an
  emergent property of the same normalisation). `_trackCommitment` recomputes `commitmentMax` from live liquidity, then
  applies the same normaliser so headroom reopening **collapses** overflow into live `settled` without a separate migration
  helper. **RFS**, **MM excess/over-withdraw clamps**, **checkpoint-with-commitment** settled USD, and **`_settledValueForPosition`**
  reason over this effective total; pool-wide **`totalSettled`** deltas include both lanes.
- **Enforced by**: `src/libraries/VTSPositionLib.sol` (`_vUpdateSettlementCore`, `_canonicalSettledSplitForLane`, `getRFS`,
  excess paths), `src/libraries/VTSCommitLib.sol` (`_checkpointWithCommitment`, `_settledValueForPosition`),
  `IVTSOrchestrator.getPositionSettledAmounts`, `IVTSOrchestrator.getPositionSettledOverflowAmounts`, and
  `PositionSettled` event fields for observability.

### Policy reference: seizure economics (amendment 2026-04-19)

- **Agents/spec**: Normative **economic intent** for guarantor seizure (base tranche, proportional cure of overdue RfS, position-wide aggregation) is documented in `agents/spec/Seizure-and-Base-Tranche-Policy.md`. That document supersedes older narrative in `agents/spec/Settlements.md` that described time-linear seizure sizing after grace.
- **Implementation note**: On-chain seized liquidity units are computed in `src/libraries/VTSLifecycleLinkedLib.sol::_calcSeizure`. The outer MM settle path captures **pre-intervention** RfS (`R_pre`) from `getRFS` immediately before settlement deposits mutate position accounting; `getRFS` compares requirements against **effective** settled (`settled + settledOverflow`) per lane. Per-lane **cured amount** is `S_eff = min(S_lane, R_pre)` from that snapshot (not from post-settlement remainders), so a transaction that **fully closes** RfS in the same step can still yield **non-zero** seized units when the snapshot showed overdue obligation. With commitment `C`, base rate `baseBps`, and denominator `B = 10_000`, seized liquidity units per step are `floor(L · inner / denom)` where: if `C == 0`, `inner = baseBps · S_eff`, `denom = B · R_pre`; else if `R_pre > C`, `inner = S_eff`, `denom = R_pre`; else if `baseBps · C ≥ B · R_pre`, `inner = baseBps · S_eff`, `denom = B · R_pre`; else `inner = S_eff`, `denom = C`. Fractional remainder is accumulated in **Q128** via `src/libraries/SeizureCarryQ128Lib.sol` into `PositionAccounting.seizureLiquidityCarry` (path independence across split cures **while a lane’s RfS remains overdue**). `LiquidityUtils.exposureBpsFloor` is **not** used for seizure sizing. After each **seizing** MM settle, `VTSLifecycleLinkedLib._executeMMSettleFromParams` clears per-lane carry for any lane whose **post-settlement** `getRFS` delta is no longer a positive open requirement (`<= 0`), so remainder does not roll into a later distinct RfS episode. Whenever RFS checkpoint marking runs (`src/libraries/Checkpoint.sol::markCheckpoint`), per-lane carry for any lane **not** present in the new open mask is also cleared—covering non-seizing settlement, checkpoints, and MM modifies that close an RFS lane without a seizing settle. Non-seizing commitment refreshes (including zero-delta `touchPosition` pokes that recompute `commitmentMax`) **preserve** carry on lanes that **remain** open in the same overdue shape. `VTSPositionLib._trackCommitment` with **zero** live liquidity clears all carry as terminal teardown. Per-lane carry is also cleared in `_calcSeizure` when `R_pre == 0` for that lane. `minResidualUnits` applies after this cumulative sizing step. **Coupling rule**: while batch-scoped seizure context is active for a position, **settle-only deposit** actions (`SETTLE_POSITION` / protocol-credit `SETTLE_POSITION_FROM_DELTAS` deposit paths / locker-credit deposit via `_settle` with negative lanes) must **not** run except for the single authorised deposit phase inside `SEIZE_POSITION`, so Q128 carry cannot advance without a matching liquidity decrease in the same logical operation. Treat `INVARIANTS.md` enforcement points as authoritative for **what reverts**; treat the agents spec as authoritative for **economic intent**, with this note describing **current sizing alignment**.
- **Known assumption — multi-call seizure is re-priced, not one-shot equivalent**: Repeated `SEIZE_POSITION` calls during the same overdue episode are **not** assumed to be economically equivalent to a single intervention that cures the same **aggregate** amount in one step. Each call snapshots the position’s **then-current** `R_pre` from `getRFS`, uses **then-current** live liquidity (and recomputed `commitmentMax` after any prior seizure decrease), sizes seized units for that step, and removes liquidity before a later step can run. Q128 carry makes **rounding** path-independent while a lane’s RfS remains overdue; it does **not** freeze an original episode baseline or make full seizure economics path-independent across separate transactions or calls.

### SETTLE-01: Withdrawals from active positions are disallowed while RFS is open

- **Statement**: If a position is active and RFS is open, withdrawals must revert (unless in seizure context).
- **Enforced by**: `src/libraries/VTSLifecycleLinkedLib.sol::_executeWithdrawals` reverts
  `Errors.RFSOpenForPosition(positionId)` when
  withdrawing while `rfsOpen`.

### SETTLE-02: Seizure settlement is clamped by RFS (for deposits) and by position-required settlement (for withdrawals)

- **Statement**: During seizure, deposits/withdrawals must be clamped to prevent over-settling or extracting value
  outside allowed bounds.
- **Protocol rule**:
  - Token-lane granularity does **not** alter the settlement mechanics once a seizure is under way.
  - After seizure has been authorised, settlement remains position-wide: any token-side settlement performed by the
    seizing party is processed under the seizure clamps for that position.
  - This is intentional because settlement on one side is economically incentivised by the collateralisation of assets
    in the counterpart token within the same position.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_settleSeizing` (deposit clamp uses positive RFS; withdrawal clamp
  uses `positionRequiredSettlementDelta`).

### SETTLE-03: MM decrease splits routing; batch-clearable delta vs deferred `settled`

- **Statement**:
  - For MM liquidity decreases, the excess settled entitlement relative to the reduced commitment is not a single
    homogeneous bucket for **routing** (vault-available immediate slice vs Hub queue vs value that must remain in live
    source `pa.settled` until it is serviceable).
  - Each economic sub-slice must have **exactly one** live representation after the decrease step: Hub-backed queue,
    MMPM underlying delta (`OwnerCurrencyDelta`) for the **vault-immediate** portion only, or still in source
    `pa.settled` — never two at once for the same slice.
- **Protocol rule**:
  - Coupled to **DELTA-01**: transient MMPM underlying deltas must be batch-clearable; only the vault-immediate slice is
    booked as positive owner underlying delta. Any shortfall that cannot be Hub-queued (principal-capped) and cannot be
    paid from the vault in the same unlock **stays in live source `settled`**, not on `OwnerCurrencyDelta`.
  - **User min-out vs routing principal**: `DECREASE_LIQUIDITY` / `BURN_POSITION` `amountMin` floors the per-leg **immediate
    post-netting non-fee LCC** (`LiquidityUtils.forwardedNonFeeLccAmount`), not hook-time pool principal
    `callerDelta - feesAccrued` used for cancel/queue caps in VTS. For **commit buckets** (`tokenId > 0`), only the
    Hub-queued slice `qCommitted` is physically forwarded to `MMQueueCustodian`; any surplus
    `nonFee - qCommitted` remains as **locker transient LCC credit** on `MMPositionManager` (cleared via `TAKE` /
    `UNWRAP_LCC` in the same batch). Informational accrued fees (`feesAccrued`) are classified separately from principal;
    queue principal remains bounded from `callerDelta - feesAccrued`.
  - **Source-side decrement (routed amount only)**: `_applySettlementClampFromExcess` removes the **routed export** from
    source `pa.settled` / pool `totalSettled` — for non-seizure decreases that is `settleableDelta + queuedDelta`; for
    seizure decreases it is the per-leg seizure export (`min(excess, settleable + burn)`, not the full queued principal
    remainder) — not the full `requiredSettlementDelta` when part of it must remain deferred in `settled`.
  - **Seizure MM decrease (guarantor)**: routing uses `_handleSeizureLiquidityDecrease` / `_computeSeizureLiquidityDecreaseRoutingSplit`.
    Per leg, `planCancelWithQueue` queues `principal - min(principal, excessSettled)` to the seizer (`locker`) and burns
    `min(principal, excessSettled)`; the settlement clamp uses `min(excess, settleable + burn)` so queued principal
    retained by the guarantor does not over-remove live `pa.settled`. Non-seizure decreases keep the shortfall-queue split unchanged.
  - **Consumption-based target credit**: another position’s `pa.settled` increases only when `_settle()` / `onMMSettle()`
    actually consumes protocol underlying delta or token flow (`MMPositionActionsImpl._netProtocolCredits` path), not
    merely because positive delta exists on MMPM.
  - **Directional settlement ordering** inside `onMMSettle()` is intentionally asymmetric:
    - deposits may still increase `pa.settled` before Phase-4 delta debt clearance, because they are moving value into
      the position;
    - withdrawals must consume any positive owner underlying delta first, then reduce `pa.settled` only for the
      residual amount that is still backed by live position settlement.
- **Enforced / expressed by**:
  - `src/libraries/VTSPositionLib.sol::_touchExistingDecrease` computes `requiredSettlementDelta` for the MM excess.
  - `src/libraries/VTSPositionMMOpsLib.sol::_computeLiquidityDecreaseRoutingSplit` (via `_handleLiquidityDecrease`)
    splits vault availability vs Hub-queued principal; `underlyingDeltaSettlement` for dynamic delta accounting equals
    the vault-immediate slice (`settleableDelta`) only.
  - Seizure decreases: `_computeSeizureLiquidityDecreaseRoutingSplit` + `_handleSeizureLiquidityDecrease` (same Hub/transient/custody handshake as ordinary decreases).
  - `src/libraries/VTSPositionMMOpsLib.sol::processMMOperations` (decrease branch): calls `_applySettlementClampFromExcess`
    with `exportedForSettlementClamp` from `_handleLiquidityDecrease` (`settleableDelta + queuedDelta`) for non-seizure,
    or from the seizure split for `isSeizing`, then `OwnerCurrencyDelta.accountUnderlyingSettlementDelta` for the immediate slice only.
  - `src/libraries/VTSLifecycleLinkedLib.sol::onMMSettle` plans withdrawals from positive underlying delta and
    settled-backed
    capacity separately, consumes the delta-backed portion first, and only then mutates `pa.settled`.
- **Why**:
  - Clamping only the queued shortfall while also booking the immediate slice on `OwnerCurrencyDelta` would double-count
    the same value as both live source `settled` and MMPM credit, enabling cross-position reuse without conservation.
  - Booking a principal-capped shortfall remainder as positive MMPM underlying delta while the vault cannot pay it in the
    same batch violates **DELTA-01** (uncleared transient delta at batch end).
  - The stricter withdrawal ordering prevents a later delta-backed settle from deducting the same exported value from
    source `pa.settled` a second time.
- **Regression / evidence (Foundry + audit)**:
  - `test/marketmaker/MMPositionMinOutFeeAdjIntegration.t.sol`, `test/modules/PositionManagerImpl.t.sol`,
    `test/marketmaker/MMPositionManager.t.sol`, `test/marketmaker/MMPositionActionsImpl.t.sol` (min-out vs hook principal;
    see [agents/audit-resolutions/3\_\_high-mm-min-out-pre-transfer-callerdelta-resolution.md](../../agents/audit-resolutions/3__high-mm-min-out-pre-transfer-callerdelta-resolution.md)).
  - Decrease routing / `VTSPositionMMOpsLib` integration: `test/libraries/VTSPositionLib.t.sol`,
    `test/libraries/VTSPositionLib.onMMSettle.t.sol`, harnesses under `test/libraries/harnesses/VTSPositionLibHarness.sol`.
  - Queue custody vs forwarded non-fee: [agents/audit-resolutions/mm-queue-custody-nonfee-vs-custodyforward-guard-resolution.md](../../agents/audit-resolutions/mm-queue-custody-nonfee-vs-custodyforward-guard-resolution.md) and **MMQ-01** (Echidna) in `test/fuzz/README.md`.

### SETTLE-03A: Inactive remnant withdrawal-only `onMMSettle` does not require a live VRL signal

- **Statement**: When `VTSOrchestrator.onMMSettle` runs **non-seizing** settlement, it normally requires a live
  VRL-backed commit (`isSignalValid(commitId, true)`). The **sole exception** is **withdrawal-only** settlement on an
  **inactive** position: both signed `amountDelta` lanes are withdrawals (`amount0 >= 0` and `amount1 >= 0` in the
  MM settle convention where negative means deposit). That path still requires an initialised commit
  (`isSignalValid(commitId, false)`), bound-factory caller, and `msg.sender == position.owner` (`MMPositionManager`), but
  does **not** require unexpired non-empty reserves. This keeps inactive `pa.settled` remnants drainable (and
  `Commit.inactiveRemnantCount` / decommit semantics consistent) after natural expiry or an empty-reserve renewal.
- **Enforced by**: `src/VTSOrchestrator.sol::onMMSettle` (live-signal assertion gated unless the carve-out applies;
  `owner` is asserted before `CheckpointLibrary.isSeizable` on seizure so unrelated callers do not observe RFS errors
  first).
- **Why**: Inactive positions already cap withdrawal capacity from stored `pa.settled` in
  `VTSLifecycleLinkedLib._planWithdrawalLane`; that slice is not fresh signal-backed issuance. Requiring a live signal
  there would deadlock decommit against `CommitNotDrained` when the advancer cannot or will not renew.

### MMQ-01: Queued principal must not exceed forwarded non-fee LCC on custody take-and-forward

- **Statement**: When routing Hub-queued principal (`qCommitted` / custody-forward) through
  `PositionManagerImpl._routeLccCustodyTakeAndForward` with a non-zero position-scoped `tokenId`, the immediate
  **non-fee** LCC amount after informational fee netting (`LiquidityUtils.forwardedNonFeeLccAmount`) must cover the queued
  slice being custodied, or the call reverts with `Errors.InsufficientBalance` (fail-closed vs under-collateralised commit
  custody). Under sound routing, queued principal is bounded by pool principal `callerDelta - feesAccrued`; informational
  `feesAccrued` does not reduce queue principal caps, so `nonFee < custodyForward` should be **unreachable** in valid
  states and indicates a regression, sequencing bug, or inconsistent coupling between VTS queue staging and the router’s
  actual post-hook receipt.
- **Enforced by**: `PositionManagerImpl` custody-forward path and `LiquidityUtils.forwardedNonFeeLccAmount` semantics
  (see audit resolution linked above). Locker delta is debited via `LiquidityUtils.lockerLccTakeAmountBeforeCustodyForward`
  only by the custodied amount for commit buckets; surplus non-fee LCC remains locker credit.
- **Evidence**:
  - Echidna: `test/fuzz/invariants/MMQ01.sol` → `echidna_mmq01_*` (run via `just echidna-mmq-01` from `contracts/evm/Justfile`; implementation is shared with `test/fuzz/FuzzMMQ01.sol`).
  - Medusa (optional, no linked-library prepare): `test/fuzz/FuzzEntry.sol` → same `echidna_mmq01_*` properties and `action_*` entrypoints (run via `just medusa-mmq-01`; uses `scripts/medusa.sh` and `medusa.json`).
  - Narrative: [agents/audit-resolutions/mm-queue-custody-nonfee-vs-custodyforward-guard-resolution.md](../../agents/audit-resolutions/mm-queue-custody-nonfee-vs-custodyforward-guard-resolution.md).

### SETTLE-04: MM in-hook protocol credit must not over-clear `requiredSettlementDelta` when deficit is cured first

- **Statement**: For MM liquidity increases that settle protocol credit inside `processMMOperations` (in-hook path with
  `clampToRequiredSettlement`), `_updateSettlement` / `_vUpdateSettlement` may apply a single positive deposit amount across
  `cumulativeDeficit`, `commitmentDeficit`, and effective settled (`pa.settled + pa.settledOverflow`, split canonically vs
  `commitmentMax`) in the usual netting order. The portion of protocol credit that cures deficits **without** increasing
  effective settled on that lane must still be debited from positive underlying delta (full economic consumption), but it
  must **not** be treated as having satisfied the MM add deposit shortfall encoded in `requiredSettlementDelta`.
  That shortfall is computed in `_touchExistingIncrease` against **effective** settled (not live `pa.settled` alone), so
  increases that land in `pa.settledOverflow` still count toward closing the obligation.
- **Protocol rule**:
  - **Credit consumption** follows total applied amount from settlement (`totalApplied`): deficit cure + effective-settled
    movement (and pool accounting on the cumulative-deficit leg) stays internally consistent.
  - **Requirement bookkeeping** for MM add backing vs the live negative `requiredSettlementDelta` advances only when the
    in-hook deposit slice increases **effective** settled on the lane (live `settled` and/or `settledOverflow`). Under
    `clampToRequiredSettlement`, the implementation advances the remainder by the sum of **positive** per-lane deltas on
    `pa.settled` and `pa.settledOverflow` after the settlement step (each positive component reflects additional deferred
    or live backing). **Vault reserve** crediting for the same protocol-credit path uses `effectiveSettledLaneIncrease`
    returned from `_vUpdateSettlement` so representation-only reshuffles cannot inflate `marketLiquidityReserves` without a
    matching economic effective-settled increase (see finding 28_2).
- **Enforced by**:
  - `src/libraries/VTSPositionLib.sol::_touchExistingIncrease` (MM `requiredSettlementDelta` vs **effective** settled)
  - `src/libraries/VTSPositionLib.sol::_vUpdateSettlement` (returns `totalApplied`, per-lane deltas, and `effectiveSettledLaneIncrease`)
  - `src/libraries/VTSPositionMMOpsLib.sol::_consumePositiveUnderlyingDeltaForSettlementLane` when `clampToRequiredSettlement`
    is true (MM in-hook settlement only; `onMMSettle` settle-from-deltas keeps `clampToRequiredSettlement = false`).
- **Regression tests**:
  - `test/libraries/VTSPositionLib.mutation.unit.t.sol`:
    - `test_trackCommitment_zeroLiquidity_canonicalisesStaleLiveSettledIntoOverflow`
  - `test/libraries/VTSPositionLib.onMMSettle.t.sol`:
    - `test_onMMSettle_fromDeltas_staleZeroCommitSplit_doesNotOverCreditLiquidityReserve`

### SEIZE-01: Seizability is token-lane scoped and aggregated at position level

- **Statement**:
  - Checkpointed RFS openness is modelled as a continuous **position-level** episode, represented with lane-addressable
    storage:
    - `openMask` identifies currently open lanes,
    - `openSince*` stores the canonical checkpointed episode start timestamp mirrored on open lanes.
  - Lane-composition changes that do not pass through a fully-closed checkpoint state preserve the same canonical episode
    timer (for example `01 -> 11`, `10 -> 11`, `11 -> 01`, `11 -> 10`).
  - Only a genuine checkpoint transition through `openMask == 0` begins a fresh episode timer.
  - Commitment-deficit bypass is evaluated per token lane using token-specific deficit age and thresholds.
  - `commitmentDeficit` bypass is distinct from swap-incurred `cumulativeDeficit` accounting:
    - `commitmentDeficit` hardens solvency enforcement (RFS/seizability),
    - `cumulativeDeficit` drives swap-attributed pool deficit principal (`totalDeficitPrincipal`).
  - Normal grace-path seizability is evaluated only for token lanes currently marked open in the checkpoint mask.
  - For normal grace-path checks, open-lane eligibility uses each lane's configured grace plus lane-local extension
    against the canonical checkpointed episode timestamp on that lane.
  - Position-level seizability is true when at least one token lane is currently eligible.
  - Explicit protocol rule: token-lane behaviour is specific to seizability and bypass-gate mechanics only.
  - Once any eligible lane authorises seizure, the position may enter a position-level seizure flow.
  - Underlying seizure mechanics remain position-wide: settlement need not stay confined to the triggering lane, and
    liquidity can be slashed proportionally to the intervening party's realised settlement contribution across the
    position.
  - This position-wide consequence is intentional because a seizer who settles one token side is economically protected
    by the collateralisation of assets on the counterpart side of the same position.
- **Enforced by**: `src/libraries/Checkpoint.sol::isSeizable`, called by `src/VTSOrchestrator.sol::onSeize`.

### SEIZE-02: Grace period extensions require an allowed verifier for the settlement token

- **Statement**: A settlement proof must be verified by an indexed verifier that is both registered and allowlisted for
  the relevant token. Verifiers receive `abi.encode(poolId, tokenIndex, positionId)` so attestations can be bound to the
  extension target position (same lane, different positions cannot reuse another position’s proof bytes).
- **Enforced by**: `src/VRLSettlementObserver.sol::verifySettlementProof` (reverts `Errors.InvalidVerifier` /
  `Errors.InvalidProof`).
- **Applied by**: `src/libraries/Checkpoint.sol::extendGracePeriod` and `src/VTSOrchestrator.sol::extendGracePeriod`.

### SEIZE-03: Seizure flows cannot issue LCCs

- **Statement**: While seizing, MM increases that would issue LCC must revert.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_touchNewPosition` and `_touchExistingIncrease` revert
  `Errors.InvariantViolated("Invalid operation: Seizures cannot issue LCCs")` when `hookData.isSeizing`.

### SEIZE-04: MM operations must not change commit identity

- **Statement**: For MM position operations, the commitId provided in hook data must equal the position’s stored
  `commitId`.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::touchPosition` reverts
  `Errors.InvariantViolated("Invalid operation: Commit ID mismatch")`.

## Market maker flash accounting and batch-level settlement safety

### DELTA-01: Deltas must net to zero per unlock/batch

- **Statement**: At the end of an unlock/batch, the protocol must have `NonzeroDeltaCount == 0` or revert.
- **Enforced by**: `src/modules/PositionManagerEntrypoint.sol::_afterBatch` calls
  `VTSOrchestrator.assertNonZeroDeltas(IMarketFactory)` (implemented on `VTSCurrencyDelta`), which:
  - runs `src/libraries/OwnerCurrencyDelta.sol::assertNonZeroDeltas` and reverts `Errors.CurrencyNotSettled()` when any
    owner-scoped PoolManager currency delta remains non-zero; and
  - runs `src/libraries/MarketCurrencyDelta.sol::assertResolved(address(factory))` for the **bound** MM
    `marketFactory`, reverting `Errors.CurrencyNotSettled()` when any factory-prefixed produced-credit bucket is still
    non-zero.
- **Practical implication**: Credits do **not** persist across unlock sessions; they are transient and must be consumed
  (eg via `TAKE`, `SYNC`, unwrap flows) within the same batch.
- **Native ETH (`msg.value`) on payable batches**: `PositionManagerEntrypoint._beforeBatch` credits the locker using
  **balance-delta** accounting (transient last-seen `address(this).balance` updated in `_afterBatch`). That prevents
  `Multicall_v4` inner `delegatecall` batches from each re-crediting the same outer `msg.value`, while still allowing a
  later **distinct** payable call in the same transaction to credit newly attached ETH. Ambient ETH already on
  `MMPositionManager` before the batch is not treated as user credit (baseline uses `balance - msg.value` on first touch).

### DELTA-01A: Produced accounting must stay paired with explicit reserve export and credit-backed withdrawal consumption

- **Statement**:
  - Factory-scoped produced credit in `MarketCurrencyDelta` is the transient mirror of real same-underlying value
    exported from a market's durable reserve ledger.
  - Therefore, any path that **produces** same-underlying withdrawal credit for later cross-market use must pair:
    - a durable source-market reserve decrement, and
    - a matching `MarketCurrencyDelta.addProduced(factory, underlying, amount)`.
  - Any path that **consumes** delta-backed withdrawal capacity must pair:
    - an owner underlying-delta debit for the consumed amount, and
    - a matching `MarketCurrencyDelta.consumeProduced(factory, underlying, amount)`.
  - Owner-level same-underlying delta may remain global for planning, but it is **not** by itself sufficient economic
    authority for a withdrawal. The withdrawal-backed slice is valid only when matched by available produced credit in the
    same bound `marketFactory` namespace.
- **Enforced / expressed by**:
  - `src/libraries/VTSPositionMMOpsLib.sol::processMMOperations` (MM decrease export path):
    - calls `IMarketVault.decreaseLiquidityReserve(...)` on the source market for the exported underlying amount, then
    - calls `MarketCurrencyDelta.addProduced(factory, underlying, amount)` for the same amount.
  - `src/libraries/VTSLifecycleLinkedLib.sol::_executeWithdrawals` and `_applyWithdrawalLane`:
    - build `VaultSettlementIntent.creditBackedWithdrawal{0,1}` from the planned delta-backed slice,
    - debit `OwnerCurrencyDelta` on the owner for the actual delta-backed withdrawal amount, and
    - call `MarketCurrencyDelta.consumeProduced(factory, underlying, amount)` for that same actual amount.
  - `src/CanonicalVault.sol::_dryModifyLiquidities` and `_modifyLiquidityWithRecipient`:
    - treat `creditBackedWithdrawal{0,1}` as distinct from the settled-backed remainder, so only the settled-backed
      slice decrements the destination market's `marketLiquidityReserves`.
  - `src/modules/PositionManagerEntrypoint.sol::_afterBatch`:
    - calls `vtsOrchestrator.assertNonZeroDeltas(marketFactory)`, which in turn requires
      `MarketCurrencyDelta.assertResolved(address(factory))`, preventing produced-credit residue from leaking across
      batches.
- **Why**:
  - This pairing invariant is what closes the original cross-market vault-payout class where owner-level same-underlying
    delta alone could be treated as withdrawal authority against the current market's vault.
  - The protocol intentionally allows same-underlying credit exported in market A to fund settlement in market B within
    the same factory, but only through:
    - explicit `VaultSettlementIntent`,
    - factory-scoped produced accounting, and
    - CanonicalVault's durable per-market reserve ledger.
  - Any future refactor that debits owner underlying delta without consuming produced credit, or that adds produced credit
    without first exporting durable reserve, would violate this invariant and re-open principal misattribution risk.

### DELTA-02: `MMPositionManager` residual balances are FCFS dust, not a persisted user entitlement

- **Statement**:
  - `MMPositionManager` intentionally follows the same broad residual-balance model as Uniswap v4
    `PositionManager`: if a caller leaves sweepable balance or takeable delta inside the router at the end of their
    interaction, that residue is **not reserved** for them across transactions.
  - Residual balances left on `MMPositionManager` are treated as **first-come, first-served dust**. The next caller may
    sync/take that residue if it remains in the contract.
  - Therefore, market makers using `MMPositionManager` are responsible for clearing their own dust/deltas inside the same
    batch / transaction. Leaving residue behind is a caller error or an accepted UX trade-off, not a protocol promise of
    later exclusivity.
- **Reference model (Uniswap v4)**:
  - `lib/v4-periphery/src/PositionManager.sol` exposes public utility actions including `Actions.SWEEP`.
  - `PositionManager._sweep(currency, to)` transfers the router’s **entire** current balance of `currency` to the
    recipient, with no caller-specific entitlement tracking.
  - Fiet adopts the same caller-clears-router-residue philosophy for `MMPositionManager` utility flows, except that
    Fiet uses explicit delta accounting (`SYNC` / `TAKE`) to net transient credits before batch end.
- **Enforced / expressed by**:
  - `src/MMPositionManager.sol::_handleUtilityAction` exposes public utility actions `SYNC` and `TAKE`.
  - `src/MMPositionManager.sol::_sync` credits the current locker from `address(this)` balance via
    `VTSOrchestrator.sync(...)`.
  - `src/modules/PositionManagerEntrypoint.sol::_take` debits the locker’s positive delta and transfers available
    contract balance to the requested recipient.
  - `src/modules/PositionManagerEntrypoint.sol::_afterBatch` calls `vtsOrchestrator.assertNonZeroDeltas(marketFactory)`,
    which forces callers to fully resolve owner-scoped transient credits/debts and the bound factory’s market-produced
    credit within the batch or revert.
- **Internal vs explicit balance attribution (DELTA-02 / settlement hardening)**:
  - **Internal** receipt paths that already know the exact amount (vault settlement outflow to MMPM, LCC **take** balance
    increases, native wrap/unwrap, and similar) credit the locker with **`VTSOrchestrator.creditExact` only for that
    amount**. They do **not** attribute the contract’s full omnibus ERC20/native balance, so **ambient** tokens parked on
    MMPM cannot inflate a locker’s credited amount or net off **negative** (debt) deltas.
  - **Public `SYNC`** (FCFS) remains the **only** intentional path that turns **unscoped** MMPM balance into locker
    **positive** credit, and it is **positive-credit only**: it does not reduce a target’s **negative** delta from
    omnibus balance (residue cannot erase debt; paydown still requires an explicit `take` / settlement transfer).
  - In other words: **FCFS dust** is an **explicit** utility choice (`SYNC` then `TAKE`); **internal** flows use
    **exact** credit, not omnibus sync.
- **Scope clarification**:
  - This FCFS rule applies to **residual dust held by `MMPositionManager` itself**.
  - It does **not** redefine assets held in explicit custody/accounting domains (for example, queue-custodied balances,
    Hub reserves, MarketVault balances, or state tracked by commitment/queue accounting) as public dust.
  - Queued-backing LCC staged after `UNWRAP_LCC` shortfalls must be forwarded into `MMQueueCustodian` (see **HUB-02A**)
    rather than left on the router; that principal is beneficiary-scoped, not FCFS dust.
  - In other words, the invariant is about router residue, not about bypassing the protocol’s actual custody systems.

### DELTA-03: Planned-cancel transient slots are path-scoped only because they are consumed immediately in the same logical flow

- **Statement**:
  - `LiquidityHub.planCancel(...)` and `planCancelWithQueue(...)` intentionally key transient intent by
    `(lcc, from, to)` rather than by a transfer nonce or other per-transfer identifier.
  - This is safe in the current MM decrease flow only because the plan is created during
    `PoolManager.modifyLiquidity(...)` hook execution and then consumed by the immediately-following matching LCC
    transfer in the same logical path and transaction.
  - The protocol does **not** treat planned-cancel transient storage as a general deferred-intent queue.
  - Therefore, any future flow that can stage a second plan for the same `(lcc, from, to)` before the first matching
    transfer consumes it is outside the supported design and must either:
    - preserve the same immediate-consumption sequencing, or
    - upgrade the transient key to include per-transfer identity.
- **Enforced by (current call graph / sequencing invariant)**:
  - `src/libraries/VTSPositionMMOpsLib.sol::_handleLiquidityDecrease` stages the planned cancel while the position is still
    inside `PoolManager.modifyLiquidity(...)`, explicitly because the LCC has not yet been transferred to `MMPM`.
  - `src/modules/PositionManagerImpl.sol::_modifySyntheticLiquidity` calls `poolManager.modifyLiquidity(...)` and then,
    before returning to any outer MM action, immediately settles/takes the resulting deltas.
  - `src/modules/PositionManagerImpl.sol::_takePositiveDeltasAndHandleLcc` performs the matching
    `PoolManager -> MMPM` LCC take for positive deltas right after `modifyLiquidity(...)` returns.
  - `src/modules/PositionManagerImpl.sol::_handleLccBalanceIncrease` then forwards non-fee LCC onward to custody,
    triggering the transfer path on which `LiquidityHub.executePlannedCancel(...)` consumes the plan.
- **Security consequence**:
  - The coarse `(lcc, from, to)` key is not, by itself, a uniqueness proof.
  - Safety currently depends on the adjacent plan-then-transfer sequencing remaining true.
  - Review any refactor that adds batching, retries, deferred transfer steps, or alternate transfer destinations before
    reusing this mechanism.

## Authorisation, call-surface, and pause invariants

### AUTH-01: Only owner/approved can settle/burn/modify MM Commit NFTs, except the primary `SEIZE_POSITION` deposit settle

- **Statement**: Settlement and position modification require `approvedOrOwner`, except **only** for the **primary**
  deposit settle that is explicitly paired with `SEIZE_POSITION` (when `TransientSlots.getSeizurePrimarySettleAllowed()`
  is true and the settle includes a deposit lane: `amount0 < 0` or `amount1 < 0`). **All** other `_settle` paths on the
  seized commitment—including follow-on withdrawal settles in the same batch—require `approvedOrOwner` for `msgSender()`
  on the commitment NFT, even while transient seizure context is active for that `positionId`.
- **Enforced by**:
  - `src/MMPositionActionsImpl.sol::_settle` calls `MMHelpers.assertApprovedOrOwner` unless `_isSeizing(positionId)` **and**
    `TransientSlots.getSeizurePrimarySettleAllowed()` **and** the settle includes a deposit lane.
  - `src/MMPositionActionsImpl.sol::_seizePosition` explicitly forbids owner/approved from seizing and forbids seizing
    inactive positions.

### AUTH-01A: Seizure context is intentionally same-position and batch-scoped

- **Statement**:
  - After a successful `SEIZE_POSITION`, the transient seized-position context may remain live for the remainder of the
    current unlock/batch so the guarantor can complete follow-on settlement / take flows for that **same** seized
    position **subject to** the narrowed NFT gate in AUTH-01 (withdrawal `_settle` is not auth-free for the seizer).
  - **Settle-only deposits under ambient seizure** (additional deposit settlement after `SEIZE_POSITION` has already run
    in the batch, while the transient seized ID still matches) are **disallowed**: they would advance `seizureLiquidityCarry`
    / seizure sizing in `onMMSettle(..., isSeizing=true)` without the coupled `_decreaseInternal` that `SEIZE_POSITION`
    performs.
  - Follow-on withdrawal or mixed-sign settles that touch `_settle` on the seized token **do not** inherit a blanket
    approval bypass: the seizer must be `approvedOrOwner` (or the owner must execute those steps), unless the batch
    never reaches an NFT-gated withdrawal settle for that token.
  - This is not a general approval bypass: the carve-out applies **only** to the orchestrator-paired primary deposit phase;
    the context is additionally valid only when the queried `positionId` exactly matches the transient seized ID.
  - The seizure context must be cleared at batch end so it cannot leak into a later batch / unlock session.
- **Enforced by**:
  - `src/MMPositionActionsImpl.sol::_isSeizing` compares the queried `positionId` against
    `TransientSlots.getSeizedPositionId()`.
  - `src/MMPositionActionsImpl.sol::_seizePosition` sets the transient seized-position ID only after
    `VTSOrchestrator.onSeize(...)` validates seizability, sets `TransientSlots.setSeizurePrimarySettleAllowed(true)` around
    its paired `_settle` (the only authorised seizing deposit phase), then clears the flag.
  - `src/MMPositionActionsImpl.sol::_settle` reverts `Errors.SeizureSettleOnlyDepositDisallowed()` on seizing deposit lanes
    when the primary-settle flag is not set; `src/MMPositionActionsImpl.sol::_settleProtocolCreditsFromDeltas` reverts the
    same when `isSeizing` is true (protocol-credit deposits bypass `_settle`).
  - `src/modules/PositionManagerEntrypoint.sol::_afterBatch` clears `TransientSlots.clearSeizedPositionId()` and
    `TransientSlots.clearSeizurePrimarySettleAllowed()`.
- **Intended flow consequence**:
  - The guarantor can drive the **primary** `SEIZE_POSITION` deposit settle without `approvedOrOwner` on the commitment NFT.
  - Batched follow-on actions on the same position (for example `SEIZE_POSITION -> SETTLE_POSITION_FROM_DELTAS -> TAKE`)
    remain valid **only** where subsequent steps either do not require NFT-gated withdrawal `_settle` without approval, or
    the guarantor already holds `approvedOrOwner` (or the owner / an approved operator performs those steps).
  - Reusing the context for a different position, or allowing it to persist after batch finalisation, would violate this
    invariant.

### AUTH-02: Commitment NFTs cannot be transferred mid-batch

- **Statement**: Commitment NFT transfers must not occur while a PoolManager unlock session is active.
- **Enforced by**: `src/MMPositionManager.sol::transferFrom` guarded by `onlyIfPoolManagerLocked` which reverts
  `Errors.PoolManagerMustBeLocked()`.

### PAUSE-01: Global/pool pause (soft pause: freeze trading risk, allow scoped solvency maintenance)

- **Statement**: When the pool or VTS is globally paused, swap processing and risk-expanding position processing must
  revert. Certain solvency-maintenance and readjustment entrypoints remain intentionally available so operators and
  participants can still settle, checkpoint commitment backing, extend grace with proofs, and validate seizure—without
  reopening general-purpose trading.
- **Enforced by (halted paths)**:
  - `src/modules/PausableVTS.sol` guards (`notPoolPaused`, `notGlobalPaused`) revert `Errors.EnforcedPause()`.
  - Applied to `src/VTSOrchestrator.sol::processPosition` and `afterCoreSwap`.
  - `src/VTSOrchestrator.sol::settlePositionGrowths`: when `s.isPaused || s.pools[poolId].isPaused`, only the canonical
    `CoreHook` for that market may call the public entrypoint (`MarketHandlerLib.assertCoreHook`); other callers revert
    `Errors.InvalidSender()`. This blocks permissionless growth refresh during pause except via hook-driven removes and
    the orchestrator-internal paused commitment-checkpoint path (see **COMMIT-02** ordering).
- **Intentionally available during pause (non-exhaustive)**:
  - Canonical remove-liquidity: `CoreHook` still calls `settlePositionGrowths` before `touchPosition`; `touchPosition`
    allows negative `liquidityDelta` while paused and reverts non-removal modifies (`src/libraries/VTSPositionLib.sol::touchPosition`).
  - `VTSOrchestrator.checkpoint(..., withCommitment: true)`: uses `_settleGrowthsBeforeCheckpoint` so commitment state is
    consistent (see **COMMIT-02**).
  - `VTSOrchestrator.checkpoint(..., withCommitment: false)` and `calcRFS`: still call public `settlePositionGrowths`
    first, so they remain **CoreHook-only** while paused (same gate as above).
  - `extendGracePeriod`, MM settlement, and conditional seizure refresh: `VTSLifecycleLinkedLib` may call
    `VTSPositionLib.settlePositionGrowths` directly on authorised paths (not via the public orchestrator pause gate).
  - `onSeize` / signal lifecycle (`commitSignal`, `renewSignal`, …) are not `notPoolPaused`-gated at the orchestrator
    layer; product policy treats these as solvency / lifecycle maintenance compatible with soft pause.
- **Non-goal**: Pause is **not** a full “hard freeze” of every state transition. A separate hard-freeze mode is not part
  of this invariant; integrators should not assume all orchestrator entrypoints revert when paused.

## Market creation and Uniswap hook constraints (structural invariants)

### MKT-01: Proxy hook cannot accept add-liquidity through the hook

- **Statement**: Adding liquidity through `ProxyHook` is not allowed.
- **Enforced by**: `src/ProxyHook.sol::_beforeAddLiquidity` reverts `Errors.AddLiquidityThroughHookNotAllowed()`.

### MKT-02: Core pool key in ProxyHook is write-once

- **Statement**: `ProxyHook.corePoolKey` must be set only once.
- **Enforced by**: `src/ProxyHook.sol::setCorePoolKey` reverts `Errors.CorePoolKeyAlreadySet()`.

### MKT-03: A core pool must not be created twice

- **Statement**: A market’s core pool ID must be unique in `MarketFactory.coreToProxy`.
- **Enforced by**: `src/MarketFactory.sol::_createCorePool` reverts `Errors.CorePoolAlreadyExists()`.

### MKT-04: Factory and issuer gating are strict boundaries

- **Statement**:
  - Only registered market factories may create and initialise LCC pairs in the hub.
  - Only configured issuers may issue/cancel/queue-cancel LCC supply for a given LCC.
- **Enforced by**:
  - `src/LiquidityHub.sol::createLCCPair` and `initialize` are `onlyFactory` (revert `Errors.InvalidSender()`).
  - `src/LiquidityHub.sol::issue`, `cancel`, `cancelWithQueue`, `planCancel*`, `confirmTake`, `prepareSettle` are issuer
    gated (revert `Errors.NotApproved(...)` via `_onlyIssuer`).

### MKT-04A: Any market-specific `MarketFactory` must hardcode EXEMPT/DEX setup policy; routine admin may only manage `BOUND_NONE <-> BOUND_ENDPOINT`

- **Statement**:
  - Any market-specific `MarketFactory` integrated with `LiquidityHub` must hardcode the policy for `BOUND_EXEMPT` /
    `BOUND_DEX` assignment in its own setup / integration surface, rather than exposing those roles through routine
    owner/admin bound management.
  - Such `MarketFactory` contracts are part of the trusted setup / integration boundary for the protocol.
  - Routine owner/admin surfaces should only manage `BOUND_NONE <-> BOUND_ENDPOINT`.
  - At the generic registry layer, once a `(factory, who)` pair has been assigned `BOUND_EXEMPT` or `BOUND_DEX`,
    that role is immutable, and tiers at or above `BOUND_EXEMPT` may only be first-assigned from `BOUND_NONE`.
- **Enforced by**:
  - Trusted `MarketFactory` integration surface:
    - `src/MarketFactory.sol::addBounds` may only assign `BOUND_ENDPOINT`.
    - `src/MarketFactory.sol::removeBounds` may only assign `BOUND_NONE`.
    - `src/MarketFactory.sol::initialise` assigns fixed setup roles (`poolManager -> BOUND_DEX`,
      `liquidityHub -> BOUND_EXEMPT`, factory / `initialBounds -> BOUND_ENDPOINT`).
    - `src/MarketFactory.sol::createMarket` assigns each newly deployed `proxyHook -> BOUND_EXEMPT`.
  - Generic registry layer:
    - `src/modules/BoundRegistry.sol::_setBoundLevel` reverts `Errors.InvalidBoundLevelTransition(oldLevel, newLevel)` when:
      - `oldLevel >= BOUND_EXEMPT` and `newLevel` differs (immutable tier), or
      - `newLevel >= BOUND_EXEMPT` but `oldLevel` is not `BOUND_NONE` (first-assignment-only at registry layer).
    - `src/LiquidityHub.sol::setBoundLevel` / `setBoundLevels` are `onlyFactory` entrypoints; which addresses may ever
      receive EXEMPT/DEX as part of setup is a trusted property of the specific registered `MarketFactory`.
- **Current `MarketFactory` example**:
  - `src/MarketFactory.sol::initialise` assigns:
    - `poolManager -> BOUND_DEX`
    - `liquidityHub -> BOUND_EXEMPT`
    - factory-owned transfer endpoints / `initialBounds -> BOUND_ENDPOINT`
  - `src/MarketFactory.sol::createMarket` assigns each newly deployed `proxyHook -> BOUND_EXEMPT`.
- **Routine admin surface (current `MarketFactory`)**:
  - `src/MarketFactory.sol::addBounds` may only assign `BOUND_ENDPOINT`.
  - `src/MarketFactory.sol::removeBounds` may only assign `BOUND_NONE`.
- **Why**:
  - Crossing the exempt boundary after balances or queues already exist is a governance footgun:
    - `EXEMPT -> tracked` can strand bucketless exempt-era balances and break the assumptions behind `LCC-02`.
    - `tracked -> EXEMPT` can make queue-backed settlement non-serviceable until roles/ownership are reconciled.
  - This lifecycle rule is therefore a structural precondition for `LCC-01` and `LCC-02`, rather than a separate
    economic policy.

### MKT-05: Proxy pool AMM price curve must never be utilised (core-curve-only execution)

- **Statement**: A swap submitted against the **proxy pool** must never execute against the proxy pool’s own Uniswap v4
  CLMM curve. The proxy pool’s `slot0` (`sqrtPriceX96`, `tick`) is **non-authoritative** and must be treated as an
  implementation detail only.

  Concretely:

  - All economically meaningful swap execution must be routed through the **core pool** (LCC↔LCC pool).
  - The proxy hook must ensure the underlying proxy-pool `PoolManager.swap(proxyPoolKey, ...)` is a **no-op** at the
    Uniswap layer (i.e. the swap’s effective `amountToSwap` on the proxy pool is zero), so that the proxy pool’s AMM
    state is not advanced by swaps.

- **Purpose**:

  - The protocol’s “single curve” is the **core** pool. Allowing the proxy pool to run its own AMM step(s) creates a
    second mutable price path that is not meant to be consumed by VTS or integrators.
  - Proxy-pool `slot0` drift is not merely cosmetic: it can become a denial-of-service vector. In particular, pushing
    proxy `sqrtPriceX96` to an extreme can cause subsequent swaps to revert via Uniswap’s price-limit guards (e.g.
    `PriceLimitAlreadyExceeded`), even though the protocol intends swaps to be routed to the core pool.

- **Risks if violated (griefing / safety impact)**:

  - **Directional swap DoS via price-limit poisoning**: If any swap leaves a non-zero residual `amountToSwap` and the
    proxy pool’s `Pool.swap()` executes, the proxy pool may “walk” its `sqrtPriceX96` towards the swap limit despite
    having no meaningful liquidity. Once proxy `slot0.sqrtPriceX96` is pushed to an extreme, subsequent swaps that use
    standard “full-range” limits can revert with `PriceLimitAlreadyExceeded`, effectively disabling proxy-pool swaps for
    that direction (and therefore disabling the protocol’s primary swap entrypoint for that market).
  - **Gas griefing / execution amplification**: Executing the proxy pool swap path can force extra bitmap scanning and
    swap-loop work that should not exist in the proxy architecture. Attackers can intentionally trigger the “residual
    swap” path (e.g. by inducing liquidity-capped execution) to increase gas usage and reduce throughput.
  - **State ambiguity / integration footguns**: A mutable proxy `slot0` creates a second on-chain price series that is
    not economically meaningful for the protocol. This increases the risk of accidental consumption by indexers,
    integrators, or future protocol modules (e.g. mistakenly using proxy `tick`/`sqrtPriceX96` as an oracle input).
  - **Auditability regression**: The protocol’s security arguments rely on a single authoritative curve. Allowing the
    proxy curve to execute complicates reasoning about “what price was used” and makes correctness harder to validate
    across upgrades and refactors.

- **Enforced by (required mechanism)**:
  - `src/ProxyHook.sol::_beforeSwap` must guarantee that swaps against the proxy pool do not leave a residual
    `amountToSwap` for the proxy pool’s own `Pool.swap` to execute.
  - If the protocol elects to support “partial fills” / liquidity-capped swaps, it must do so without permitting the
    proxy pool’s AMM state machine to advance (e.g. by reverting when a cap would otherwise leave non-zero residual, or
    by redesigning the hook accounting so the proxy swap is always fully neutralised). Proxy **exact-output**
    (`amountSpecified > 0`) remains **strict**: insufficient immediate vault liquidity reverts even when a deficit
    recipient is resolved via `hookData` — queued-deficit exact-output on the proxy pool is not supported because it
    would break the specified-delta cancellation required for **MKT-05**.

### MKT-06: Canonical market pair ordering is core/LCC order (and events must reflect it)

- **Statement**: Any protocol surface that groups a market’s two tokens into `(0,1)` lanes must use **core pool / LCC**
  ordering as the canonical order:

  - `lcc0 = corePoolKey.currency0`
  - `lcc1 = corePoolKey.currency1`
  - `lcc0UnderlyingAsset = ILCC(lcc0).underlying()`
  - `lcc1UnderlyingAsset = ILCC(lcc1).underlying()`

  In particular, event emission must not independently sort underlyings and LCCs such that the implied pairing becomes
  ambiguous.

- **Enforced by**:

  - `src/MarketFactory.sol::createMarket` emits `MarketCreated(corePoolId, proxyPoolId, lcc0, lcc1, lcc0UnderlyingAsset, lcc1UnderlyingAsset, ...)`
    derived from `corePoolKey.currency0/1` plus the deterministic input mapping
    `(underlyingAsset0 -> ctx.lccToken0, underlyingAsset1 -> ctx.lccToken1)`.
  - `src/MarketFactory.sol::corePoolToCurrencyPair` stores `[corePoolKey.currency0, corePoolKey.currency1]` in core/LCC order.

- **Non-canonical (allowed) ordering**:
  - Proxy pool currencies are ordered by Uniswap’s proxy `PoolKey` sorting and may differ from core/LCC order.
    Any mapping between proxy order and core order must be explicit (see `src/ProxyHook.sol` swap-context alignment).

---

## Notes for test authors

- **Config**: use `VTSConfigs.getDefaultConfig()` unless a test intentionally constructs a custom `VTSConfig`.
- Many invariants above are **batch-scoped** (PoolManager unlock sessions) rather than “global over time”.
- When writing tests that exercise settlement/credit paths, prefer asserting on **balance deltas** and **explicit revert
  selectors** (eg `Errors.CurrencyNotSettled()`, `Errors.TransferNotAllowed()`, `DelegateCallGuard.OnlyDelegateCall()`).
- Bound-level tests should respect **MKT-04A**: do not flip `BOUND_EXEMPT` / `BOUND_DEX` after assignment; if a test
  needs an exempt bucket holder, prefer canonical setup fixtures or `BOUND_NONE -> BOUND_EXEMPT` rather than
  `BOUND_ENDPOINT -> BOUND_EXEMPT`.
- Do not assume “LCC supply == hub reserves”; supply spans multiple domains and is constrained by **backing checks**
  and **explicit queue mechanics** instead of a single equality.
