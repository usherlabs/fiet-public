# Uniswap Labs Micro-Audit Context

## Grace Period Extension

> One of the issues allows any caller to effectively reset the grace period for any position in RFS, which normally gives a market maker a fixed window (default = 30 minutes) to settle their obligations after entering RFS (Request for Settlement). After the grace period expires, anyone can seize the market maker's liquidity as collateral. This is the protocol's teeth: without it, market makers have no economic incentive to actually deliver the underlying assets they've committed to. This is a medium because if market makers can defer seizure indefinitely, the LCC tokens they issue run the risk of becoming unbacked (or underbacked) promises. Those holding LCC tokens are exposed to counterparty risk with no recourse. It would be a high-severity finding, but the forced deficit seizure mechanism effectively counters the impact for 2 of the 3 paths in which it applies. This vulnerability essentially acts as a perpetual anti-settlement action for MMs who are solvent but delinquent.

This note responds to comments asserting that any caller can indefinitely reset grace periods for RFS positions.

### Position

1. **`maxGracePeriodTime` is the ultimate cap**
   - Grace extension is bounded by market configuration.
   - Effective extension is capped to `maxGracePeriodTime - gracePeriodTime` per token.
   - This prevents unbounded deferral of seizure via extension alone.

2. **“Undercommitted” (commitment deficit) positions are immediately seizable**
   - If a position has a non-zero `commitmentDeficit` on either token, it is seizable immediately (grace period is bypassed).
   - Therefore, grace-period extension does not protect positions which are undercollateralised by this definition.

3. **`extendGracePeriod` is presently non-operational in production posture**
   - Extension requires a successful settlement-proof verification path.
   - As of now, no settlement proof verifiers are integrated/allowlisted for this flow.
   - Therefore the extension path is not currently usable in live operation until verifier rollout is completed.

4. **Settlement proofs are not intended to be replayable**
   - Proofs are expected to be acquired from the Prover as part of a specific settlement context.
   - The intent is to prove pending fiat settlement and therefore an incoming correlated stablecoin transfer.
   - They are not designed as generic reusable artefacts.

### Additional hardening now included

- `VRLSettlementObserver` now includes on-chain replay protection:
  - `mapping(bytes32 => bool) public usedProofHashes;`
  - Proofs are chain-scoped by `hash(settlementProof)`.
  - Only valid proofs are marked as used.
  - Invalid proofs revert and do not persist any proof-hash state.
  - `CheckpointLibrary.extendGracePeriod` verifies with `revertOnInvalid=true` and reverts on invalid proofs.

This closes the gap between design intent ("proofs should not replay") and enforceable protocol behaviour at the contract layer.

## Finding: replayable settlement proofs can accelerate extensions

> A third finding shows that it is possible to continually extend the grace period for an undercommitted position. Each call to extendGracePeriod() requires a valid VRLSettlementObserver proof, but the function doesn't perform enough validation for this mechanism to be safe. The concern is not that proofs can be faked, but rather that they are reusable: the same proof can be submitted multiple times in a single block since the function doesn't track which proofs have been used. This can be exploited to accumulate a massive extension. A proof representing, say, "$1000 is being settled" can be submitted up to 19 times in a single transaction, which would have 19x the intended impact on the grace period, giving the MM ~10 hours to settle rather than the expected 30 minutes. Note that the first issue above interacts with this one in a complex way that makes it hard to fully grok the impact without spending more time testing the full flow in different scenarios.

### Assessment

- **Before replay protection**: if the same `settlementProof` bytes could be reused, a caller could submit it repeatedly to increase `gracePeriodExtension{0,1}` until it hit the configured ceiling. This does not exceed `maxGracePeriodTime`, but it can reach the cap “immediately” (eg within a single transaction), rather than over multiple independent settlement events.
- **After replay protection (current)**: the same `settlementProof` bytes cannot be submitted more than once on-chain (chain-scoped) because the observer marks the proof hash as used and rejects replays. This closes the “N submissions in one block/tx” amplification vector.

### Residual considerations

- This mechanism intentionally still allows **multiple distinct valid proofs** (eg distinct prover outputs/nonces) to extend a position’s grace period **up to the cap**; controlling the issuance/shape of proofs is a **Fiet Prover (zkTLS) Policy Concern**.

## Dust-sized Commitment Deficits & Seizability

> Another concern is that because dust-sized position deficits can be instantly seized without respecting the grace period there is a perverse incentive in the protocol design. A legitimate MM with $500k in committed liquidity, fully backed by underlying assets in their vault, can be potentially forced to (partially) settle due to normal intraday volatility. However the mechanism for calculating how much of their position must be settled relies on the proportional RFS exposure, not the deficit itself, which could be quite different. Rational actors will monitor makers for any moment where their oracle-derived backing dips below 100% by even 1bps, and as noted above it's completely normal and expected to see >0.01% intraday vol even on stables. And since checkpoint() is permissionless, this creates a condition where bots can profitably compete to partially seize positions that are as much as 99.99% backed. Market makers are forced to either massively over-collateralize or risk seizure from normal market fluctuations. Makers will require much higher compensation to cover the seizure risk from dust deficits, which increases the cost of liquidity for the entire market. Sophisticated attackers can also weaponize this: short an underlying on another venue, trigger a small price movement, then seize multiple positions for profit.

This is a real, protocol-enforced liquidation surface — whether you label it a “vulnerability” depends on intent — but the audit’s economic concern is materially valid given the current mechanics.

**The key nuance is that the “instant seize” path is not about ordinary swap-driven cumulative deficits; it is about commitmentDeficit (an oracle-derived backing shortfall gate).**

### What is true in code pre-patch

- **Checkpoint is permissionless**: any actor can call `VTSOrchestrator.checkpoint(commitId, positionIndex, true)` to run `checkpointWithCommitment` and update `commitmentDeficit`.
- **Any non-zero commitmentDeficit bypasses grace**: `CheckpointLibrary.isSeizable` returns true immediately when `commitmentDeficit.token0 > 0 || commitmentDeficit.token1 > 0`.
  This creates a practical “sniping” surface where bots can crystallise a transient, small oracle-derived shortfall into an immediately-seizable state.

### Options explored

- **Option A — Backing haircut / buffer**: add a static buffer (e.g. treat signals as worth \((1 - haircut)\) when checking backing).
  Rejected: this is synthetic/arbitrary, hard to tune across assets, and undermines the “issued LCCs are backed by settled + signal” invariant framing.

- **Option B — Minimum deficit threshold**: treat small backing shortfalls as non-actionable (do not create an instant-seize condition).
  Partially accepted: appropriate as a noise gate, but must be defined carefully to avoid allowing meaningful insolvency to linger.

- **Option C — Persistence requirement**: require the deficit condition to persist across time / multiple checkpoints before triggering immediate seizability.
  Considered similar in effect to a short grace window.

- **Option D — Short insolvency grace**: reuse the concept of a grace window to allow makers time to cure transient conditions.
  We decided the simplest variant is to **reuse the existing RFS grace** rather than introduce a new window.

- **Option E — Make seizure proportional to deficit**: size seizure directly from deficit magnitude.
  Deprioritised: seizures need to remain sufficiently lucrative to incentivise third-party intervention; a purely deficit-proportional design risks creating “dust deficit build-up” behaviour before anyone is incentivised to act.

### Decision: threshold-gate the grace bypass (per market), reuse existing grace

We will proceed with a combination of Option B and Option D (using the existing grace mechanics):

- **If backing shortfall is material** (above a configurable threshold), then `commitmentDeficit` continues to act as an immediate insolvency gate (grace bypass).
- **If backing shortfall is small** (below threshold), the position may still be in RFS, but it is **not** immediately seizable; it remains subject to the existing grace window.

#### Important implementation detail: threshold should be based on deficit severity (bps), not token-unit ratios

Comparing `commitmentDeficit` token units to `commitmentMax` token units is not a reliable severity measure, because `commitmentDeficit` is derived from _effective_ token amounts at current price, while `commitmentMax` is the maximum across the full tick range.
Instead, the threshold should be expressed in **deficit basis points**:

- \(deficitBps = \\frac{issuedUsd - backingUsd}{issuedUsd}\\) (scaled to 10,000 bps)

This bps value is already computed inside `VTSCommitLib.checkpointWithCommitment` when under-backed; we plan to persist it (per position) and use it to decide whether the grace bypass applies.

#### Note: why Option E (deficit-proportional seizure) is not an appropriate fit

Option E proposes sizing seizure strictly in proportion to the measured deficit magnitude (i.e. “only seize what is needed to cover the deficit”).
While this is directionally intuitive, it breaks the keeper/incentive model that makes seizure a reliable enforcement mechanism:

- **Intervention becomes uneconomic for small deficits**: in practice, a dust or low-bps deficit will often not cover gas + MEV opportunity costs, so rational third parties will not act.
- **This creates a “wait until it’s bad enough” equilibrium**: if seizing is only profitable once the deficit crosses some implicit profitability threshold, then deficits will tend to accumulate (or persist) until they are large enough to justify intervention.
- **Traders bear the externality**: allowing deficits to linger degrades the trading experience/guarantees during the interval where positions are under-backed but no-one is incentivised to seize.
- **The protocol still needs teeth even when the deficit is small**: the goal is timely settlement and credible enforcement, not merely eventual deficit coverage. A purely proportional model weakens the deterrent for “small but persistent” delinquency.

For these reasons, we prefer threshold-gating the grace bypass (Option B + D): it preserves strong incentives to intervene when insolvency is material, while avoiding punitive instant seizure on transient, dust-sized oracle noise.

### Proposed change summary (implementation outline)

- Add **per-market** config: `unbackedCommitmentGraceBypassBps` in `MarketVTSConfiguration`.
- Persist **per-position** severity: `commitmentDeficitBps` in `PositionAccounting`, set during `checkpointWithCommitment`.
- Update `CheckpointLibrary.isSeizable`:
  - If `commitmentDeficit > 0`, only bypass grace when `commitmentDeficitBps >= unbackedCommitmentGraceBypassBps`.
  - Otherwise, require the normal “RFS open + grace elapsed” path.

### Post-patch Implementation

- `MarketVTSConfiguration` now includes `unbackedCommitmentGraceBypassBps` (per-market, bps threshold).
- `PositionAccounting` now includes `commitmentDeficitBps` (persisted at checkpoint time).
- `VTSCommitLib.checkpointWithCommitment` now:
  - sets `commitmentDeficitBps = 0` when sufficiently backed (or no issued value), and
  - sets `commitmentDeficitBps = deficitBps` when under-backed.
- `CheckpointLibrary.isSeizable` now only bypasses grace on `commitmentDeficit` when:
  - `commitmentDeficit > 0` **and**
  - `commitmentDeficitBps >= unbackedCommitmentGraceBypassBps`.
- Additional optional notional guardrails are now supported:
  - `unbackedCommitmentGraceBypassThreshold0`
  - `unbackedCommitmentGraceBypassThreshold1`
  - These thresholds are only evaluated when `commitmentDeficitBps < unbackedCommitmentGraceBypassBps`.
  - If either threshold is configured (`> 0`) and the matching token deficit meets/exceeds it, grace is bypassed.
  - If unset (`0`), the threshold check is omitted entirely.
- Result: dust/noise deficits can still open RFS, but must pass through existing grace unless severity crosses the configured bypass threshold.

### Checkpoint Ordering Adjustment (grace-timing consistency)

- `VTSOrchestrator.checkpoint` now uses this ordering:
  1. `VTSPositionLib.settlePositionGrowths(...)` once,
  2. optional `VTSCommitLib.checkpointWithCommitment(...)`,
  3. `VTSPositionLib.getRFS(...)` (without re-settling growth),
  4. `CheckpointLibrary.markCheckpoint(...)`.
- Rationale: this keeps commitment deficit updates and RFS/open-state transitions on the same state snapshot.
- This avoids a delayed/fresh grace-period start that could otherwise occur if RFS were marked before commitment-derived unbacking was computed.

## Finding: dual-pool architecture enables spot tick manipulation / “core ↔ proxy divergence”

> The fourth finding shows that it is possible to manipulate the pool price via large swaps. This is because the protocol uses a dual-pool architecture (core pool with LCC tokens + proxy pool with underlying). The core pool uses standard v4 concentrated liquidity with its tick and sqrtPrice being used directly by VTS for RFS calculations, deficit/inflow growth accounting, and fee calculations. While the protocol uses an external oracle for commitment backing (which insulates commitmentDeficit from spot manipulation), the tick-based VTS accounting has no such protection. Additionally, the core and proxy pools can diverge after a direct swap on the core pool, which means (1) arbs see a risk-free profit in narrowing the divergence, (2) during the divergence window, any VTS operations execute at distorted prices, and (3) because the onCorePoolDirectSwap() callback occurs after the swap, there's a window during the swap execution itself where the tick is manipulated. By itself, this is a low severity issue, however it also carries a second-order effect of increasing the impact of MEV. Specifically, it distorts VTS accounting for every position touched by hooks during the manipulation window, which implies that a single sandwich can (1) push one or more positions into RFS, (2) increase deficit growth for multiple positions simultaneously, and (3) create price divergence that temporarily misprices the LCC relative to the underlying.

### Clarification: the architecture does **not** create two independently tradeable AMM curves

The finding’s “arb between core and proxy curves” narrative assumes there are two live, independently tradeable price curves: one for LCC↔LCC (core) and one for underlying↔underlying (proxy), both updating in response to swaps.

That is **not** how swaps are implemented in the proxy pool:

- **Proxy-pool swaps are explicitly routed to the core pool.**
  - `ProxyHook._beforeSwap(...)` executes the swap directly on the core pool via `poolManager.swap(corePoolKey, ...)` (see `contracts/evm/src/ProxyHook.sol`, `_beforeSwap`, around the `poolManager.swap(corePoolKey, ...)` call).
  - The proxy hook then performs the underlying/LCC settlement and returns a `BeforeSwapDelta` to the PoolManager (the proxy hook has `beforeSwapReturnDelta` enabled via `getHookPermissions()`).
  - Practically, this means the proxy hook can reduce the proxy-pool swap’s `amountToSwap` (including to zero), so the proxy pool’s own `slot0`/tick is not the price source for execution.

- **The proxy pool does not accept “normal” liquidity provision and is not intended to be a competing price source.**
  - `ProxyHook._beforeAddLiquidity` reverts (`AddLiquidityThroughHookNotAllowed`), and the proxy hook’s purpose is settlement orchestration, not price discovery (see `contracts/evm/src/ProxyHook.sol`).

Accordingly:

- A “divergence” between proxy pool `slot0` and core pool `slot0` (tick/sqrtP) is possible in the _literal state_ sense, but it is **not** two competing tradeable curves.
- Any putative “arb” would not be the standard “buy on proxy / sell on core” CLMM arb, because the protocol does not expose a second autonomous CLMM curve for swaps; proxy swaps are executed against the **core** curve.

### Direct core swaps: what happens, and what does **not** happen

We agree that a user can call `PoolManager.swap(corePoolKey, ...)` directly (i.e. “direct core swap”). This moves the **core** CLMM tick/sqrtP, because it is a real Uniswap v4 concentrated-liquidity pool.

However, the “core↔proxy divergence” resulting from a direct core swap does not create a second tradeable curve:

- After a core swap completes, `CoreHook._afterSwap(...)` performs VTS swap processing (`vtsOrchestrator.afterCoreSwap(...)`), and then (only for a direct core swap) notifies the proxy hook via `ProxyHook.onCorePoolDirectSwap(delta)` (see `contracts/evm/src/CoreHook.sol`, `_afterSwap`, and `contracts/evm/src/ProxyHook.sol`, `onCorePoolDirectSwap`).
- For core swaps that are initiated by the proxy hook (i.e. proxy swaps routed into the core pool), `ProxyHook` sets a transient “proxy swap in progress” flag and `CoreHook` uses that flag to avoid treating the nested core swap as a “direct core swap” (and to avoid recursing into `onCorePoolDirectSwap`). See `contracts/evm/src/libraries/ProxySwapFlag.sol` and its use in `contracts/evm/src/CoreHook.sol` / `contracts/evm/src/ProxyHook.sol`.
- `onCorePoolDirectSwap` is a _settlement-coherence_ callback: it ensures token-in underlying is moved Hub → Vault at a 1:1 with LCC for the inbound leg. It is not a “price sync” mechanism, because there is no separate proxy-pool price curve to sync.

### Timing / execution window: VTS swap processing is invoked **post-swap**

We agree with the general statement “tick can be manipulated via large swaps”, because this is a CLMM. But we want to correct the implied execution window:

- `CoreHook` snapshots `sqrtPBefore`/`liqBefore` in `beforeSwap`, and then calls `vtsOrchestrator.afterCoreSwap(...)` from `CoreHook._afterSwap(...)` (see `contracts/evm/src/CoreHook.sol`).
- Uniswap v4’s `PoolManager.swap(...)` executes the pool swap first, emits the `Swap` event, and only then calls the hook’s `afterSwap` (see `contracts/evm/lib/v4-periphery/lib/v4-core/src/PoolManager.sol`, `swap(...)`).
- `VTSSwapLib.processSwap(...)` reads final post-swap `slot0` from the PoolManager and accrues growth across the segment(s) between `sqrtPBefore` and the final `sqrtPAfter` (see `contracts/evm/src/libraries/VTSSwapLib.sol`, `processSwap(...)`).

Therefore, there is not an obvious intra-swap “mid-execution” window in which _third-party_ VTS operations can run “during the swap” while the tick is in a partially-manipulated transient state. The VTS swap processing is invoked as a normal v4 hook callback **after** the swap has been applied to pool state.

The realistic adversarial model is the standard one: **sandwiching** (or otherwise ordering) discrete protocol interactions around a victim interaction (e.g. a liquidity modification, settlement, or another swap), not re-entering “mid swap step”.

### Residual risk we acknowledge: VTS growth is spot-tick-derived by design

We agree with the core technical premise that:

- **Tick/sqrtP are spot values and can be moved by swaps**, and
- **VTS swap accounting (deficit/inflow growth) is derived from the AMM’s realised price path**.

This is an intentional coupling: VTS deficit/inflow growth is meant to track what the pool actually “experienced” in swap flow, not an oracle-smoothed price.

What makes this acceptable in our design posture:

- **Manipulation is not free**: moving the tick materially requires executing swaps against the core CLMM and paying LP/protocol fees and price impact. The resulting deficit/inflow accrual corresponds to actual executed swap flow on the core pool.
- **The oracle-backed commitment path is insulated (and necessarily oracle-based)**: the high-signal insolvency gate (`commitmentDeficit`) is derived from oracle-priced backing rather than the core pool’s spot tick. This is a design requirement because commitment backing may rely on liquidity that is off-chain and/or not even tokenised; it cannot be proven purely from on-chain spot.
  - The invariant \(issuedUsd \le settledUsd + signalUsd\) explicitly acknowledges the split between (i) on-chain settled value (`settledUsd`) and (ii) oracle-verified value (`signalUsd`).
  - Where assets are tokenised/on-chain, `settledUsd` valuation routes through our oracle contracts and may be supported by an oracle provider that itself references on-chain spot markets (e.g. Uniswap DEX) as an input.
- **Deployment environment reduces public-mempool MEV assumptions**: the protocol is not intended to be deployed on Ethereum L1 with a fully adversarial public mempool. This does not eliminate ordering risk entirely, but it changes the practical MEV surface relative to the audit’s implied environment.

That said, we agree this is correctly categorised as (at most) a **low-severity** economic/mechanism observation: if an attacker can reliably obtain ordering around a victim action, they can move the core tick around that action and thereby affect spot-tick-based VTS calculations for positions touched in that window.

### How we frame this to users/integrators (and potential mitigations)

We treat the proxy pool’s `slot0` as **non-authoritative** for price. The authoritative price curve is the **core** pool, and all swap execution is routed there.

If we ever need to further harden against spot-tick manipulation impacts on VTS accounting, the natural mitigations are:

- using TWAP-style tick inputs for _specific_ risk triggers (not for all growth accounting), and/or
- adding protocol-level constraints on when sensitive actions may be executed relative to swaps (e.g. action-specific sequencing, batching, or private orderflow requirements).

We have not implemented these mitigations at this time because they materially change the mechanism and UX, and because the current deployment posture already assumes an execution environment where adversarial public-mempool sandwiching is not the baseline.
