---
name: Reserve Liveness Supplement
overview: "Add an explicit supplement to the Market Action Sequencer plan covering the original liveness fix: reserve-capped, best-effort `Hub -> vault` settlement so direct core actions no longer revert when shared Hub reserves are temporarily depleted."
todos:
  - id: cap-hub-settlement
    content: Make _settleUnderlyingToVaultFromHub reserve-capped and no-op on zero availability instead of relying on full prepareSettle amount succeeding.
    status: pending
  - id: clarify-sequencer-vs-liveness
    content: Document that the sequencer proves wrapped eligibility and ordering, while reserve sufficiency remains best-effort at settlement time.
    status: pending
  - id: add-liveness-regressions
    content: Add tests showing direct swaps and direct LP adds no longer revert when Hub reserves are partially or fully depleted.
    status: pending
isProject: false
---

# Reserve Liveness Supplement

## Purpose

This supplement closes the gap left implicit in the main Market Action Sequencer plan: provenance sequencing fixes *which* portion of a direct core action should source liquidity from `LiquidityHub`, but it must be paired with an explicit liveness rule for *how much* is actually moved when Hub reserves are currently contested.

The current hard revert lives here:

```835:843:contracts/evm/src/LiquidityHub.sol
function prepareSettle(address lcc, uint256 amount) external onlyIssuer(lcc) nonReentrant {
    if (amount == 0) revert Errors.InvalidAmount(0, 0);

    address underlying = s.lccToUnderlying[lcc];
    if (s.reserveOfUnderlying[underlying] < amount) {
        revert Errors.InvalidAmount(amount, s.reserveOfUnderlying[underlying]);
    }

    s.reserveOfUnderlying[underlying] -= amount;
```

And direct core settlement still relies on that full amount succeeding:

```191:198:contracts/evm/src/modules/MarketVault.sol
function _settleUnderlyingToVaultFromHub(ILCC lccToken, uint256 amount) internal {
    liquidityHub.prepareSettle(address(lccToken), amount);

    Currency uaCurrency = Currency.wrap(lccToken.underlying());
    address payer = uaCurrency.isAddressZero() ? address(this) : address(liquidityHub);
    _settleUnderlyingToVaultFromSender(uaCurrency, payer, amount);
}
```

## Required Outcome

Direct core swaps and direct LP adds must no longer revert merely because shared Hub reserves were consumed earlier in the same block / transaction ordering race.

The combined design should be:

- the sequencer determines the wrapped-only portion eligible for `Hub -> vault` movement
- the vault settlement path caps that movement to currently available Hub reserve
- reserve shortfall becomes partial/no-op settlement, not a revert

## Planned Changes

### 1. Make `Hub -> vault` settlement explicitly best-effort

Update `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/MarketVault.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/MarketVault.sol)` so `_settleUnderlyingToVaultFromHub(...)`:

- reads current available reserve with `liquidityHub.reserveOfUnderlying(address(lccToken))`
- computes `toSettle = min(requestedWrappedAmount, availableReserve)`
- returns early when `toSettle == 0`
- calls `prepareSettle(...)` only for `toSettle`
- settles only `toSettle` into the vault

Documentation requirement:

- add a method comment explaining that this path is intentionally liveness-preserving for direct core actions and must not revert on reserve competition

### 2. Preserve strict sequencing, but not strict reserve sufficiency

Amend the main sequencing plan semantics in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MarketActionSequencer.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/MarketActionSequencer.sol)` and `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MarketFactory.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/MarketFactory.sol)`:

- unresolved provenance / ordering mismatches should still be treated as sequencing failures
- insufficient Hub reserve should **not** be treated as a sequencing failure
- dispatch into `VaultCoreActionHandler.handleSwap(...)` / `handleLiquidity(...)` should pass the wrapped-eligible amount, after which vault settlement is best-effort against live reserve

Documentation requirement:

- add comments making clear that the sequencer proves eligibility, not reserve availability

### 3. Keep obligation settlement best-effort after direct actions

Retain the existing best-effort behaviour of `_settleObligations(...)` and `_settleObligationsForLCC(...)` in `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/MarketVault.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/MarketVault.sol)`, and document that post-action obligation fulfilment remains opportunistic.

This keeps the direct-core path consistent:

- best-effort Hub -> vault movement for wrapped liquidity
- best-effort vault -> Hub movement for queued obligations

### 4. Add explicit liveness regression tests

Extend direct-core tests to prove that reserve contention no longer causes direct action reverts.

Files:

- `[/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/CoreHook.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/CoreHook.t.sol)`
- any direct `ProxyHook` / `MarketFactory` integration tests covering core swaps and direct LP adds

Test focus:

- direct swap proceeds when wrapped-eligible amount exceeds current reserve, settling only the available reserve
- direct LP add proceeds when one or both wrapped legs exceed current reserve, settling each leg up to availability
- zero available reserve is a no-op for Hub -> vault movement, not a revert
- provenance mismatch or unresolved sequencing still fails distinctly from reserve shortfall

## Relationship To Main Plan

This supplement should be implemented alongside the Market Action Sequencer plan, not instead of it.

The main plan fixes:

- wrapped-vs-market-derived correctness
- ordering independence across router / locker execution
- inheritance and handler boundaries

This supplement fixes:

- original liveness vulnerability caused by strict `prepareSettle` reserve gating

