# Chainlink Functions — VTS Off‑chain Reconstruction

This note outlines how a Chainlink Functions JavaScript job can reconstruct flushed (overflowed) VTSEvents ring histories, verify integrity via Merkle roots emitted on‑chain, and produce precise VTSRequired inputs for an external calculator.

## On‑chain Data Surfaces

- VTSEvents per‑entry events (recent, in‑ring):
  - SwapRecorded(poolId, ts, sqrtP_before, sqrtP_after, out0, out1)
  - DeficitRecorded(poolId, token, deficit, ts)
  - SettlementRecorded(poolId, token, settled, marketDeficitBefore, ts)
- VTSEvents ring flush events (older history):
  - RingFlushed(poolId, ringType, segmentId, root, startIndex, endIndex)
- VTSEvents reader views (for coordination only):
  - getSwapRingState, getDeficitRingState, getSettlementRingState
  - getRingCaps
  - getFlushedCounts, getFlushedRoot

## Reconstruction Procedure (High Level)

1. Fetch recent per‑entry events from the RPC/event logs for the target `poolId`.
2. For each `RingFlushed` segment:
   - Determine `ringType` and `segmentId` and read the expected `root` with `getFlushedRoot`.
   - Gather candidate leaves (ordered entries) for that segment from RPC/event logs using `startIndex..endIndex` bounds.
   - Derive a Merkle root from the ordered leaves using the same hash shape used on‑chain:
     - Swap: keccak256(acc, ts, sqrtP_before, sqrtP_after, out0, out1)
     - Deficit: keccak256(acc, ts, token, deficit)
     - Settlement: keccak256(acc, token, settled, marketDeficitBefore)
   - Verify the computed `root` equals the on‑chain `root`. If not, reject.
3. Merge verified flushed segments with recent entries to produce a complete chronological history per ring.
4. Compute VTSRequired per position:
   - For each `DeficitEvent de`: accumulate across all `SwapEvent sv` where `sv.ts <= de.ts`:
     - Compute price path intersection within the position’s tick range at `sv.ts`.
     - Attribute `posOut` using `SqrtPriceMath.getAmount{0,1}Delta` over intersection with `liquidityAt(positionId, sv.ts)` (queried via the PositionIndex view/graph).
     - Sum pool `outTot` (sv.out0 or sv.out1) and the position’s `posOut`.
   - Attribute `de.deficit * sumPosOut / sumPoolOut` to D(r, token).
   - Apply settlement decay: for each `SettlementEvent se`, reduce D(r, token) by `D * se.settled / se.marketDeficitBefore`.
   - Output `VTSRequired = min(1, D / C)` where C is the commitment cap (query on‑chain).

## Chainlink Functions Sketch (JS)

```js
// Pseudocode sketch
export default async (args) => {
  const { poolIdHex, managerAddress, fromBlock, toBlock } = args;
  // 1) Pull RingFlushed events and per-entry events via public RPC
  const flushed = await getRingFlushedSegments(managerAddress, poolIdHex, fromBlock, toBlock);
  const perEntry = await getPerEntryEvents(managerAddress, poolIdHex, fromBlock, toBlock);

  // 2) For each flushed segment, reconstruct leaves from logs and verify root
  const verifiedSegments = await Promise.all(flushed.map(async (seg) => {
    const leaves = await fetchLeavesForSegment(seg);
    const root = computeSegmentRoot(seg.ringType, leaves);
    const onchainRoot = await viewGetFlushedRoot(managerAddress, poolIdHex, seg.ringType, seg.segmentId);
    if (root !== onchainRoot) throw new Error('Root mismatch');
    return { ringType: seg.ringType, start: seg.startIndex, end: seg.endIndex, leaves };
  }));

  // 3) Merge verified flushed segments + recent per-entry events into full rings
  const rings = materialiseRings(verifiedSegments, perEntry);

  // 4) For each position, compute VTSRequired using attribution + decay
  const results = await computeVTSForPositions(rings, /* positionIndex accessors, commitments, etc. */);

  // 5) Return results for on-chain submission (or signed payload)
  return Results.encode(results);
};
```

## Reorg/Finality and Verification

- Use a block finality buffer (e.g., wait N blocks) before consuming events. Alternatively, pin to L2 state roots if available.
- Flush roots are emitted and immutable; a reorg that precedes the flush would change the emitted root. The processor should:
  - Read `RingFlushed` with a finality buffer.
  - Recompute roots strictly from logs in the confirmed range.
  - Reject if roots diverge from on‑chain `getFlushedRoot`.
- On-chain submission path should include:
  - The set of ring segment ids used and their on‑chain roots (or a digest of them).
  - A hash of the calculator input dataset (e.g., keccak256 of canonicalised events) to bind the off-chain work to the flushed data.
  - Authorisation: Only a whitelisted calculator/oracle contract address can post results (settable by governance). Optionally require ECDSA signature from a known signer.

## Oracle Submission Pattern (On‑chain)

- VTSManager exposes an external-calculator integration that accepts:
  - `(poolId, ringDigest, payloadHash, vtsResults)`
  - Verifies `ringDigest` matches current `getFlushedRoot` set for referenced segments
  - Verifies caller is an authorised calculator contract
  - Updates cached VTSRequired or serves them via view
- Cryptographic alternatives for stronger assurances (optional):
  - Include segment-level Merkle proofs for random sampling (spot-check) to reduce trust; or commit full dataset to a DA layer and verify root equality on-chain (cheap).
  - Leverage succinct proofs (e.g., zkVM) if/when economical; currently costlier than root checks.

## Notes

- The current on-chain emits are sufficient; no extra leaf emission is required.
- Keeping the on-chain hashing scheme stable is critical for off-chain root parity.
- The processor must replicate the on-chain ordering and attribution logic exactly.
