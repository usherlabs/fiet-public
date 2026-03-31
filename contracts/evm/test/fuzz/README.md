# Echidna fuzz harnesses

This folder contains **Echidna** fuzzing harnesses for protocol invariants.
All invariant harnesses live in **`invariants/`**.

## How Echidna fuzzing works (in this repo)

These files are **Echidna harness contracts**, not Foundry unit tests. Each harness is a _stateful Solidity contract_
that Echidna deploys once, then interacts with by generating sequences of calls. At a high level:

- Echidna deploys the harness (runs its `constructor()` to set up initial state).
- Echidna generates a sequence of "transactions" (function calls) into the harness to mutate state.
- After and during sequences, Echidna evaluates **properties** (invariants) and fails the run if any property is false.
- When a property fails, Echidna attempts to **shrink** the call sequence to a minimal reproducer.

### Harness structure

In this repository, harnesses follow a consistent pattern:

- **`constructor()`**: deploy real protocol contracts + mocks, configure roles/bounds, seed balances, etc.
- **`action_*` functions**: state-mutating entrypoints for Echidna to call in arbitrary order with arbitrary inputs.
  - Actions often clamp inputs into safe ranges.
  - Actions often use low-level calls / `try/catch` so a revert does not abort the whole fuzz sequence.
- **`echidna_*` functions**: boolean properties that express invariants; Echidna treats any `echidna_*() -> bool`
  as "must always hold".
  - Many properties use a `checked`/`lastOk` pattern so the property only becomes meaningful after a relevant action
    has executed (avoids vacuous failures before an action has run).
  - Some harnesses include a second trivial property (`*_smoke`) to avoid rare instability when only one property exists.

### What Echidna considers a "test"

The default configuration used by this repo is `contracts/evm/echidna.config.yml`:

- **`testMode: property`**: treat `echidna_*` as properties/invariants.
- **`prefix: echidna_`**: the property prefix.
- **`seqLen`**: the maximum length of call sequences Echidna will explore per run.
- **`testLimit`**: how many sequences to try.
- **`maxValue`**: maximum `msg.value` Echidna may use when calling payable actions (used for native wrap flows).

### How we run Echidna here

We run Echidna through `contracts/evm/scripts/echidna.sh`, which:

- prefers a locally installed `echidna`/`echidna-test` binary when available,
- otherwise falls back to Docker (using Trail of Bits' toolbox image),
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
  sh ./scripts/echidna.sh --file test/fuzz/invariants/LCCBacking01.sol --contract LCCBacking01
```

## Checklist

The **source of truth** for protocol invariants is `contracts/evm/INVARIANTS.md`.

This README is a **coverage tracker** for:

- which `INVARIANTS.md` items are covered by Echidna harnesses in this directory, and
- which invariants are still missing (and what the next priorities are).

### Coverage (from `INVARIANTS.md`)

This table is keyed by **canonical** invariant IDs from `INVARIANTS.md`. It is the main "what's done / what's next"
view.

- **Needs property?**: "Yes" means we should prefer a property-based test (Echidna and/or invariant-style Foundry)
  because manual inspection is unreliable.
- **Status**: "Covered" means there is at least one non-trivial check; "Partial" means the invariant is exercised but
  not comprehensively (or only in a narrow harness assumption).

| Invariant (`INVARIANTS.md`) | Priority | Needs property? | Status                | Evidence (Echidna)                                                                                                                             | Notes                                                                                                     |
| --------------------------- | -------- | --------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **LCC-BACKING-01**          | **P1**   | Yes             | **Covered**           | `invariants/LCCBacking01.sol` → `echidna_lcc_backing_01_*` (10 properties)                                                                     | Full domain accounting: supply, reserves, queues, wrapWith conservation, commitment gate.                 |
| **LCC-01**                  | **P2**   | Yes             | **Covered**           | `invariants/LCC01.sol` → `echidna_lcc_01_*` (7 properties)                                                                                     | Transfer gating: user-to-user blocked, endpoint/exempt routes allowed, approved transfers.                |
| **LCC-02**                  | **P1**   | Yes             | **Covered**           | `invariants/LCC02.sol` → `echidna_lcc_02_*` (3 properties)                                                                                     | Queue annul semantics on protocol transfer, bucket-sum invariant.                                         |
| **LCC-03**                  | **P1**   | Yes             | Not started           | —                                                                                                                                              | Nested ingress settlement must preserve outer `sync(lcc) -> transfer -> settle()` window.                 |
| **HUB-01**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB01.sol` → `echidna_hub_01_*` (12 properties)                                                                                    | Native + ERC20 wrap 1:1, supply/reserve model, balance coverage, guard checks.                            |
| **HUB-02**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB02.sol` → `echidna_hub_02_*` (6 properties)                                                                                     | Queue/unwrap decomposition, total-queued model, guard checks.                                             |
| **HUB-03**                  | **P2**   | Yes             | **Covered**           | `invariants/HUB03.sol` → `echidna_hub_03_*` (3 properties)                                                                                     | Issuer gating: invalid LCC reverts, non-issuer reverts, valid issuer succeeds.                            |
| **HUB-04**                  | **P3**   | Yes             | **Covered**           | `invariants/HUB04.sol` → `echidna_hub_04_*` (3 properties)                                                                                     | Same-factory constraint on pair operations, cross-factory and non-LCC rejection.                          |
| **HUB-05**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB05.sol` → `echidna_hub_05_*` (4 properties)                                                                                     | Reserve never exceeds actual balance, confirmTake accounting.                                             |
| **HUB-06**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB06.sol` → `echidna_hub_06_*` (5 properties)                                                                                     | Issue/cancel domain accounting, prepareSettle decrements, guard checks.                                   |
| **SIG-01**                  | **P3**   | Yes             | **Covered**           | `invariants/SIG01_02.sol` → `echidna_sig_01_*` (3 properties)                                                                                  | Nonce monotonicity, valid signal succeeds, stale nonce reverts.                                           |
| **SIG-02**                  | **P3**   | Yes             | **Covered**           | `invariants/SIG01_02.sol` → `echidna_sig_02_*` (2 properties)                                                                                  | Invalid proof reverts / returns false.                                                                    |
| **COMMIT-01**               | **P1**   | Yes             | **Covered**           | `invariants/COMMIT01.sol` → `echidna_commit_01_gate_correct`                                                                                   | Issuance gate: issuedUsd <= settledUsd + signalUsd.                                                       |
| **COMMIT-02**               | **P1**   | Yes             | **Covered**           | `invariants/COMMIT02.sol` → `echidna_commit_02_checkpoint_deficit_math_correct`                                                                 | Checkpoint deficit math correctness.                                                                      |
| **COMMIT-03**               | **P3**   | Yes             | **Covered**           | `invariants/COMMIT03.sol` → `echidna_commit_03_*` (4 properties)                                                                               | Advancer binding: renewal, hijack prevention, rotation.                                                   |
| **COV-01**                  | **P1**   | Yes             | **Covered**           | `invariants/COV01.sol` → `echidna_cov_01_burn_base_bounded`                                                                                    | `_applyBurnBase` maths bounds.                                                                            |
| **COV-02**                  | **P1**   | Yes             | **Covered**           | `invariants/COV02.sol` → `echidna_cov_02_settle_before_modify`                                                                                  | Coverage burns settled before position modifications.                                                     |
| **COV-03**                  | **P1**   | Yes             | **Covered**           | `invariants/COV03.sol` → `echidna_cov_03_conditional_index_increment`                                                                           | Conditional index increments under zero-principal cases.                                                  |
| **COV-04**                  | **P1**   | Yes             | **Covered**           | `invariants/COV04.sol` → `echidna_cov_04_*` (4 properties)                                                                                     | Fee-burn remainder carry: bounded, split-equals-single, accumulated, zero-fees preservation.              |
| **FEE-01**                  | **P1**   | Yes             | **Covered**           | `invariants/FEE01.sol` → `echidna_fee_01_queue_vs_pot`, `echidna_fee_01_materialise_updates_pot_only`                                          | Queue-vs-materialised fee pot accounting.                                                                 |
| **FEE-02**                  | **P1**   | Yes             | **Covered**           | `invariants/FEE02.sol` → `echidna_fee_02_no_bonus_on_creation`                                                                                 | New positions don't receive fee-sharing bonuses on creation.                                               |
| **VTS-02**                  | **P1**   | Yes             | **Covered**           | `invariants/VTS02.sol` → `echidna_vts_02_flip_identity`                                                                                         | Tick-cross "outside flip" preserves inside-growth queryability.                                            |
| **VTS-03**                  | **P1**   | Yes             | **Covered**           | `invariants/VTS03.sol` → `echidna_vts_03_segment_growth_accounting`                                                                             | Swap segment-based deficit/inflow growth accounting.                                                      |
| **DELTA-01**                | **P1**   | Yes             | **Covered**           | `invariants/DELTA01.sol` → `echidna_delta_01_nonzero_deltas_revert`                                                                             | Deltas must net to zero per unlock/batch.                                                                 |
| **SETTLE-01**               | **P1**   | Yes             | **Covered**           | `invariants/SETTLE01.sol` → `echidna_settle_01_withdraw_reverts_when_rfs_open`                                                                  | Withdrawals revert while RFS open (unless seizing).                                                       |
| **MKT-05**                  | **P1**   | Yes             | **Needs fix**         | `invariants/MKT05.sol` → `echidna_mkt05_live_amountToSwap_is_zero`                                                                             | Proxy pool AMM curve must never be utilised. Mock needs update for protocol changes.                      |
| **SETTLE-02**               | **P2**   | Yes             | Not started           | —                                                                                                                                              | Seizure settlement clamps (deposit/withdraw bounds).                                                      |
| **SEIZE-01**                | **P2**   | Yes             | Not started           | —                                                                                                                                              | Seizable predicate: commitment deficit OR (RFS open + grace).                                             |
| **SEIZE-02**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | Allowed verifier requirement for grace extensions.                                                        |
| **SEIZE-03**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | Seizure flows cannot issue LCC.                                                                           |
| **SEIZE-04**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | MM ops must not change commit identity.                                                                   |
| **PAUSE-01**                | **P3**   | Yes             | Not started           | —                                                                                                                                              | Guard application is broad and regression-prone.                                                          |
| **VTS-01**                  | **P3**   | Yes             | Not started           | —                                                                                                                                              | Must always settle growths before liquidity modification.                                                 |
| **AUTH-01**                 | **P3**   | Yes             | Not started           | —                                                                                                                                              | Hard to eyeball all surfaces; especially with seizure context exceptions.                                 |
| **AUTH-02**                 | **P3**   | Yes             | Not started           | —                                                                                                                                              | "No mid-batch transfer" is a global property across unlock sessions.                                      |
| **MKT-06**                  | **P2**   | No              | Not started           | —                                                                                                                                              | Canonical market pair ordering must be core/LCC order.                                                    |
| **MKT-01**                  | P3       | No              | Not started           | —                                                                                                                                              | Mostly an explicit revert surface; lower risk than maths/state-machine items.                             |
| **MKT-02**                  | P3       | No              | Not started           | —                                                                                                                                              | Write-once property; easy to review, still worth testing.                                                 |
| **MKT-03**                  | P3       | No              | Not started           | —                                                                                                                                              | "Core pool cannot be created twice" is largely structural.                                                |
| **MKT-04**                  | P3       | No              | Not started           | —                                                                                                                                              | Factory/issuer boundaries are structural; still good to keep coverage.                                    |
| **MKT-04A**                 | **P3**   | No              | Not started           | —                                                                                                                                              | Bound-role lifecycle: bootstrap-only and immutable roles.                                                 |

## Coverage map (invariant -> harness -> property)

All harnesses live in **`invariants/`**.

| Invariant               | Harness                  | Properties                                                                                              |
| ----------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------- |
| LCC-BACKING-01          | `LCCBacking01.sol`       | `echidna_lcc_backing_01_no_unauthorised_mint`, `echidna_lcc_backing_01_no_unauthorised_burn`, `echidna_lcc_backing_01_total_supply_matches_model`, `echidna_lcc_backing_01_direct_reserve_matches_wrapped`, `echidna_lcc_backing_01_holder_balances_match_model`, `echidna_lcc_backing_01_reserve_tuple_matches_model`, `echidna_lcc_backing_01_settle_queue_matches_model`, `echidna_lcc_backing_01_wrapwith_conserves_backing`, `echidna_lcc_backing_01_commitment_gate_consistent`, `echidna_lcc_backing_01_commitment_gate_boundary` |
| LCC-01                  | `LCC01.sol`              | `echidna_lcc_01_user_to_user_blocked`, `echidna_lcc_01_approved_user_to_user_blocked`, `echidna_lcc_01_user_to_endpoint_allowed`, `echidna_lcc_01_user_to_exempt_allowed`, `echidna_lcc_01_endpoint_to_user_allowed`, `echidna_lcc_01_endpoint_to_endpoint_allowed`, `echidna_lcc_01_approved_user_to_endpoint_allowed` |
| LCC-02                  | `LCC02.sol`              | `echidna_lcc_02_bucket_sum_equals_balance`, `echidna_lcc_02_queue_matches_model`, `echidna_lcc_02_transfer_annuls_queue_correctly` |
| HUB-01                  | `HUB01.sol`              | `echidna_hub_01_direct_supply_native_matches_model`, `echidna_hub_01_direct_supply_erc20_matches_model`, `echidna_hub_01_reserve_native_matches_model`, `echidna_hub_01_reserve_erc20_matches_model`, `echidna_hub_01_total_supply_native_matches_model`, `echidna_hub_01_total_supply_erc20_matches_model`, `echidna_hub_01_hub_eth_balance_covers_native_reserve`, `echidna_hub_01_hub_erc20_balance_covers_erc20_reserve`, `echidna_hub_01_native_wrap_is_one_to_one`, `echidna_hub_01_erc20_wrap_is_one_to_one`, `echidna_hub_01_native_guard_rejects_mismatch`, `echidna_hub_01_erc20_guard_rejects_value` |
| HUB-02                  | `HUB02.sol`              | `echidna_hub_02_holder_queue_matches_model`, `echidna_hub_02_total_queued_matches_model`, `echidna_hub_02_zero_amount_reverts`, `echidna_hub_02_over_balance_reverts`, `echidna_hub_02_unwrap_decomposition_holds`, `echidna_hub_02_balance_decreases_by_paidout` |
| HUB-03                  | `HUB03.sol`              | `echidna_hub_03_invalid_lcc_always_reverts`, `echidna_hub_03_non_issuer_always_reverts`, `echidna_hub_03_valid_issuer_succeeds` |
| HUB-04                  | `HUB04.sol`              | `echidna_hub_04_same_market_resolves`, `echidna_hub_04_cross_factory_reverts`, `echidna_hub_04_non_lcc_reverts` |
| HUB-05                  | `HUB05.sol`              | `echidna_hub_05_erc20_reserve_never_exceeds_balance`, `echidna_hub_05_native_reserve_never_exceeds_balance`, `echidna_hub_05_valid_take_increments_correctly`, `echidna_hub_05_over_balance_take_reverts` |
| HUB-06                  | `HUB06.sol`              | `echidna_hub_06_direct_supply_matches_model`, `echidna_hub_06_reserve_direct_matches_model`, `echidna_hub_06_prepare_settle_decrements_both`, `echidna_hub_06_zero_amount_reverts`, `echidna_hub_06_over_limit_reverts` |
| SIG-01                  | `SIG01_02.sol`           | `echidna_sig_01_nonce_never_decreases`, `echidna_sig_01_valid_signal_succeeds`, `echidna_sig_01_stale_nonce_reverts` |
| SIG-02                  | `SIG01_02.sol`           | `echidna_sig_02_invalid_proof_reverts`, `echidna_sig_02_invalid_proof_returns_false` |
| COMMIT-01               | `COMMIT01.sol`           | `echidna_commit_01_gate_correct` |
| COMMIT-02               | `COMMIT02.sol`           | `echidna_commit_02_checkpoint_deficit_math_correct` |
| COMMIT-03               | `COMMIT03.sol`           | `echidna_commit_03_valid_renewal_succeeds`, `echidna_commit_03_owner_hijack_reverts`, `echidna_commit_03_non_advancer_reverts`, `echidna_commit_03_rotation_respects_new_advancer` |
| COV-01                  | `COV01.sol`              | `echidna_cov_01_burn_base_bounded` |
| COV-02                  | `COV02.sol`              | `echidna_cov_02_settle_before_modify` |
| COV-03                  | `COV03.sol`              | `echidna_cov_03_conditional_index_increment` |
| COV-04                  | `COV04.sol`              | `echidna_cov_04_carry_lt_liquidity`, `echidna_cov_04_split_equals_single`, `echidna_cov_04_accumulated_matches_single`, `echidna_cov_04_zero_fees_preserves_carry` |
| FEE-01                  | `FEE01.sol`              | `echidna_fee_01_queue_vs_pot`, `echidna_fee_01_materialise_updates_pot_only` |
| FEE-02                  | `FEE02.sol`              | `echidna_fee_02_no_bonus_on_creation` |
| VTS-02                  | `VTS02.sol`              | `echidna_vts_02_flip_identity` |
| VTS-03                  | `VTS03.sol`              | `echidna_vts_03_segment_growth_accounting` |
| DELTA-01                | `DELTA01.sol`            | `echidna_delta_01_nonzero_deltas_revert` |
| SETTLE-01               | `SETTLE01.sol`           | `echidna_settle_01_withdraw_reverts_when_rfs_open` |
| MKT-05                  | `MKT05.sol`              | `echidna_mkt05_live_amountToSwap_is_zero` |
