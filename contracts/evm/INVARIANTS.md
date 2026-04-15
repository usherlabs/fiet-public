# Fiet EVM Protocol Invariants

This document describes **protocol-level invariants** enforced by the EVM contracts under `contracts/evm/src`.
It is intended for auditors, integrators, and test authors.

Wherever possible, each invariant is anchored to the **enforcement point** (the exact revert/guard) rather than
being an informal “should”.

## Scope and terminology

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
  - **cumulativeDeficit**: swap-driven outflow shortfall accumulated per position; this is the DICE principal used for
    coverage-index attribution and fee-slash accounting.
  - **commitmentDeficit**: position-level insolvency gate derived from commitment backing checks; this is used for
    RFS/seizability hardening and is not part of DICE principal (`totalDeficitPrincipal`).

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
  - Native ETH settlement egress now attempts direct ETH payout first, then wraps to WETH9 and transfers ERC20 WETH
    when the recipient cannot accept native ETH.
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

- **Enforced by (authorised mint surfaces)**:

  - **Domain A**: `src/LiquidityHub.sol::_wrap` transfers underlying in, increments
    `directSupply[lcc]` and `reserveOfUnderlying[underlying]`, then mints LCC.
  - **Domain B**: `src/LiquidityHub.sol::issue` is `onlyIssuer(lcc)` and mints market-derived amount via the LCC hub
    mint path; issuer gating is enforced by `LiquidityHub._onlyIssuer` (valid LCC + issuer allowlist).
  - **Domain C**: `src/libraries/VTSPositionMMOpsLib.sol::_handleLiquidityIncrease` calls
    `src/libraries/VTSCommitLib.sol::validateLiquidityDelta(..., revertIfInsufficientBacking=true)`, which reverts
    `Errors.InvalidLiquiditySignal(...)` unless \(issuedUsd \le settledUsd + signalUsd\).
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
  - If `prepareMarketLiquidity` executes while the active synced currency is this same `lcc`, it must:
    - allow only the first unpaid ingress transfer in that sync window, and
    - restore `sync(lcc)` after nested settlement side-effects.
  - For native-underlying lanes, the temporary clear of ERC20 sync context (native reset) is allowed only inside this
    controlled same-`lcc` branch, followed by restoring `sync(lcc)`.
- **Enforced by**:
  - `src/MarketFactory.sol::prepareMarketLiquidity`
    - Reads PoolManager transient slots (`Currency`, `ReservesOf`) through `exttload`.
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

### HUB-01: Wrapping mints 1:1 and increases Hub reserves

- **Statement**: `wrap`/`wrapTo` must:
  - transfer `amount` underlying into the hub, and
  - increment `directSupply[lcc]` and `reserveOfUnderlying[underlying]` by `amount`, and
  - mint `amount` LCC to the recipient.
- **Enforced by**: `src/LiquidityHub.sol::_wrap`.
- **Notable guard**:
  - native-asset wrap requires `msg.value == amount`, otherwise `Errors.InvalidAmount`.
  - ERC20-backed wrap requires `msg.value == 0`, otherwise `Errors.InvalidAmount`.
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

### HUB-02: Unwrapping cannot exceed liquid (bucketed) balance; shortfalls are explicitly queued

- **Statement**: Unwrap requires `0 < amount <= availableToUnwrap`, where `availableToUnwrap` is the caller’s live
  bucketed balance (`wrappedBalance + marketDerivedBalance` for `msg.sender`) minus any existing settlement queue for
  the same `(lcc, queueTo)` key: `max(0, fromBalance - settleQueue[lcc][queueTo])`. Any unavailable portion of the
  requested unwrap is still tracked via the settlement queue rather than silently failing.
- **Enforced by**:
  - `src/LiquidityHub.sol::_unwrap` reverts `Errors.InvalidAmount(amount, availableToUnwrap)` when out of bounds.
  - The split/queue behaviour is implemented in `LiquidityHubLib.unwrapInternalLogic(...)` (called from `_unwrap`).
  - Queue state is observable via `LiquidityHub.settleQueue(lcc, recipient)` and `LiquidityHub.totalQueued(lcc)`.
- **Why**: Queued shortfall does not burn the holder’s LCC at queue time; without netting, the same balance could back
  multiple queued claims and inflate `queueOfUnderlying` / vault obligation sizing.

### HUB-02A: `unwrapTo` is endpoint-only (on-behalf-of); direct users use `unwrap`

- **Statement**: Every `LiquidityHub.unwrapTo(...)` overload requires `msg.sender` to be `BOUND_ENDPOINT` in the
  resolved LCC’s market factory namespace (`boundLevelOfLcc(lcc, msg.sender) == BOUND_ENDPOINT`). Bucket-exempt and
  DEX tiers are not admitted via `unwrapTo`. End users unwrap with `unwrap(...)` / `unwrap(underlying, marketId, ...)`,
  which always queue shortfalls to the caller.
- **Enforced by**: `src/LiquidityHub.sol::_onlyUnwrapToEndpoint` on each `unwrapTo` entrypoint before `_unwrap`.
- **Trusted endpoint contract**:
  - `unwrapTo(lcc, to, queueTo, ...)` is an on-behalf-of primitive, not a generic convenience wrapper over `unwrap`.
  - The endpoint must call it only after it has already consumed/escrowed beneficiary-linked value (for example locker
    LCC or delta credit) for `queueTo`, so the caller-held LCC slice economically represents that beneficiary.
  - Under that precondition, HUB-02 headroom netting against `settleQueue[lcc][queueTo]` is correct because the queue is
    already encumbering the same caller-held slice.
  - Current intended caller: `MMPositionManager`, which consumes locker/user LCC or delta credit before calling
    `unwrapTo`.
  - Any additional `BOUND_ENDPOINT` integration that cannot preserve this coupling must not use `unwrapTo` without
    revisiting HUB-02 netting assumptions.
- **Rationale**: Splitting immediate payout recipient from queue owner is a trusted endpoint pattern (for example
  `MMPositionManager` after it has consumed the beneficiary’s LCC or delta credit). Exposing that split to arbitrary EOAs
  allowed repeated queue inflation against unchanged holder balance.

### HUB-02B: Unwrap immediate payout recipients must be serviceable (not Hub, exempt, or DEX)

- **Statement**: On every unwrap path, the immediate underlying payout address `to` must not be `address(0)`, the Hub
  itself, any `BOUND_EXEMPT` address, or any `BOUND_DEX` address. This is independent of queue-owner validation on
  `queueTo`: the Hub may still attribute queued settlement to `address(this)` where Hub-internal queue semantics apply,
  but underlying must never be pushed to unserviceable protocol sinks (for example proxy-hook/facade).
- **Enforced by**: `src/LiquidityHub.sol::_assertValidUnwrapPayoutRecipient` inside `_unwrap` before `_pay`.
- **Why**: Exempt endpoints are not unwrap payout targets; paying them strands underlying outside durable custody and
  settlement accounting.

### HUB-02C: Native queue settlement remains serviceable if recipient shape changes after queueing

- **Statement**: For native-underlying settlements on the external recipient path, `processSettlementFor(...)` must not
  become permanently unserviceable merely because a queue owner that appeared EOA-shaped at queue time later becomes a
  non-payable contract.
- **Enforced by**:
  - `src/libraries/LiquidityHubLib.sol::transferUnderlying`:
    - attempts direct native ETH transfer first;
    - on native transfer failure, wraps the same amount via `LiquidityHub.weth9()` and transfers WETH as ERC20.
- **Why**:
  - Queue-time recipient checks (for example `recipient.code.length`) are snapshot checks and cannot guarantee future
    native payability for counterfactual addresses.
  - Settlement-time fallback is therefore the definitive liveness guard for native queue redemption.

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

## Commitment backing, signals, and insolvency gates

### COMMIT-ROLE-01: Commitment owner and advancer are intentionally distinct roles

- **Operating model / protocol assumption**:
  - `mmState.owner` is the durable identity for the market maker's signalled state and is expected to correspond to the
    operator's high-security custody / approval authority.
  - `mmState.advancer` is the lower-friction operational key used to submit / renew VRL-backed MM state and to initiate
    ordinary MM position operations through `MMPositionManager`.
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
- **Expressed by**:
  - `src/libraries/VTSCommitLib.sol::_renewSignalInternal` preserves `mmState.owner` across renewals and authorises
    renewals via `mmState.advancer`.
  - `src/libraries/VTSLifecycleLinkedLib.sol::validateMMOperation` requires the MM batch locker to equal the stored
    advancer for non-seizure MM operations.
  - `src/libraries/MMHelpers.sol::assertApprovedOrOwner` separately enforces ERC-721 owner / approval authority on the
    relevant `MMPositionManager` entrypoints.
- **Non-goal**:
  - The protocol does **not** guarantee that transferring an active commitment NFT alone transfers full MM operating
    authority to the recipient.

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
  backing must revert.
- **Enforced by**:
  - `src/libraries/VTSCommitLib.sol::validateLiquidityDelta` computes issued/settled/signal values and reverts
    `Errors.InvalidLiquiditySignal(issuedValue, signalValue, settledValue)` when insufficient.
  - Called during MM increases by `src/libraries/VTSPositionMMOpsLib.sol::_handleLiquidityIncrease` with
    `revertIfInsufficientBacking = true`.

### COMMIT-02: Checkpointing with commitment updates `commitmentDeficit` as an insolvency gate

- **Statement**: A commitment checkpoint must set (or reduce/clear) `PositionAccounting.commitmentDeficit` in token
  units based on the USD backing shortfall.
- **Enforced by**: `src/libraries/VTSCommitLib.sol::checkpointWithCommitment`.
- **Ordering (growth before commitment)**: `checkpointWithCommitment` values backing from stored `pa.settled` (and
  effective issued amounts). Therefore `src/VTSOrchestrator.sol::checkpoint(..., withCommitment: true)` must settle
  position growths **before** delegating to `VTSLifecycleLinkedLib.checkpointAfterGrowthNoCommitment` / `VTSCommitLib.checkpointAfterGrowthWithCommitment` (commitment path uses `VTSCommitLib.checkpointWithCommitment`), so
  uncrystallised deficit/inflow/fee growth cannot make the commitment gate read stale-high `settled`. While the pool
  (or VTS globally) is paused, public `VTSOrchestrator.settlePositionGrowths` remains restricted to the canonical
  `CoreHook` for that market; the orchestrator-only helper `_settleGrowthsBeforeCheckpoint` performs the same
  `VTSPositionLib.settlePositionGrowths` work for paused commitment checkpoints only, without widening arbitrary
  third-party refresh on the public entrypoint.
- **Consequence**: Positions with non-zero `commitmentDeficit` can bypass normal grace only when the configured
  token-lane bypass age/severity gates in `SEIZE-01` are satisfied.
- **Separation invariant**: `commitmentDeficit` is a checkpoint-derived solvency gate and is not the pool DICE
  principal. DICE denominator (`totalDeficitPrincipal`) tracks swap-incurred `cumulativeDeficit` only.

### COMMIT-02A: Non-seizure MM liquidity changes blocked while `commitmentDeficit` is non-zero

- **Statement**: If `PositionAccounting.commitmentDeficit` is non-zero on either token, any MM `touchPosition` with
  `liquidityDelta != 0` must revert unless the operation is a seizure (`hookData.seizure.isSeizing == true`).
- **Enforced by**: `src/libraries/VTSPositionLib.sol::touchPosition` reverts `Errors.CommitmentDeficitBlocksLiquidityChange`.
- **Rationale**: Closing live RFS (via settlement) does not necessarily clear stored `commitmentDeficit`; allowing MM
  add/remove while the insolvency gate persists would desynchronise commitment context from checkpoint-derived deficit
  state. MM no-ops (`liquidityDelta == 0`) and settlement / checkpoint paths remain available to cure or formalise
  backing.

### COMMIT-02B: Full liquidity mirror deactivation clears commitment-deficit storage

- **Statement**: When `positionLiquidityMirror` transitions from a value `> 0` to `0`, `commitmentDeficit` (both
  tokens), `commitmentDeficitSince`, and `commitmentDeficitBps` are reset to zero.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyLiquidityMirrorTransition`.
- **Rationale**: Issued commitment is zero after a full unwind; retaining token deficit amounts without a coherent age
  vector would be stale and could interact badly with deficit-age bypass logic. **COMMIT-02A** remains in force: MM still
  cannot change liquidity while deficit is non-zero, so this reset is not a way to “MM-remove past” the gate—it is the
  bookkeeping cleanup once deactivation is actually reached (including non-MM and seizure paths).

### COMMIT-03: “Advancer” binding for checkpoint-with-commitment must hold

- **Statement**: A checkpoint-with-commitment must only accept signals where:
  - the new signal’s owner matches the old owner, and
  - the `sender` equals `mmState.advancer`, and
  - `advancer != owner`.
- **Enforced by**: `VTSCommitLib.checkpointWithCommitment` reverts `Errors.InvalidSender()` when violated.

## Coverage, fee burning, and bounded exercises

### COV-01: Coverage burn is bounded by `(deficit + settled)`; fee burn is capped by deficit

- **Statement**:
  - Effective coverage usage must satisfy \(cov\_{eff} = \min(cov, cumulativeDeficit + settled)\).
  - Burn base must satisfy \(burnBase = \min(cov\_{eff}, cumulativeDeficit)\).
  - `commitmentDeficit` is not used as slash principal in this burn path.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyCoverageBurn`.

### COV-02: Coverage is applied before position modification to preserve economic integrity

- **Statement**: Coverage burns must be settled before liquidity modification to prevent “cover then avoid burn in same
  call” games.
- **Ordering requirement**: Settlement netting order is:
  1. `cumulativeDeficit` first,
  2. then `commitmentDeficit`,
  3. then `settled` increases.
     Only the `cumulativeDeficit` leg mutates DICE principal (`totalDeficitPrincipal`).
- **Enforced by**:
  - `src/libraries/VTSPositionLib.sol::settlePositionGrowths` calls `_settleDeficitIndexedCoverageUsage` after settling
    deficit/inflow growths, and is invoked by `CoreHook` _before_ modifies.

### COV-03: Coverage increments are meaningful only when there is principal/settled to index against

- **Statement**: Coverage index increments are conditional:
  - If `totalDeficitPrincipal > 0`, increment DICE index; else accrue to residual.
    (`totalDeficitPrincipal` is the pool sum of outstanding `cumulativeDeficit`, excluding `commitmentDeficit`.)
  - If `totalSettled > 0`, increment CISE index; else accrue to residual.
- **Enforced by**: `src/libraries/VTSCommitLib.sol::incrementCoverage`.
- **Practical implication**: Tests should not assume “arbitrary coverage” will always produce burns or index movement.

### COV-03A: Coverage is measured at unwrap-time market consumption, not at later queue fulfilment

- **Statement**:
  - `incrementCoverage` measures only the amount of already-live market liquidity actually consumed by
    `MarketFactory.useMarketLiquidity(...)` during an unwrap.
  - Any unwrap remainder that is queued is **not** itself a coverage event.
  - Later queue servicing via vault-to-Hub mobilisation (for example `CanonicalVault._settleObligationsForLCC(...)` ->
    `LiquidityHub.confirmTake(...)`) is fulfilment / reserve reconciliation, not retroactive enlargement of the earlier
    coverage event.
- **Why**:
  - DICE/CISE are intended to answer "how much market liquidity was exercised by this unwrap now?", not "how much queue
    debt was eventually paid later?".
  - Therefore, if current reserve state causes part of an unwrap to queue, the protocol records coverage only for the
    immediate exercised slice. Later token-in replenishment may clear the queue, but it does not create a second
    coverage event for that original unwrap.

### COV-04: Fee-burn baseline remainder carry and liquidity resets

- **Statement**:
  - When applying a coverage fee burn, the position checkpoints `feeGrowthInsideLast` on the fee token by advancing
    Q128 growth in a way that **carries** the `(consumedFees * Q128) mod positionLiquidity` remainder across successive
    burns at fixed liquidity, so repeated partial burns do not lose one wei of growth per event to independent flooring.
  - The remainder is **invalid** if `positionLiquidity` changes: `touchPosition` clears `feeBurnGrowthRemainder` whenever
    `liquidityDelta != 0` for an existing position. New positions initialise both fee snapshots and remainders in
    `_initFeeSnapshot`.
  - If Uniswap position liquidity changes **without** `touchPosition` (for example paused remove-liquidity in
    `CoreHook._afterRemoveLiquidity`), `settlePositionGrowths` detects a mismatch between stored `Position.liquidity`
    and `StateLibrary.getPositionLiquidity` and clears `feeBurnGrowthRemainder` so carry is never applied under a stale
    denominator. The next `touchPosition` continues to be the canonical place that updates the stored liquidity mirror.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyBurnBase`, `_initFeeSnapshot`, `touchPosition`,
  `_reconcileLiquidityMirrorAndFeeBurnRemainder`, `settlePositionGrowths`.

### FEE-01: Queued slashes vs materialised slashed pot

- **Statement**:
  - `protocolFeeAccrued` represents **queued** fee-pot accounting (used for bonus allocation maths).
  - `slashedPot` represents **materialised** pot balance (used for actually paying bonuses during fee finalisation).
  - Therefore, `protocolFeeAccrued` may increase after growth settlement / coverage settlement, while `slashedPot`
    remains unchanged until the relevant position is fee-processed (“touched”).
- **Enforced by**:
  - `src/libraries/VTSFeeLib.sol::_queueBonusForToken` allocates bonuses against `protocolFeeAccrued` and queues
    `pendingFeeAdj` (it does not mint/burn the slashed pot).
  - `src/libraries/VTSFeeLib.sol::_finaliseFeeAdjustment` is the materialisation point:
    - **positive** `pendingFeeAdj` funds `slashedPot` (`_fundFeePot`)
    - **negative** `pendingFeeAdj` drains `slashedPot` up to availability (`_drainFeePot`)
  - `src/libraries/VTSFeeLib.sol::_processPositionFees` calls `_finaliseFeeAdjustment` during touch.
  - Bonus sizing uses `FullMath.mulDivRoundingUp(potAvail, ciseExposure, totalExposure)` (then caps to `potAvail`) so
    tiny proportional shares are not stranded at zero wei when the position is otherwise eligible.
- **Echidna harness note**:
  - `test/fuzz/invariants/FEE01.sol` resets CSI `feesSharedEpoch`, remaining-share factors, and related accounting at the
    start of each action. Echidna reuses a single deployed harness, so without that reset, `_syncFeesSharedRemainingForToken`
    can clear or rescale seeded `feesShared` across steps and desynchronise a naive “expected queue” model from production
    behaviour.

### FEE-02: New positions must not receive fee-sharing bonuses on creation

- **Statement**: A newly registered position (MM or DirectLP) must not immediately allocate/receive fee-sharing bonuses
  at the moment it is created, even if the pool has already accumulated `protocolFeeAccrued` or a funded `slashedPot`.
  Bonus allocation is only possible after the position has accrued non-dust eligibility (CISE exposure) and is later
  fee-processed.
- **Enforced by**:
  - `src/libraries/VTSFeeLib.sol::_queueBonusForToken` requires `ciseExposure > 0` and `ciseExposure >= 1e6`
    (dust guard). New positions start with `ciseExposureSinceLastMod == 0`.
  - CISE exposure accrues only when coverage is incremented (`VTSCommitLib.incrementCoverage`) **after** the position
    exists; it is then realised/consumed on subsequent fee-processing touches.

## Settlement, RFS, and seizure safety

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
  - **Source-side decrement (routed amount only)**: `_applySettlementClampFromExcess` removes
    `settleableDelta + queuedDelta` from source `pa.settled` / pool `totalSettled` — the value actually routed to the
    vault path or queue in this step — not the full `requiredSettlementDelta` when part of it must remain deferred in
    `settled`.
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
  - `src/libraries/VTSPositionMMOpsLib.sol::previewLiquidityDecreaseRouting` (and `_handleLiquidityDecrease` via
    `_computeLiquidityDecreaseRoutingSplit`) splits vault availability vs Hub-queued principal; `underlyingDeltaSettlement`
    for dynamic delta accounting equals the vault-immediate slice (`settleableDelta`) only.
  - `src/libraries/VTSPositionMMOpsLib.sol::processMMOperations` (decrease branch): calls `_applySettlementClampFromExcess`
    with `exportedForSettlementClamp` from `_handleLiquidityDecrease` (`settleableDelta + queuedDelta`), then
    `OwnerCurrencyDelta.accountUnderlyingSettlementDelta` for the immediate slice only.
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

### SETTLE-04: MM in-hook protocol credit must not over-clear `requiredSettlementDelta` when deficit is cured first

- **Statement**: For MM liquidity increases that settle protocol credit inside `processMMOperations` (in-hook path with
  `clampToRequiredSettlement`), `_updateSettlement` / `_vUpdateSettlement` may apply a single positive deposit amount across
  `cumulativeDeficit`, `commitmentDeficit`, and `pa.settled` in the usual netting order (**COV-02**). The portion of
  protocol credit that cures deficits without increasing `pa.settled` must still be debited from positive underlying
  delta (full economic consumption), but it must **not** be treated as having satisfied the MM add deposit requirement
  encoded in `requiredSettlementDelta`. Only the actual `pa.settled` lane delta may reduce that remainder before the
  post-hook underlying settlement step.
- **Protocol rule**:
  - **Credit consumption** follows total applied amount from settlement (`totalApplied`): deficit cure + settled increase
    (and pool accounting such as DICE principal on the cumulative-deficit leg) stays internally consistent.
  - **Requirement bookkeeping** for MM add backing vs the live negative `requiredSettlementDelta` advances only by the
    settled leg (`settledDeltaOnly`), so a position cannot skip posting the still-outstanding deposit obligation merely
    because credit first cleared `cumulativeDeficit` / `commitmentDeficit`.
- **Enforced by**:
  - `src/libraries/VTSPositionLib.sol::_vUpdateSettlement` (returns both `totalApplied` and `next - cur` on `pa.settled`)
  - `src/libraries/VTSPositionMMOpsLib.sol::_consumePositiveUnderlyingDeltaForSettlementLane` when `clampToRequiredSettlement`
    is true (MM in-hook settlement only; `onMMSettle` settle-from-deltas keeps `clampToRequiredSettlement = false`).
- **Regression tests**:
  - `test/libraries/VTSPositionLib.mutation.unit.t.sol`:
    - `test_touchPosition_mmIncrease_cumulativeDeficit_doesNotOverClearRequiredSettlement`
    - `test_touchPosition_mmIncrease_cumulativeDeficit_surplusProtocolCredit_preservesShortfallAndSurplus`
    - `test_touchPosition_mmIncrease_mixedLane_cumulativeDeficitToken0_exactToken1`

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
    - `cumulativeDeficit` drives DICE slash attribution and pool deficit principal.
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
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_touchExistingIncrease` reverts
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
- **Scope clarification**:
  - This FCFS rule applies to **residual dust held by `MMPositionManager` itself**.
  - It does **not** redefine assets held in explicit custody/accounting domains (for example, queue-custodied balances,
    Hub reserves, MarketVault balances, or state tracked by commitment/queue accounting) as public dust.
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

### AUTH-01: Only owner/approved can settle/burn/modify MM Commit NFTs, except in seizure context

- **Statement**: Settlement and position modification require `approvedOrOwner`, except when operating in an active
  seizure context.
- **Enforced by**:
  - `src/MMPositionActionsImpl.sol::_settle` calls `MMHelpers.assertApprovedOrOwner` unless `_isSeizing(positionId)`.
  - `src/MMPositionActionsImpl.sol::_seizePosition` explicitly forbids owner/approved from seizing and forbids seizing
    inactive positions.

### AUTH-01A: Seizure context is intentionally same-position and batch-scoped

- **Statement**:
  - After a successful `SEIZE_POSITION`, the transient seized-position context may remain live for the remainder of the
    current unlock/batch so the guarantor can complete follow-on settlement / take flows for that **same** seized
    position.
  - This is not a general approval bypass: the context is valid only when the queried `positionId` exactly matches the
    transient seized ID.
  - The seizure context must be cleared at batch end so it cannot leak into a later batch / unlock session.
- **Enforced by**:
  - `src/MMPositionActionsImpl.sol::_isSeizing` compares the queried `positionId` against
    `TransientSlots.getSeizedPositionId()`.
  - `src/MMPositionActionsImpl.sol::_seizePosition` sets the transient seized-position ID only after
    `VTSOrchestrator.onSeize(...)` validates seizability.
  - `src/modules/PositionManagerEntrypoint.sol::_afterBatch` clears `TransientSlots.clearSeizedPositionId()`.
- **Intended flow consequence**:
  - Batched follow-on actions such as `SEIZE_POSITION -> SETTLE_POSITION_FROM_DELTAS -> TAKE` on the same position are
    part of the supported seizure execution model.
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

- Many invariants above are **batch-scoped** (PoolManager unlock sessions) rather than “global over time”.
- When writing tests that exercise settlement/credit paths, prefer asserting on **balance deltas** and **explicit revert
  selectors** (eg `Errors.CurrencyNotSettled()`, `Errors.TransferNotAllowed()`, `DelegateCallGuard.OnlyDelegateCall()`).
- Bound-level tests should respect **MKT-04A**: do not flip `BOUND_EXEMPT` / `BOUND_DEX` after assignment; if a test
  needs an exempt bucket holder, prefer canonical setup fixtures or `BOUND_NONE -> BOUND_EXEMPT` rather than
  `BOUND_ENDPOINT -> BOUND_EXEMPT`.
- Do not assume “LCC supply == hub reserves”; supply spans multiple domains and is constrained by **backing checks**
  and **explicit queue mechanics** instead of a single equality.
