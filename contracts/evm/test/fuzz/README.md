# Echidna fuzz harnesses

This folder contains **Echidna** fuzzing harnesses for protocol invariants.

## How Echidna fuzzing works (in this repo)

These files are **Echidna harness contracts**, not Foundry unit tests. Each harness is a _stateful Solidity contract_
that Echidna deploys once, then interacts with by generating sequences of calls. At a high level:

- Echidna deploys the harness (runs its `constructor()` to set up initial state).
- Echidna generates a sequence of “transactions” (function calls) into the harness to mutate state.
- After and during sequences, Echidna evaluates **properties** (invariants) and fails the run if any property is false.
- When a property fails, Echidna attempts to **shrink** the call sequence to a minimal reproducer.

### Harness structure

In this repository, harnesses follow a consistent pattern:

- **`constructor()`**: deploy real protocol contracts + mocks, configure roles/bounds, seed balances, etc.
- **`action_*` functions**: state-mutating entrypoints for Echidna to call in arbitrary order with arbitrary inputs.
  - Actions often clamp inputs into safe ranges.
  - Actions often use low-level calls / `try/catch` so a revert does not abort the whole fuzz sequence.
- **`echidna_*` functions**: boolean properties that express invariants; Echidna treats any `echidna_*() -> bool`
  as “must always hold”.
  - Many properties use a `checked`/`lastOk` pattern so the property only becomes meaningful after a relevant action
    has executed (avoids vacuous failures before an action has run).
  - Some harnesses include a second trivial property (`*_smoke`) to avoid rare instability when only one property exists.

### What Echidna considers a “test”

The default configuration used by this repo is `contracts/evm/echidna.config.yml`:

- **`testMode: property`**: treat `echidna_*` as properties/invariants.
- **`prefix: echidna_`**: the property prefix.
- **`seqLen`**: the maximum length of call sequences Echidna will explore per run.
- **`testLimit`**: how many sequences to try.
- **`maxValue`**: maximum `msg.value` Echidna may use when calling payable actions (used for native wrap flows).

### How we run Echidna here

We run Echidna through `contracts/evm/scripts/echidna.sh`, which:

- prefers a locally installed `echidna`/`echidna-test` binary when available,
- otherwise falls back to Docker (using Trail of Bits’ toolbox image),
- uses `crytic-compile` with the **Foundry backend** by default in our `yarn` scripts.

We also use a dedicated Foundry profile (`[profile.echidna]` in `contracts/evm/foundry.toml`) to:

- compile only the harnesses under `test/fuzz` (faster, avoids OOM),
- build into a separate output directory (`out-echidna/`),
- hard-link selected libraries for determinism (some harnesses deploy those libraries via `CREATE2` to the linked
  addresses during `constructor()`).

## Run

From `contracts/evm/`:

```bash
# Run all fuzz harnesses
just fuzz
just fuzz-deep

# Run individual harnesses
just echidna-lcc-backing-a
just echidna-sig-backing-01
```

### Troubleshooting

- If you see `error: missing --file or --contract`, it means `scripts/echidna.sh` was invoked without required args.
  As a workaround (and for debugging), you can call the runner directly:

```bash
cd contracts/evm
FOUNDRY_PROFILE=echidna FOUNDRY_OUT_DIR=out-echidna ECHIDNA_COMPILE=foundry \
  sh ./scripts/echidna.sh --file test/fuzz/LiquidityHubLCCBackingEchidnaTest.sol --contract LiquidityHubLCCBackingEchidnaTest
```

## Checklist

This is the canonical list of invariants currently covered by the harnesses in this directory.

## Echidna Fuzzing Invariants Checklist

## LiquidityHub / LCC Backing (Domain A/B + wrapWith + transfer semantics)

- [x] **HUB-A-DELTA-01 (Domain A)**: native wrap is exact 1:1 across `directSupply`, `reserveOfUnderlying`, `totalSupply`, holder buckets, and Hub ETH.

- [x] **HUB-B-DELTA-01 (Domain B)**: `issue` mints market-derived only (no `directSupply`/reserve/Hub ETH changes).

- [x] **HUB-B-QUEUE-01 (Domain B)**: unwrap shortfalls are represented in `settleQueue`/`totalQueued` and reserves are not fabricated.

- [x] **WRAPWITH-CONS-01 (Domain conversion)**: `wrapWith` conserves value (no reserve/ETH fabrication; supply-vs-queue relation preserved).

- [x] **WRAPWITH-QUEUE-01 (Domain conversion)**: `wrapWith` with pre-existing Hub queues does not double-count (no double burn on subsequent settlement).

  - Note: `wrapWith` invariants are also covered by a focused micro-harness (`LiquidityHubWrapWithEchidnaTest`) to keep
    queue/netting expectations deterministic (recommended when iterating on `wrapWith` internals).
  - Coverage expectations (micro-harness):
    - `checkedConserve` and `checkedNetting` should typically flip to true in longer runs (or `just fuzz-deep`).
    - `echidna_wrapWith_conserves_clean` and `echidna_wrapWith_queue_netting_no_double_burn` must always pass.

- [x] **LCC-01 (Transfer gating)**: non-protocol ↔ non-protocol LCC transfers are disallowed unless one endpoint is protocol-bound.

- [x] **LCC-02 (Transfer semantics)**: non-protocol → protocol transfers annul queued settlement before bucket decrement (no “bleeding” into the queue).

- [x] **HUB-05 (Balance-backed reserves)**: `confirmTake` / reserve accounting must never exceed actual Hub underlying balance (no fabricated reserves).

  - Note: HUB-05 is also covered by a callback-focused micro-harness (`LiquidityHubConfirmTakeCallbackEchidnaTest`) to
    force the `unwrap -> useMarketLiquidity -> confirmTake` call chain described in `INVARIANTS.md`.
  - Coverage expectations (micro-harness):
    - `echidna_hub05_callback_seen_or_not` should become “true” in the sense that `callbackSeen` is expected to be reached in most runs.
    - `echidna_hub05_hub_queue_seen_or_not` is a reachability hook; it should be reachable when `action_seed_hub_queue(_large)` is exercised.
    - `echidna_hub05_settlement_attempted_or_not` is a reachability hook; it should be reachable when `action_process_hub_settlement` is exercised.
    - `echidna_hub05_reserve_never_exceeds_hub_balance` must always pass.

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

- [x] **COMMIT-02 (Domain C)**: checkpointing updates `commitmentDeficit` as the insolvency gate derived from backing shortfall.
  - Target: `VTSCommitLib.checkpointWithCommitment(...)`

## Coverage map (invariant → harness → property)

This table links the checklist items above to the exact harness contract and `echidna_*` property function(s).

| Invariant                          | Harness                                                                                    | Property / check                                                               |
| ---------------------------------- | ------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------ |
| HUB-A-DELTA-01                     | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_wrap_native_is_1_to_1`                                                |
| HUB-B-DELTA-01                     | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_issue_market_is_market_derived_only`                                  |
| HUB-B-QUEUE-01                     | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_unwrap_shortfall_is_queued`                                           |
| WRAPWITH-CONS-01                   | `LiquidityHubLCCBackingEchidnaTest.sol` / `LiquidityHubWrapWithEchidnaTest.sol`            | `echidna_wrapWith_conserves` / `echidna_wrapWith_conserves_clean`              |
| WRAPWITH-QUEUE-01                  | `LiquidityHubLCCBackingEchidnaTest.sol` / `LiquidityHubWrapWithEchidnaTest.sol`            | `echidna_wrapWith_queue_netting_no_double_burn`                                |
| LCC-01                             | `LCC01TransferGatingEchidnaTest.sol`                                                       | `echidna_lcc01_user_to_user_blocked`, `echidna_lcc01_user_to_protocol_allowed` |
| LCC-02                             | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_lcc02_annuls_queue_on_protocol_transfer`                              |
| HUB-05                             | `LiquidityHubLCCBackingEchidnaTest.sol` / `LiquidityHubConfirmTakeCallbackEchidnaTest.sol` | `echidna_hub05_reserve_never_exceeds_hub_balance`                              |
| LCC-BACKING-01 (no free mint/burn) | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_no_free_mint`, `echidna_no_free_burn`                                 |
| HUB-B issuer gating                | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_issue_is_issuer_gated`                                                |
| VALID-LCC-01                       | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_issue_rejects_uninitialised_lcc`, `echidna_issue_rejects_invalid_lcc` |
| Bucket sanity (holder-level)       | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_totalSupply_equals_wrapped_plus_marketDerived`                        |
| Bucket sanity (hub vs holder)      | `LiquidityHubLCCBackingEchidnaTest.sol`                                                    | `echidna_directSupply_equals_wrapped_bucket`                                   |
| COMMIT-01 / SIG-BACKING-01         | `VTSCommit01SigBackingEchidnaTest.sol`                                                     | `echidna_sig_backing_01_gate_correct`                                          |
| COMMIT-02                          | `VTSCommit02CheckpointEchidnaTest.sol`                                                     | `echidna_commit_02_checkpoint_deficit_math_correct`                            |
