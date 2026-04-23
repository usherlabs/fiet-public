# Checkpointing and RFS Grace Semantics

_Date: 3rd April 2026_

This note documents the current checkpointing paradigm around:

- `VTSOrchestrator.checkpoint(...)`
- `VTSOrchestrator.onSeize(...)`
- `VTSOrchestrator.extendGracePeriod(...)`
- `RFSCheckpoint.openMask`
- `RFSCheckpoint.openSince0/openSince1`

It is intended to clarify an important design distinction:

- **live RFS** is computed from current accounting state;
- **checkpointed RFS** is the persisted state used for grace timing, seizure gating, and proof-driven grace extension.

This distinction is deliberate. It is also the source of several subtle edge cases if the checkpoint is refreshed at the wrong time.

---

## 1. High-level model

The protocol does **not** continuously persist RFS timing on every state change.

Instead, it uses explicit checkpointing to materialise a canonical stored view of:

- which RFS lanes are open (`openMask`);
- when the currently-open **position-level** RFS episode began (`openSince0/openSince1`);
- any lane-local grace extension that has been granted.

`openSince0/openSince1` are lane-addressable fields, but they represent a shared canonical episode timer.
When both lanes are open, each open lane may hold the same canonical episode timestamp.

This means the protocol has two related but distinct concepts:

1. **Current economic state**
   - What `VTSPositionLib.getRFS(...)` would compute right now from **effective** settled amounts (`pa.settled + pa.settledOverflow` per lane), deficits, commitment deficits, and current position state.

2. **Stored checkpoint state**
   - What the protocol has most recently persisted into `s.positions[positionId].checkpoint`.

The stored checkpoint is what seizure grace and extension logic consume.

---

## 2. What `_checkpoint(...)` actually does

`VTSOrchestrator._checkpoint(...)` is not just a "mark current RFS" helper.

It performs a full state materialisation pipeline:

1. `settlePositionGrowths(...)`
   - crystallises fee / deficit / inflow growth into position accounting so later reads use a consistent snapshot;

2. optional `checkpointWithCommitment(...)`
   - if `withCommitment=true`, recomputes `commitmentDeficit`, `commitmentDeficitSince`, and `commitmentDeficitBps`
     using USD backing from **effective** settled per lane (`pa.settled + pa.settledOverflow`, priced like issuance),
     not live `settled` alone;

3. `getRFS(...)`
   - computes the current live RFS delta from the unified post-settlement snapshot;

4. `markCheckpoint(...)`
   - persists the lane-open state into `RFSCheckpoint`.

The crucial property is that the persisted checkpoint is derived from a **single coherent snapshot**.

---

## 3. Why checkpointing exists at all

Grace timing cannot safely depend on an entirely live, stateless `getRFS(...)` read.

The protocol needs durable answers to questions like:

- when did this open RFS episode begin?
- has grace already been running for this position?
- was grace extended on token0 but not token1?

That information is inherently historical. It must be persisted.

So the checkpoint is not merely a cache. It is the protocol's canonical memory of the current RFS episode.

---

## 4. Canonical `openSince`: continuous-open semantics

The intended meaning of `openSince*` is:

- **not** "the most recent time this exact token lane became open in isolation";
- **but** "the canonical time at which the current **position-level** RFS-open episode began, as represented in checkpoint storage".

The implementation therefore follows three rules.

### 4.1 If the open mask is unchanged, do not overwrite timestamps

If checkpoint A and checkpoint B have the same `openMask`, the position is treated as being in the same stored RFS episode.

`mark(...)` returns early and leaves `openSince*` untouched.

This preserves grace continuity across repeated checkpointing while the stored open state remains the same.

### 4.2 If the open requirement changes lanes without fully closing, inherit the prior timer

If the position was already checkpointed as open, and the open RFS requirement changes lane composition **without an intervening fully-closed checkpoint**, the newly-open lane inherits the canonical prior timer.

This includes:

- `01 -> 11`
- `10 -> 11`
- `11 -> 01`
- `11 -> 10`

That is intentional.

The protocol treats this as one continuous position-level RFS-open episode rather than unrelated lane-specific grace windows. In other words, the grace timer should not reset merely because the positive required-settlement balance moved onto a different currently-open lane.

### 4.3 Only a checkpointed closed -> open transition starts a fresh timer

If the checkpointed state was fully closed (`openMask == 0`) and a later checkpoint marks it open, that is a new stored position-level RFS episode.

In that case, `openSince*` is set to `block.timestamp` for lanes that open in that transition.

Importantly, this refers to the persisted checkpoint timeline, not any uncheckpointed live economic interval. Live RFS may close and later reopen without restarting stored grace if storage was never checkpointed closed in between.

### 4.4 Lane-local grace extension remains lane-local

The canonical `openSince*` episode timer is position-level in meaning, but grace extension remains lane-local.

So a lane transition can preserve canonical episode age while still resetting the extension attached to the lane that
opened or closed. This is intentional: elapsed episode time and extension entitlements are separate dimensions.

---

## 5. Important limitation: continuity only exists if storage already knew about it

The protocol can preserve continuity only from what has already been checkpointed.

If a position was economically open in the live `getRFS(...)` sense, but nobody checkpointed that state yet, then storage does not have a canonical earlier `openSince` to preserve.

So:

- if checkpoint A already recorded the position as open, a later checkpoint B can preserve continuity;
- if no prior open checkpoint exists, checkpoint B necessarily creates the first stored open episode.

This is why "live RFS has been open for a while" and "stored checkpoint grace has been running for a while" are related but not identical concepts.

The converse also matters: "live RFS briefly closed and reopened" does **not** imply that stored grace restarted. A restart requires a checkpointed fully-closed state, not merely an economically closed interval that nobody persisted.

---

## 6. Why `onSeize(...)` does not always checkpoint first

At first glance, it is tempting to make `onSeize(...)` always refresh checkpoint state before testing seizure eligibility.

That would be unsafe for the **normal lane-grace path**.

Why:

1. `_checkpoint(...)` always re-runs `markCheckpoint(...)`;
2. if storage had not yet recorded the open episode, a forced checkpoint during `onSeize(...)` would create that episode "now";
3. the grace test would then be measuring a timer that was just materialised by the seize attempt itself.

That would make seizure depend on whether the caller happened to be the first party to persist the open state, rather than on the intended pre-existing checkpointed grace window.

So `onSeize(...)` only forces `_checkpoint(..., true, ...)` when there is already a stored `commitmentDeficit`.

That path is different because the main safety requirement there is:

- do not allow stale commitment-deficit storage to create durable bypass eligibility.

In short:

- **normal RFS grace path**: preserve stored timer semantics;
- **commitment-deficit bypass path**: refresh stale backing state before trusting bypass.

### 6.1 Incentive model: why ordinary seizure does not refresh the checkpoint

`checkpoint(...)` is intentionally an open, callable maintenance action rather than something reserved to the eventual seizer.

Different actors have different incentives:

- a position owner (or another friendly actor) is incentivised to checkpoint when live RFS has become closed, because a persisted closed checkpoint clears stored ordinary-grace continuity;
- a potential seizer is incentivised to act when the position is economically vulnerable, ie. while live RFS is open and seizure may be profitable;
- a potential seizer is **not** intended to receive a special ability to first checkpoint under new ordinary-RFS conditions and thereby manufacture a fresh grace start or reset immediately before testing seizure.

That asymmetry is deliberate. Ordinary seizure gating consumes the best previously-persisted checkpoint state; it does not give the seizing party a privileged "refresh-then-test" path for lane-grace semantics.

Said differently: the protocol expects checkpoint storage to be shaped by open participation from economically motivated parties over time, not by granting the final seizer a one-shot right to rewrite the relevant ordinary-grace episode at the moment of seizure.

---

## 7. Why `extendGracePeriod(...)` does refresh lane-open state first

`extendGracePeriod(...)` has a different risk profile from `onSeize(...)`.

For proof-driven grace extension, the protocol wants to verify:

- the proof targets a real currently-open settlement lane;
- stale storage should not cause a legitimate extension proof to fail simply because the open lane had not been persisted yet.

So the flow first refreshes:

1. growth settlement;
2. live `getRFS(...)`;
3. `markCheckpoint(...)` from that fresh snapshot;

and only then checks whether the target lane is open for extension.

This is safe because grace extension is not trying to prove that the pre-existing grace timer has already elapsed. It is trying to extend the currently-open lane's allowed grace window.

---

## 8. Relationship to commitment deficits

`commitmentDeficit` is separate from ordinary lane-open grace.

It is a position-level insolvency signal derived from:

- issued position value;
- stored signal backing;
- settled on-chain backing.

When present, it affects both:

- the RFS amount itself, by inflating required settlement;
- seizure rules, by enabling the bypass path after the configured deficit-age / threshold conditions are met.

Unlike ordinary lane grace, stale `commitmentDeficit` state is dangerous in the direction of false seizure eligibility. That is why the bypass path is refreshed inside `onSeize(...)`, while the ordinary lane-grace path is not.

### 8.1 Insolvency freeze on MM liquidity changes

While `commitmentDeficit.token0 > 0` or `commitmentDeficit.token1 > 0`, **non-seizure** MM position modifications with
`liquidityDelta != 0` revert (`Errors.CommitmentDeficitBlocksLiquidityChange`). This is stricter than “RFS closed”:
settling enough to close live RFS does not, by itself, clear stored `commitmentDeficit`; the MM must cure or clear the
insolvency gate (e.g. `checkpoint(..., withCommitment=true)` with sufficient backing, settlement netting via
`_updateSettlement`, or similar) before resizing liquidity.

**Still allowed** while deficit is non-zero:

- MM **no-op** touches (`liquidityDelta == 0`) that only refresh checkpoints / fees;
- **Seizure** decreases (`isSeizing == true` in hook data);
- `onMMSettle` / ordinary settlement paths that improve backing without changing pool liquidity through this gate.

### 8.2 Full deactivation clears the entire commitment-deficit snapshot

When the position liquidity mirror transitions from **strictly positive** to **zero** (full deactivation),
`VTSPositionLib` resets `commitmentDeficit` (both token legs), `commitmentDeficitSince`, and `commitmentDeficitBps`.

**Rationale:** With no remaining issued commitment (liquidity is fully unwound), there is no economic object for the
insolvency gate to describe. Clearing token amounts avoids a pathological stored shape where `commitmentDeficit` is
non-zero but `commitmentDeficitSince` was previously zeroed without clearing amounts, which would incorrectly block
age-gated deficit bypass in `CheckpointLibrary.isSeizable`.

This semantic cleanup is **orthogonal** to §8.1: non-seizure MM `liquidityDelta != 0` remains blocked while stored
deficit is non-zero (defence in depth). MM therefore still cannot rely on “remove to wipe deficit” without first curing
or using the seizure path; non-MM and seizure paths can reach full deactivation and then receive a consistent zeroed
deficit snapshot.

See also:

- `agents/spec/Unbacked-Commitment-Declaration.md`

---

## 9. Practical implications for reviewers and test authors

### 9.1 Do not assume live `getRFS(...)` implies stored grace has already started

A swap or accounting change can make live RFS open immediately.

That does **not** mean `openSince*` has already been persisted unless a checkpointing path has materialised it.

### 9.1A Do not assume live close -> reopen implies stored grace restarted

A reviewer may observe:

1. checkpointed open state at `T0`;
2. a later live economic close;
3. a later live reopen at `T2`;

and conclude that seizure before `T2 + grace` must be invalid.

Under this design, that conclusion is not automatically correct.

If nobody persisted a fully-closed checkpoint between those live states, storage still represents one continuous checkpointed open episode. Ordinary seizure therefore continues to use the existing stored `openSince*` timer.

This is intentional and should not be reported as a bug unless the intended semantics themselves are being challenged.

### 9.2 If a test intends to measure grace elapsed, it must establish a stored open checkpoint first

Typical pattern:

1. create the deficit / open-RFS condition;
2. checkpoint the position so `openSince*` is stored;
3. warp time;
4. assert seizure or grace behaviour.

### 9.3 If a test intends to validate final post-settlement RFS, assert on the returned final state

`onMMSettle(...)` recomputes and persists the final RFS checkpoint after settlement, so its returned `rfsOpen` is the **post-settlement** state, not the pre-settlement state.

### 9.4 MM remove/add tests must respect the commitment-deficit freeze

If a scenario leaves `commitmentDeficit` non-zero, a later non-seizure MM `liquidityDelta != 0` will revert even when
`getRFS(...)` is closed. Establish a zero stored deficit (or use the seizure path) before asserting paused or normal MM
removes.

---

## 10. Summary

The checkpointing paradigm is:

- checkpointing is the protocol's canonical memory of an RFS-open episode;
- `openSince*` tracks the continuous checkpointed RFS episode, not merely the latest lane transition in isolation;
- only a checkpointed fully-closed interval resets ordinary grace; an unpersisted live close/reopen does not;
- lane rotations inherit the prior timer if the position never fully closed;
- unconditional checkpoint refresh during seizure would incorrectly restart ordinary grace when storage had not yet recorded the episode;
- ordinary seizure intentionally does not let the seizing party checkpoint under new lane-grace conditions before testing eligibility;
- checkpointing is an open maintenance action that economically interested parties may call, including owners who want a persisted closed state;
- commitment-deficit bypass is special and may be force-refreshed because stale deficit storage is itself a security risk;
- non-seizure MM liquidity resizing is blocked while stored `commitmentDeficit` is non-zero, independent of whether live RFS is closed;
- full mirror deactivation (liquidity to zero) clears all commitment-deficit storage fields for a consistent post-unwind state;
- grace extension refreshes lane-open state first so valid proofs are not blocked by stale checkpoint storage.

This design intentionally prefers **stable, explicit stored timing semantics** over trying to reconstruct historical openness from live state at the moment of seizure or proof submission.
