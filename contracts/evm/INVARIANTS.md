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
  - **cumulativeDeficit**: swap-driven outflow shortfall accumulated per position.
  - **commitmentDeficit**: position-level insolvency gate derived from commitment backing checks.

## LCC backing and liquidity domains

### LCC-BACKING-01: Every LCC mint must correspond to a specific backing domain (no “free mint”)

- **Statement**: Any increase in LCC supply must be attributable to **exactly one** of the protocol’s backing domains
  (or a domain-preserving conversion), and must only be reachable through the protocol’s authorised mint surfaces.
  Concretely, LCCs represent **claims on liquidity** in one of these domains:

  - **Domain A — Wrapped / out-of-market (Hub-reserved underlying)**:
    - LCC is minted **1:1** against underlying deposited into `LiquidityHub`.
    - This corresponds to the `directSupply` / `wrappedBalances` notion for non-protocol holders.
    - The backing asset is *immediately* reflected in `LiquidityHub.reserveOfUnderlying(underlying)`.

  - **Domain B — In-market (market-derived liquidity claims, including queued settlement claims)**:
    - LCC is minted by an **issuer** (eg ProxyHook, VTSOrchestrator) to represent liquidity that exists (or is being
      routed) *inside the market system* (PoolManager / MarketVault), rather than as Hub-held underlying reserves.
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
  - **Domain C**: `src/libraries/VTSPositionLib.sol::_handleLiquidityIncrease` calls
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
- **Why**: LCCs are *market compatibility primitives*, not freely transferable assets. This prevents bypassing
  settlement/queue semantics and reduces misclassification risk for downstream integrations.

### LCC-02: LCC bucket accounting must remain consistent with transfer flow

- **Statement**: For non-protocol → protocol transfers, queued-settlement ownership must be annulled before bucket
  decrement to prevent “bleeding” into the queue.
- **Enforced by**:
  - `src/LCC.sol::_beforeTransfer` calls `LiquidityHub.annulSettlementBeforeTransfer(...)` for non-protocol → protocol
    transfers.
  - `src/LiquidityHub.sol::annulSettlementBeforeTransfer` adjusts `settleQueue` / `totalQueued` if a transfer would
    implicitly consume queued claims.

### HUB-01: Wrapping mints 1:1 and increases Hub reserves

- **Statement**: `wrap`/`wrapTo` must:
  - transfer `amount` underlying into the hub, and
  - increment `directSupply[lcc]` and `reserveOfUnderlying[underlying]` by `amount`, and
  - mint `amount` LCC to the recipient.
- **Enforced by**: `src/LiquidityHub.sol::_wrap`.
- **Notable guard**: native-asset wrap requires `msg.value == amount`, otherwise `Errors.InvalidAmount`.

### HUB-02: Unwrapping cannot exceed liquid (bucketed) balance; shortfalls are explicitly queued

- **Statement**: Unwrap requires `0 < amount <= wrappedBalance + marketDerivedBalance`; any unavailable portion is
  tracked via the settlement queue rather than silently failing.
- **Enforced by**:
  - `src/LiquidityHub.sol::_unwrap` reverts `Errors.InvalidAmount(amount, fromBalance)` when out of bounds.
  - The split/queue behaviour is implemented in `LiquidityHubLib.unwrapInternalLogic(...)` (called from `_unwrap`).
  - Queue state is observable via `LiquidityHub.settleQueue(lcc, recipient)` and `LiquidityHub.totalQueued(lcc)`.

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
  - `confirmTake` is intentionally *not* guarded by `nonReentrant` so that future flows can safely allow
    `useMarketLiquidity → ... → confirmTake()` callback patterns.
  - The balance-backed check ensures this flexibility cannot be abused to “mint” reserves via re-entrancy.

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
  \((growthInsideNow - growthInsideLast) * liquidity\).

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
- **Enforced by**:
  - `src/VTSOrchestrator.sol::afterCoreSwap` → `src/libraries/VTSSwapLib.sol::processSwap`
  - `VTSSwapLib._accrueSegmentGrowth`, `_accrueDeficitGlobalGrowth`, `_accrueInflowGlobalGrowth`.

## Commitment backing, signals, and insolvency gates

### SIG-01: VRL nonce must be strictly monotonically increasing per MM

- **Statement**: A new signal for an MM must have `signal.nonce > mmNonce[mmState.owner]`.
- **Enforced by**: `src/VRLSignalManager.sol::_verifyLiquiditySignalInternal` reverts
  `Errors.InvalidNonce(newNonce, prevNonce)` otherwise.

### SIG-02: Signal verification must succeed (or revert when requested)

- **Statement**: When a call requests revert-on-invalid, an invalid proof must revert.
- **Enforced by**: `src/VRLSignalManager.sol::verifyLiquiditySignal(bytes,bool)` reverts `Errors.InvalidProof()` when
  `revertOnInvalid && !ok`.

### COMMIT-01: Commitment backing must satisfy `issuedUsd <= settledUsd + signalUsd` (per-position, per-commit)

- **Statement**: Any MM liquidity increase that would cause the issued commitment value to exceed (settled + signalled)
  backing must revert.
- **Enforced by**:
  - `src/libraries/VTSCommitLib.sol::validateLiquidityDelta` computes issued/settled/signal values and reverts
    `Errors.InvalidLiquiditySignal(issuedValue, signalValue, settledValue)` when insufficient.
  - Called during MM increases by `src/libraries/VTSPositionLib.sol::_handleLiquidityIncrease` with
    `revertIfInsufficientBacking = true`.

### COMMIT-02: Checkpointing with commitment updates `commitmentDeficit` as an insolvency gate

- **Statement**: A commitment checkpoint must set (or reduce/clear) `PositionAccounting.commitmentDeficit` in token
  units based on the USD backing shortfall.
- **Enforced by**: `src/libraries/VTSCommitLib.sol::checkpointWithCommitment`.
- **Consequence**: Positions with non-zero `commitmentDeficit` are **immediately seizable** (see `SEIZE-01`).

### COMMIT-03: “Advancer” binding for checkpoint-with-commitment must hold

- **Statement**: A checkpoint-with-commitment must only accept signals where:
  - the new signal’s owner matches the old owner, and
  - the `sender` equals `mmState.advancer`, and
  - `advancer != owner`.
- **Enforced by**: `VTSCommitLib.checkpointWithCommitment` reverts `Errors.InvalidSender()` when violated.

## Coverage, fee burning, and bounded exercises

### COV-01: Coverage burn is bounded by `(deficit + settled)`; fee burn is capped by deficit

- **Statement**:
  - Effective coverage usage must satisfy \(cov_{eff} = \min(cov, deficit + settled)\).
  - Burn base must satisfy \(burnBase = \min(cov_{eff}, deficit)\).
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_applyCoverageBurn`.

### COV-02: Coverage is applied before position modification to preserve economic integrity

- **Statement**: Coverage burns must be settled before liquidity modification to prevent “cover then avoid burn in same
  call” games.
- **Enforced by**:
  - `src/libraries/VTSPositionLib.sol::settlePositionGrowths` calls `_settleDeficitIndexedCoverageUsage` after settling
    deficit/inflow growths, and is invoked by `CoreHook` *before* modifies.

### COV-03: Coverage increments are meaningful only when there is principal/settled to index against

- **Statement**: Coverage index increments are conditional:
  - If `totalDeficitPrincipal > 0`, increment DICE index; else accrue to residual.
  - If `totalSettled > 0`, increment CISE index; else accrue to residual.
- **Enforced by**: `src/libraries/VTSCommitLib.sol::incrementCoverage`.
- **Practical implication**: Tests should not assume “arbitrary coverage” will always produce burns or index movement.

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
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_settleActive` reverts `"VTSPositionLib: RFS open"` when
  withdrawing while `rfsOpen`.

### SETTLE-02: Seizure settlement is clamped by RFS (for deposits) and by position-required settlement (for withdrawals)

- **Statement**: During seizure, deposits/withdrawals must be clamped to prevent over-settling or extracting value
  outside allowed bounds.
- **Enforced by**: `src/libraries/VTSPositionLib.sol::_settleSeizing` (deposit clamp uses positive RFS; withdrawal clamp
  uses `positionRequiredSettlementDelta`).

### SEIZE-01: A position is seizable if (commitment deficit exists) OR (RFS open AND grace elapsed)

- **Statement**:
  - If `commitmentDeficit.token0 > 0 || commitmentDeficit.token1 > 0`, seizure is immediately permitted.
  - Otherwise, seizure requires an open checkpoint and elapsed grace period for at least one token (including proof
    extensions).
- **Enforced by**: `src/libraries/Checkpoint.sol::isSeizable`, called by `src/VTSOrchestrator.sol::onSeize`.

### SEIZE-02: Grace period extensions require an allowed verifier for the settlement token

- **Statement**: A settlement proof must be verified by an indexed verifier that is both registered and allowlisted for
  the relevant token.
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
- **Enforced by**: `src/libraries/DynamicCurrencyDelta.sol::assertNonZeroDeltas` reverts `Errors.CurrencyNotSettled()`.
- **Practical implication**: Credits do **not** persist across unlock sessions; they are transient and must be consumed
  (eg via `TAKE`, `SYNC`, unwrap flows) within the same batch.

## Authorisation, call-surface, and pause invariants

### AUTH-01: Only owner/approved can settle/burn/modify MM Commit NFTs, except in seizure context

- **Statement**: Settlement and position modification require `approvedOrOwner`, except when operating in an active
  seizure context.
- **Enforced by**:
  - `src/MMPositionActionsImpl.sol::_settle` calls `MMHelpers.assertApprovedOrOwner` unless `_isSeizing(positionId)`.
  - `src/MMPositionActionsImpl.sol::_seizePosition` explicitly forbids owner/approved from seizing and forbids seizing
    inactive positions.

### AUTH-02: Commitment NFTs cannot be transferred mid-batch

- **Statement**: Commitment NFT transfers must not occur while a PoolManager unlock session is active.
- **Enforced by**: `src/MMPositionManager.sol::transferFrom` guarded by `onlyIfPoolManagerLocked` which reverts
  `Errors.PoolManagerMustBeLocked()`.

### PAUSE-01: Global/pool pause must halt sensitive VTS entrypoints

- **Statement**: When paused, swap processing and position processing must revert.
- **Enforced by**:
  - `src/modules/PausableVTS.sol` guards (`notPoolPaused`, `notGlobalPaused`) revert `Errors.EnforcedPause()`.
  - Applied to `src/VTSOrchestrator.sol::processPosition` and `afterCoreSwap` (and to `settlePositionGrowths` for active
    positions).

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

---

## Notes for test authors

- Many invariants above are **batch-scoped** (PoolManager unlock sessions) rather than “global over time”.
- When writing tests that exercise settlement/credit paths, prefer asserting on **balance deltas** and **explicit revert
  selectors** (eg `Errors.CurrencyNotSettled()`, `Errors.TransferNotAllowed()`, `DelegateCallGuard.OnlyDelegateCall()`).
- Do not assume “LCC supply == hub reserves”; supply spans multiple domains and is constrained by **backing checks**
  and **explicit queue mechanics** instead of a single equality.
