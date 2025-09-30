# VTSCalculator — Coverage Gate and Oracle Fallback

Date: 2025‑09‑30

## Purpose

This document explains how `VTSCalculatorLib` determines whether it can compute `VTS_required` fully on‑chain from event rings (swaps, deficits, settlements) or must defer to an external oracle. It details the coverage gate, its assumptions, adversarial analysis, and integration guidance.

## Background

`VTS_required(r, A)` attributes each `DeficitEvent` to prior `SwapEvent`s that intersect the position’s price range at each swap timestamp, then applies proportional decay from `SettlementEvent`s. Events are stored in on‑chain ring buffers and periodically flushed (oldest half) with a Merkle root for off‑chain reconstruction.

Because rings are finite, old events can be flushed before all dependent computations complete. The coverage gate ensures on‑chain computation only proceeds when all required history is present; otherwise the calculator reads a cached result from an oracle adapter.

## Coverage Gate Logic

Implemented in `VTSCalculatorLib.calcVTSRequiredWithOracleSupport`.

- Read tail timestamps (earliest retained per ring):
  - `sTailTs`: swaps
  - `deTailTs`: deficits
  - `rTailTs`: settlements
- Let `minDeficitTs = deTailTs` (earliest retained deficit).
- Coverage is OK iff:
  - `sTailTs == 0 || sTailTs <= minDeficitTs` (swaps cover back to the earliest retained deficit), and
  - `rTailTs == 0 || rTailTs <= minDeficitTs` (settlements cover back to the earliest retained deficit).
- If coverage OK: compute on‑chain via `calcVTSRequired`.
- Else: return oracle adapter’s cached result via `getVTSRequiredCached(positionId)`.

Notes:

- `ts == 0` indicates an empty/uninitialised ring and is treated as covering the entire past (i.e., there are no events of that type to consider).
- Tail timestamps are the earliest retained events due to monotonic event timestamps (`block.timestamp`).

## Assumptions

- Events are recorded with non‑decreasing timestamps.
- Rings are dense (no gaps); flush archives the oldest contiguous half.
- On‑chain attribution requires:
  - Swaps at or before each deficit timestamp, and
  - Settlements at or before each deficit timestamp (for decay).
- If any of the above may be missing, prefer oracle data over partial attribution.

## Robustness and Adversarial Analysis

The gate cannot be gamed to compute with missing data. If required history may be missing, the gate falls back to oracle. Attackers can at worst force oracle usage (DoS on fast path), not incorrect results.

Scenarios:

1) Normal operation, full coverage

- Example: `S(100), D(150), R(120)` → tails `s=100, de=150, r=120` → coverage OK → on‑chain.

2) Post‑flush, missing swaps

- Swaps flushed so `sTailTs=200`, deficits at `deTailTs=100` → coverage fails → oracle.

3) Empty/Uninitialised rings

- `sTailTs=0` or `rTailTs=0` is treated as covered (no events to consider) → on‑chain.

4) Same‑timestamp bursts

- `S/D/R` all at `ts=100` → coverage OK → on‑chain.

5) Micro‑unwrap flood (rapid deficits)

- Many deficits advance `deTailTs` forward. Gate anchors to the current earliest retained deficit. Old flushed deficits are ignored on‑chain (oracle maintains full history). Not incorrect, just scoped to retained data.

6) Micro‑settlement flood (rapid settlements)

- Settlements flush forward, making `rTailTs > deTailTs` → coverage fails → oracle.

7) Attempt to force passing with missing history

- Any attempt that removes required swaps or settlements before the earliest retained deficit causes `sTailTs > deTailTs` or `rTailTs > deTailTs` → coverage fails → oracle.

## Integration Guidance

- Configure ring sizes to tolerate expected bursts, especially `deficitRingSize`.
- Consider emitting high‑watermark events or polling ring occupancy to pre‑activate the oracle before flush.
- Optionally extend the gate with freshness checks: compare on‑chain `getFlushedCounts` with oracle’s last processed segment ids and force oracle if chain is ahead.
- Keep the calculator read‑only; never mutate rings during reads.

## API Surface

- `VTSEvents.getTailEventTimestamps(poolId)` → `(swapTailTs, deficitTailTs, settlementTailTs)`
- `VTSCalculatorLib.calcVTSRequiredWithOracleSupport(reader, positionId, meta, index, c0, c1, oracle)` → `(vts0, vts1, usedOracle)`
- `IVTSOracleAdapter.getVTSRequiredCached(positionId)` → `(vts0, vts1, version, swapSeg, deficitSeg, settlementSeg)`

## Future Enhancements

- Add a freshness gate comparing `getFlushedCounts` to oracle watermarks.
- Optional pruning helpers keyed by safe watermarks.
- Batch/aggregate micro events to reduce flush churn under bursts.
