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
just echidna-lcc-backing
just echidna-commit-01
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

The **source of truth** for protocol invariants is `contracts/evm/INVARIANTS.md`.

This README is a **coverage tracker** for:

- which `INVARIANTS.md` items are covered by Echidna harnesses in this directory, and
- which invariants are still missing (and what the next priorities are).

Important: some IDs in this README (e.g. `WRAPWITH-CONS-01`) are **test-check IDs** (micro-properties / decompositions)
used by the harness authors. They are _not_ canonical protocol invariant IDs, and they should always map back to one or
more `INVARIANTS.md` invariants.

### Coverage (from `INVARIANTS.md`)

This table is keyed by **canonical** invariant IDs from `INVARIANTS.md`. It is the main “what’s done / what’s next”
view.

- **Needs property?**: “Yes” means we should prefer a property-based test (Echidna and/or invariant-style Foundry)
  because manual inspection is unreliable.
- **Status**: “Covered” means there is at least one non-trivial check; “Partial” means the invariant is exercised but
  not comprehensively (or only in a narrow harness assumption).

| Invariant (`INVARIANTS.md`) | Priority | Needs property? | Status                | Evidence (Echidna)                                                                                                                             | Notes                                                                                                     |
| --------------------------- | -------- | --------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **COV-01**                  | **P1**   | Yes             | **Covered**           | `VTSCoverageBurnCOV01EchidnaTest.sol` → `echidna_cov_01_burn_base_bounded`                                                                     | Focused harness for `_applyCoverageBurn` maths bounds.                                                    |
| **COV-02**                  | **P1**   | Yes             | **Covered**           | `VTSCoverageBurnCOV02EchidnaTest.sol` → `echidna_cov_02_settle_before_modify`                                                                  | Sequencing: coverage burns must be settled before modifies.                                               |
| **COV-03**                  | **P1**   | Yes             | **Covered**           | `VTSCoverageBurnCOV03EchidnaTest.sol` → `echidna_cov_03_conditional_index_increment`                                                           | Conditional index increments; easy to get wrong under zero-principal cases.                               |
| **FEE-01**                  | **P1**   | Yes             | **Covered**           | `VTSFee01QueueVsMaterialisedEchidnaTest.sol` → `echidna_fee_01_queue_vs_pot`, `echidna_fee_01_materialise_updates_pot_only`                    | Queue-vs-materialised fee pot is subtle and regression-prone.                                             |
| **FEE-02**                  | **P1**   | Yes             | **Covered**           | `VTSFee02NoBonusOnCreationEchidnaTest.sol` → `echidna_fee_02_no_bonus_on_creation`                                                             | “New positions don’t get bonuses on creation” is a tricky edge case.                                      |
| **VTS-02**                  | **P1**   | Yes             | **Covered**           | `VTSSwapVTS02FlipOutsideEchidnaTest.sol` → `echidna_vts_02_flip_identity`                                                                      | Tick-cross flip identity; easy to regress with accounting refactors.                                      |
| **VTS-03**                  | **P1**   | Yes             | **Covered**           | `VTSSwapVTS03SegmentGrowthEchidnaTest.sol` → `echidna_vts_03_segment_growth_accounting`                                                        | Segment-based deficit/inflow growth accounting.                                                           |
| **DELTA-01**                | **P1**   | Yes             | **Covered**           | `VTSCurrencyDelta01EchidnaTest.sol` → `echidna_delta_01_nonzero_deltas_revert`                                                                 | End-of-batch delta netting; very hard to eyeball across flows.                                            |
| **HUB-01**                  | **P2**   | Yes             | **Covered (partial)** | `LiquidityHubLCCBackingEchidnaTest.sol` → `echidna_wrap_native_is_1_to_1`                                                                      | Currently covers native wrap invariants under harness assumptions.                                        |
| **HUB-02**                  | **P2**   | Yes             | **Covered (partial)** | `LiquidityHubLCCBackingEchidnaTest.sol` → `echidna_unwrap_shortfall_is_queued`                                                                 | Exercises explicit queue semantics for unwrap shortfalls.                                                 |
| **HUB-03**                  | **P3**   | Yes             | **Covered (partial)** | `LiquidityHubLCCBackingEchidnaTest.sol` → `echidna_issue_rejects_uninitialised_lcc`, `echidna_issue_rejects_invalid_lcc`                       | Maps to “issuer-only paths reject invalid/uninitialised LCCs”.                                            |
| **HUB-04**                  | **P3**   | Yes             | Not started           | —                                                                                                                                              | “Same factory” constraint on pair-based operations.                                                       |
| **HUB-05**                  | **P1**   | Yes             | **Covered**           | `LiquidityHubLCCBackingEchidnaTest.sol` / `LiquidityHubConfirmTakeCallbackEchidnaTest.sol` → `echidna_hub05_reserve_never_exceeds_hub_balance` | Includes callback-style reachability harness.                                                             |
| **SETTLE-01**               | **P1**   | Yes             | **Covered**           | `VTSSettle01RFSOpenEchidnaTest.sol` → `echidna_settle_01_withdraw_reverts_when_rfs_open`                                                       | Withdrawals must revert while RFS open (unless seizing).                                                  |
| **SETTLE-02**               | **P2**   | Yes             | Not started           | —                                                                                                                                              | Seizure settlement clamps (deposit/withdraw bounds).                                                      |
| **SEIZE-01**                | **P2**   | Yes             | Not started           | —                                                                                                                                              | Seizable predicate: commitment deficit OR (RFS open + grace).                                             |
| **SEIZE-02**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | Allowed verifier requirement for grace extensions.                                                        |
| **SEIZE-03**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | Seizure flows cannot issue LCC.                                                                           |
| **SEIZE-04**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | MM ops must not change commit identity.                                                                   |
| **LCC-BACKING-01**          | **P1**   | Yes             | **Covered (partial)** | `LiquidityHubLCCBackingEchidnaTest.sol` → `echidna_no_free_mint`, `echidna_no_free_burn` (+ wrapWith checks)                                   | “No free mint/burn” is covered; domain accounting is partially covered via wrap/issue/wrapWith harnesses. |
| **LCC-01**                  | **P2**   | Yes             | **Covered**           | `LCC01TransferGatingEchidnaTest.sol` → `echidna_lcc01_user_to_user_blocked`, `echidna_lcc01_user_to_protocol_allowed`                          | Transfer gating invariant.                                                                                |
| **LCC-02**                  | **P1**   | Yes             | **Covered**           | `LiquidityHubLCCBackingEchidnaTest.sol` → `echidna_lcc02_annuls_queue_on_protocol_transfer`                                                    | Queue annul semantics on protocol transfer.                                                               |
| **LCC-03**                  | **P1**   | Yes             | Not started           | —                                                                                                                                              | Nested ingress settlement must preserve outer `sync(lcc) -> transfer -> settle()` and enforce at-most-one unpaid ingress per active sync window. |
| **COMMIT-01**               | **P1**   | Yes             | **Covered**           | `VTSCommit01SigBackingEchidnaTest.sol` → `echidna_sig_backing_01_gate_correct`                                                                 | Issuance gate \(issuedUsd \le settledUsd + signalUsd\).                                                   |
| **COMMIT-02**               | **P1**   | Yes             | **Covered**           | `VTSCommit02CheckpointEchidnaTest.sol` → `echidna_commit_02_checkpoint_deficit_math_correct`                                                   | Math-heavy; promoted to P1 given your rubric.                                                             |
| **COMMIT-03**               | **P3**   | Yes             | Not started           | —                                                                                                                                              | “Advancer binding” correctness under checkpoint-with-commitment.                                          |
| **PAUSE-01**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | Guard application is broad and regression-prone.                                                          |
| **SIG-01**                  | **P3**   | Yes             | Not started           | —                                                                                                                                              | Nonce monotonicity across state transitions.                                                              |
| **SIG-02**                  | **P3**   | Yes             | Not started           | —                                                                                                                                              | “Revert-on-invalid” behaviour; correctness across call sites.                                             |
| **VTS-01**                  | **P3**   | Yes             | Not started           | —                                                                                                                                              | Must always settle growths before liquidity modification.                                                 |
| **AUTH-01**                 | **P3**   | Yes             | Not started           | —                                                                                                                                              | Hard to eyeball all surfaces; especially with seizure context exceptions.                                 |
| **AUTH-02**                 | **P3**   | Yes             | Not started           | —                                                                                                                                              | “No mid-batch transfer” is a global property across unlock sessions.                                      |
| **MKT-05**                  | **P1**   | Yes             | **Covered**           | `ProxySwapMKT05LiveEchidnaTest.sol` → `echidna_mkt05_live_amountToSwap_is_zero`                                                                |Proxy pool AMM curve must never be utilised; prevent proxy `slot0` drift/DoS and enforce “core-only curve”.|
| **MKT-06**                  | **P2**   | No              | Not started           | —                                                                                                                                              | Canonical market pair ordering must be core/LCC order (events + `(0,1)` lanes are core-ordered).          |
| **MKT-01**                  | P3       | No              | Not started           | —                                                                                                                                              | Mostly an explicit revert surface; lower risk than maths/state-machine items.                             |
| **MKT-02**                  | P3       | No              | Not started           | —                                                                                                                                              | Write-once property; easy to review, still worth testing.                                                 |
| **MKT-03**                  | P3       | No              | Not started           | —                                                                                                                                              | “Core pool cannot be created twice” is largely structural.                                                |
| **MKT-04**                  | P3       | No              | Not started           | —                                                                                                                                              | Factory/issuer boundaries are structural; still good to keep coverage.                                    |

## Implemented Echidna checks (test-check IDs)

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
| COV-01                             | `VTSCoverageBurnCOV01EchidnaTest.sol`                                                      | `echidna_cov_01_burn_base_bounded`                                             |
| COV-02                             | `VTSCoverageBurnCOV02EchidnaTest.sol`                                                      | `echidna_cov_02_settle_before_modify`                                          |
| COV-03                             | `VTSCoverageBurnCOV03EchidnaTest.sol`                                                      | `echidna_cov_03_conditional_index_increment`                                   |
| FEE-01                             | `VTSFee01QueueVsMaterialisedEchidnaTest.sol`                                               | `echidna_fee_01_queue_vs_pot`, `echidna_fee_01_materialise_updates_pot_only`   |
| FEE-02                             | `VTSFee02NoBonusOnCreationEchidnaTest.sol`                                                 | `echidna_fee_02_no_bonus_on_creation`                                          |
| VTS-02                             | `VTSSwapVTS02FlipOutsideEchidnaTest.sol`                                                   | `echidna_vts_02_flip_identity`                                                 |
| VTS-03                             | `VTSSwapVTS03SegmentGrowthEchidnaTest.sol`                                                 | `echidna_vts_03_segment_growth_accounting`                                     |
| DELTA-01                           | `VTSCurrencyDelta01EchidnaTest.sol`                                                        | `echidna_delta_01_nonzero_deltas_revert`                                       |  
