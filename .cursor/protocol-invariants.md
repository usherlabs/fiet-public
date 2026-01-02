# Protocol invariants (tests must respect)

## Coverage bound: `incrementCoverage()` cannot exceed realised amounts

In this protocol, `incrementCoverage()` is invoked via **LCC unwrap** (`contracts/evm/src/LCC.sol` → LiquidityHub/Factory → `VTSOrchestrator.incrementCoverage`).

Because unwrap is backed by **actual liquidity inside the AMM**, coverage is **economically bounded**:

- **Coverage cannot exceed what is actually available/realised in the system** for that token at that time.
- In particular, tests must **not** assume `incrementCoverage(amount)` can be arbitrarily larger than:
  - realised swap-driven outflows/deficits over the relevant interval, or
  - the amount made available via unwind/unwrap of liquidity.

Practical test implication:

- When writing DICE/CISE/CSI tests, ensure `incrementCoverage(...)` is sized to something plausibly obtainable from prior swaps/unwraps in the scenario (otherwise burns/bonuses may correctly be 0 and spend indices won’t advance).

## Delta settlement is per-unlock: batches must end with zero nonzero-delta count

Delta accounting is transient and enforced at the end of each `MMPositionManager.modifyLiquidities(...)` / `MMA.executeWithUnlock(...)` session:

- **All deltas must be netted within the same unlock/batch**, or the batch will revert with `Errors.CurrencyNotSettled()`.
- **Credits/deltas do not persist across unlock sessions** (tests must not assume a credit “created earlier” remains available in a later `executeWithUnlock`).

Practical test implication:

- Any batch that intentionally creates deltas must also include the actions that consume/drain them (typically `TAKE`, and sometimes `SYNC`, `UNWRAP_*`, etc.), otherwise you should `expectRevert(Errors.CurrencyNotSettled.selector)`.

## Credits are delta-based, not “free balances”

The system’s “credit” semantics are defined by positive deltas:

- `take()` consumes only **positive delta (credit)** for the target; if no credit exists, it returns 0.
- A `TAKE` can transfer **at most** what the manager contract actually holds as an ERC20 balance for that currency.

Practical test implication:

- When asserting `TAKE` behaviour, prefer assertions on **balance deltas** (after-before) and/or explicit success paths, rather than assuming credit persists beyond the batch.

## `MMPositionActionsImpl` is delegatecall-only (security + storage invariant)

`MMPositionActionsImpl.handleAction(...)` must be called via delegatecall from `MMPositionManager`:

- Direct calls to the implementation are not part of the supported surface and should revert (delegatecall guard).

Practical test implication:

- If you test the guard, assert the **specific** error selector (not “any revert”), and provide well-formed calldata so you don’t accidentally revert on ABI decoding.

## Authorisation invariant: only owner/approved can settle/burn unless in seizure context

Normal position operations must enforce:

- **`assertApprovedOrOwner(msgSender(), tokenId)`** for settle/mint/increase/decrease/burn-style flows.

The protocol also has an explicit “seize” context:

- When a position is being seized (tracked via transient state), the normal approval gate for certain settle paths is bypassed by design.

Practical test implication:

- For auth tests, the simplest invariant is: an unapproved caller cannot `_settle` (negative deltas / deposits) into someone else’s position.
- For seizure tests, ensure the position is in a “seizing” context before asserting bypass behaviour.

## Commitment maxima are risk bounds, not “effective” or “required” settlement amounts

`LiquidityUtils.calculateCommitmentMaxima(...)` returns an upper bound on potential token0/token1 exposure for a tick range and liquidity:

- **Even if a position is effectively one-sided at the current tick**, commitment maxima can be non-zero on both sides.
- Therefore, a position can be settled on both tokens even when its current composition is one-sided.

Practical test implication:

- To create one-sided settlement/credit scenarios, drive them using **effective required settlement amounts** (eg `_calculateSettlementAmounts(...)` / current-tick logic) and explicitly settle **only one side**, rather than relying on tick-range “one-sidedness” alone.

## Liquidity availability invariant: settleable vs queued liquidity

Burn/decrease flows distinguish between:

- **settleable** liquidity (available immediately) and
- **queued** liquidity (shortfall tracked in the hub/queue).

Practical test implication:

- Tests that assume immediate withdrawals must ensure the scenario actually produces settleable liquidity; otherwise it’s correct for withdrawals to be delayed/queued or for net effects to be smaller than maxima.
