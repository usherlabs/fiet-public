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
- Result: dust/noise deficits can still open RFS, but must pass through existing grace unless severity crosses the configured bypass threshold.
