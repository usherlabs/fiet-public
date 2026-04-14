# Scan #17 Targeted Remediations

> **Modules**: `CoreHook`, `ProxyHook`, `MarketVault`, `LiquidityHub`, `LiquidityHubLib`, `VTSOrchestrator`  
> **Author**: Fiet Protocol  
> **Last Updated**: April 2026

## Overview

This spec defines targeted remediations for scan #17 items `#1`, `#2`, and `#4`:

1. `CoreHook` pre-swap tick snapshot encoding/decoding safety.
2. Native fully-deficit queue recipient serviceability in issuer deficit flows.
3. Write-once `initPool` semantics in `VTSOrchestrator`.

The intent is to fix concrete liveness and configuration hazards without changing the core economic model, queue accounting model, or trusted-role boundaries already documented in `INVARIANTS.md`.

## Design Goals

1. Preserve VTS swap attribution semantics while hardening pre-swap tick snapshot integrity.
2. Keep fully-deficit settlement support, but reject native recipient shapes that are not serviceable.
3. Prevent silent pool config overwrite/unpause through repeated `initPool` calls.
4. Keep ERC20 behaviour unchanged for queueing and settlement recipient handling.
5. Keep changes narrow and implementation-auditable.

## Item #1: CoreHook Tick Snapshot Encoding

### Problem Statement

`CoreHook` currently stores pre-swap tick into transient storage via an unsigned slot conversion and later reconstructs it through a reverse cast:

```text
TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tstore(uint256(int256(tickBefore)));
...
int24 tickBefore = int24(int256(TransientSlot.asUint256(TransientSlots.TICK_BEFORE_SLOT).tload()));
```

This boundary must be explicit and robust for all valid `int24` ticks, including negative values.

### Required Behaviour Change

1. Replace the current implicit cast round-trip with an explicit signed encoding/decoding scheme for the transient tick snapshot.
2. Keep the authoritative source as `slot0.tick` read in `_beforeSwap`.
3. Preserve existing sequencing:
   - snapshot in `_beforeSwap`
   - consume in `_afterSwap`
   - clear transient slots immediately after read
4. Do not change swap economics, growth formulas, or downstream `afterCoreSwap(...)` semantics.

### Implementation Notes

- Centralise encode/decode (either helper functions or a small dedicated library section) so the signed boundary is auditable.
- Keep storage format fixed-width and deterministic.
- Add comments describing why this snapshot must not be recomputed from `sqrtPBefore` alone (consistent with `VTS-03`).

## Item #2: Native Fully-Deficit Recipient Serviceability

### Problem Statement

Fully-deficit issuer flows currently support:

1. transfer deficit LCC to a resolved recipient, then
2. queue settlement for that recipient.

For native-backed LCC, settlement later requires an ETH transfer to that same recipient. If recipient shape is unsupported for native payout, queue rows can become uncleareable in practice.

### Selected Policy

Strict on-chain rejection for unsupported recipients in native fully-deficit queueing paths.

### Required Behaviour Change

1. For native-backed LCC (`underlying == address(0)`), fully-deficit queueing must revert when resolved `deficitRecipient` is not a supported native payout target.
2. Enforce this at queue-admission time (issuer deficit queue path), not at delayed settlement time.
3. Preserve existing queue owner validation and market-derived backing checks.
4. Preserve ERC20 recipient behaviour unchanged.

### Control Points

- `ProxyHook`: recipient resolution remains as-is.
- `MarketVault._cancelLCCWithDeficit(...)`: fully-deficit branch remains supported, but queueing to unsupported native recipient shapes must fail.
- `LiquidityHub.queueForTransferRecipient(...)` / validation helpers: extend serviceability checks for native lane recipient compatibility.

### Non-Goals

- No redesign to pull-based native settlement in this iteration.
- No change to generic queue semantics outside this strict native recipient gate.

## Item #4: Write-Once initPool

### Problem Statement

`VTSOrchestrator.initPool(...)` currently overwrites pool config and resets `isPaused` without a prior-initialisation guard.

### Selected Policy

Write-once initialisation. Any repeated initialisation for an existing pool id must revert.

### Required Behaviour Change

1. `initPool(...)` must revert when called for an already-initialised `PoolId`.
2. Initial call behaviour remains unchanged.
3. No migration/admin re-init escape hatch is added in this iteration.

### Security Intent

This removes silent overwrite risk for:

- `vtsConfig`
- pool pause state (`isPaused`)

while keeping the existing `onlyFactory` boundary in place.

## Invariant Impact

The remediations align with these invariants:

- `VTS-03`: pre-swap authoritative tick snapshot integrity remains required and explicit.
- `HUB-02` / `HUB-02A`: queue semantics remain intact; this change tightens native recipient serviceability only for issuer deficit queueing.
- `MKT-03`: write-once pool initialisation behaviour is made explicit in orchestrator state handling.
- `MKT-04`: issuer/factory role boundaries are unchanged; stricter checks are applied inside privileged flows.
- `PAUSE-01`: write-once `initPool` avoids accidental pause-state reset via re-initialisation.

## Test Plan

### Item #1 Tests (CoreHook tick snapshot)

1. Unit/regression test for negative pre-swap tick:
   - set pool state to a negative tick
   - execute swap path through `_beforeSwap` and `_afterSwap`
   - assert successful pass-through to `afterCoreSwap(...)` with correct `tickBefore`.
2. Boundary tests for min/max valid tick values.
3. Regression test to confirm transient slots are still cleared after `_afterSwap`.

### Item #2 Tests (native fully-deficit recipient)

1. Native market, fully-deficit path, unsupported recipient:
   - deficit recipient resolves to unsupported native payout target
   - assert revert at queue-admission stage.
2. Native market, fully-deficit path, supported recipient:
   - assert queueing succeeds and settlement remains processable.
3. ERC20 market parity:
   - assert equivalent recipient flow remains unchanged.
4. Existing market-derived balance/serviceability checks remain enforced.

### Item #4 Tests (`initPool` write-once)

1. First `initPool(...)` call succeeds for new pool id.
2. Second `initPool(...)` call for same pool id reverts.
3. `MarketFactory.createMarket(...)` flow remains functional for first-time initialisation.
4. Regression assertion: repeated call cannot reset `isPaused` or overwrite `vtsConfig`.

## Follow-Up Documentation

After implementation, add a small follow-up in `contracts/evm/INVARIANTS.md` to codify:

1. explicit signed pre-swap tick transient encoding under `VTS-03`;
2. native recipient serviceability assumptions for fully-deficit issuer queueing under `HUB-02`;
3. write-once orchestrator pool initialisation near `MKT-03`/structural market invariants.
