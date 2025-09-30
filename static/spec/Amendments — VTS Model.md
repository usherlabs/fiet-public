# Amendments — VTS Model

Date: 2025‑09‑30

## Deficit Timing and Attribution (On‑Chain Precision)

- Deficits are accrued at unwrap time (settlement queueing), not at LCC issuance.
- This reflects when LCCs crystallise into obligations requiring settlement liquidity.
- Consequently, `DeficitEvent` timestamps refer to unwrap events.

## On‑Chain Attribution Policy (Pre‑Oracle)

- Each deficit must be attributed to the swap flow that causally led to the LCC outstanding amount.
- On‑chain attribution will distribute a single `DeficitEvent` across multiple prior `SwapEvent`s in reverse time order, bounded by the ring window, using:
  - price‑path intersection with the position’s range at the chosen swap;
  - per‑swap outflow proportion for the relevant token (`out0` or `out1`);
  - position liquidity at the swap timestamp via `PositionIndex.liquidityAt(positionId, ts)`.
- The attribution consumes deficit amount across matched swaps until fully assigned; no pro‑rata fallback is used on‑chain.
- Settlements reduce per‑position deficits proportionally to market‑level decay from `SettlementEvent`s.

## Off‑Chain Calculator (Future)

- Rings may be flushed to Merkle roots for verifiable off‑chain reconstruction.
- An external calculator can replace on‑chain attribution to improve scale and history depth.
- Until the calculator is enabled, on‑chain multi‑swap attribution is authoritative.
