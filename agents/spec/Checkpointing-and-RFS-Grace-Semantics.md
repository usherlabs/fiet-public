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
   - What `VTSPositionLib.getRFS(...)` would compute right now from `settled`, deficits, commitment deficits, and current position state.

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
   - if `withCommitment=true`, recomputes `commitmentDeficit`, `commitmentDeficitSince`, and `commitmentDeficitBps`;

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

### 4.3 Only a genuine closed -> open transition starts a fresh timer

If the checkpointed state was fully closed (`openMask == 0`) and later becomes open, that is a new stored position-level RFS episode.

In that case, `openSince*` is set to `block.timestamp` for lanes that open in that transition.

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

See also:

- `agents/spec/Unbacked-Commitment-Declaration.md`

---

## 9. Practical implications for reviewers and test authors

### 9.1 Do not assume live `getRFS(...)` implies stored grace has already started

A swap or accounting change can make live RFS open immediately.

That does **not** mean `openSince*` has already been persisted unless a checkpointing path has materialised it.

### 9.2 If a test intends to measure grace elapsed, it must establish a stored open checkpoint first

Typical pattern:

1. create the deficit / open-RFS condition;
2. checkpoint the position so `openSince*` is stored;
3. warp time;
4. assert seizure or grace behaviour.

### 9.3 If a test intends to validate final post-settlement RFS, assert on the returned final state

`onMMSettle(...)` recomputes and persists the final RFS checkpoint after settlement, so its returned `rfsOpen` is the **post-settlement** state, not the pre-settlement state.

---

## 10. Summary

The checkpointing paradigm is:

- checkpointing is the protocol's canonical memory of an RFS-open episode;
- `openSince*` tracks the continuous checkpointed RFS episode, not merely the latest lane transition in isolation;
- lane rotations inherit the prior timer if the position never fully closed;
- unconditional checkpoint refresh during seizure would incorrectly restart ordinary grace when storage had not yet recorded the episode;
- commitment-deficit bypass is special and may be force-refreshed because stale deficit storage is itself a security risk;
- grace extension refreshes lane-open state first so valid proofs are not blocked by stale checkpoint storage.

This design intentionally prefers **stable, explicit stored timing semantics** over trying to reconstruct historical openness from live state at the moment of seizure or proof submission.
