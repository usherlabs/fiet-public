# Echidna Fuzzing Invariants Checklist

This checklist is the canonical list of invariants we intend to fuzz with Echidna in this repo.

## LiquidityHub / LCC Backing (Domain A/B + wrapWith + transfer semantics)

- [x] **HUB-A-DELTA-01 (Domain A)**: native wrap is exact 1:1 across `directSupply`, `reserveOfUnderlying`, `totalSupply`, holder buckets, and Hub ETH.

- [x] **HUB-B-DELTA-01 (Domain B)**: `issue` mints market-derived only (no `directSupply`/reserve/Hub ETH changes).

- [x] **HUB-B-QUEUE-01 (Domain B)**: unwrap shortfalls are represented in `settleQueue`/`totalQueued` and reserves are not fabricated.

- [x] **WRAPWITH-CONS-01 (Domain conversion)**: `wrapWith` conserves value (no reserve/ETH fabrication; supply-vs-queue relation preserved).

- [x] **WRAPWITH-QUEUE-01 (Domain conversion)**: `wrapWith` with pre-existing Hub queues does not double-count (no double burn on subsequent settlement).

- [x] **LCC-02 (Transfer semantics)**: non-protocol → protocol transfers annul queued settlement before bucket decrement (no “bleeding” into the queue).

- [x] **HUB-05 (Balance-backed reserves)**: `confirmTake` / reserve accounting must never exceed actual Hub underlying balance (no fabricated reserves).

## Safety / surface “smoke” checks (cheap but useful to keep)

- [x] **LCC-BACKING-01 (no free mint)**: direct `LCC.mint` calls from non-Hub never succeed.

- [x] **LCC-BACKING-01 (no free burn)**: direct `LCC.burn` calls from non-Hub never succeed.

- [x] **HUB-B issuer gating**: `issue` is issuer-gated (non-issuer cannot issue).

- [x] **VALID-LCC-01**: issuer-only `issue` rejects uninitialised LCCs.

- [x] **VALID-LCC-01**: issuer-only `issue` rejects invalid/non-LCC addresses.

- [x] **Bucket sanity (holder-level)**: holder ERC20 balance equals wrapped+market-derived buckets.

- [x] **Bucket sanity (hub vs holder)**: hub `directSupply(lcc)` matches holder wrapped bucket (single-holder harness assumption).

## Domain C / Commit backing (VTS / MM issuance)

- [x] **COMMIT-01 / SIG-BACKING-01 (Domain C)**: MM issuance gate holds: \(issuedUsd \le settledUsd + signalUsd\).
  - Target: `VTSCommitLib.validateLiquidityDelta(...)` (called from `VTSPositionLib._handleLiquidityIncrease`)
