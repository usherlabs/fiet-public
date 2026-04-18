# Medusa fuzz harnesses

This folder contains Medusa-backed fuzzing harnesses for protocol invariants.
All invariant harnesses live in **`invariants/`**.

## How Medusa fuzzing works (in this repo)

These files are Solidity property harnesses, not Foundry unit tests. Each harness is a _stateful Solidity contract_
that Medusa deploys once, then interacts with by generating sequences of calls. At a high level:

- Medusa deploys the harness (runs its `constructor()` to set up initial state).
- Medusa generates a sequence of "transactions" (function calls) into the harness to mutate state.
- After and during sequences, Medusa evaluates **properties** (invariants) and fails the run if any property is false.
- When a property fails, Medusa attempts to **shrink** the call sequence to a minimal reproducer.

### Harness structure

In this repository, harnesses follow a consistent pattern:

- **`constructor()`**: deploy real protocol contracts + mocks, configure roles/bounds, seed balances, etc.
- **`action_*` functions**: state-mutating entrypoints for Medusa to call in arbitrary order with arbitrary inputs.
  - Actions often clamp inputs into safe ranges.
  - Actions often use low-level calls / `try/catch` so a revert does not abort the whole fuzz sequence.
- **`fuzz_*` functions**: boolean properties that express invariants, and Medusa treats any
  `fuzz_*() -> bool` as "must always hold".
  - Many properties use a `checked`/`lastOk` pattern so the property only becomes meaningful after a relevant action
    has executed (avoids vacuous failures before an action has run).
  - Some harnesses include a second trivial property (`*_smoke`) to avoid rare instability when only one property exists.

### What Medusa considers a "test"

The default configuration used by this repo is `contracts/evm/medusa.json`:

- **`propertyTesting.enabled: true`**: treat `fuzz_*` as properties/invariants.
- **`propertyTesting.testPrefixes: ["fuzz_"]`**: preserve the existing property prefix.
- **`callSequenceLength`**: the maximum length of call sequences Medusa will explore per run.
- **`testLimit`**: how many transactions Medusa will execute before halting a campaign.
- **`deployerAddress: 0x30000`**: fixed deployer used for deterministic harness/library deployment.

### How we run Medusa here

We run Medusa through `contracts/evm/scripts/medusa.sh`, which:

- expects a locally installed `medusa` binary,
- targets one harness source file at a time so `crytic-compile` exposes the relevant contract artifacts,
- uses `crytic-compile` with the Foundry backend and the dedicated Medusa output directory,
- resolves `MEDUSA_CORPUS_DIR` to an absolute workspace path so coverage-guided corpus artifacts stay under the repo
  instead of landing next to the runner's temporary config in `/tmp`.

We also use a dedicated Foundry profile (`[profile.medusa]` in `contracts/evm/foundry.toml`) to:

- compile only the harnesses under `test/fuzz` (faster, avoids OOM),
- build into a separate output directory (`out-medusa/`),
- hard-link selected libraries for determinism (some harnesses deploy those libraries via `CREATE2` to the linked
  addresses during `constructor()`).

### Linked-library wiring

Harness constructors call helpers in `test/fuzz/base/FuzzLinkedLibs.sol` to deploy selected libraries at
**deterministic CREATE2** addresses (fixed deployer + per-library salts). Foundry must **link** the same addresses
into bytecode that delegates to those libraries, otherwise HEVM rejects unlinked placeholders.

The only repo-level touchpoints for that wiring are:

- `foundry.toml` → `[profile.medusa].libraries`
- `test/fuzz/base/FuzzLinkedLibs.sol` → `address internal constant ...` values

If a harness constructor starts reverting with a linked-library address mismatch, update those two locations together.

## Migration checklist

- Canonical invariant harnesses under `test/fuzz/invariants/*`: migrated to Medusa and exposed through `fuzz_*`
  properties.
- Targeted regression harnesses:
  `LiquidityHubWrapWithFuzzTest.sol`, `LiquidityHubWrapWithQueueFuzzTest.sol`,
  `LiquidityHubConfirmTakeCallbackFuzzTest.sol`, and `invariants/MKT05.sol`.
- Legacy configs, runner scripts, and validation/smoke helpers: removed from the supported workflow.

## Run

From `contracts/evm/`:

```bash
# Run all fuzz harnesses
just fuzz
just fuzz-deep
just fuzz-invariants
just medusa-coverage-smoke

# Run individual harnesses
just medusa-lcc-backing
just medusa-commit-01
```

## Coverage-guided artifacts

Medusa is configured with `coverageEnabled: true`, so coverage still guides the campaign even though the repo’s human-
readable line/branch/function percentages come from `forge coverage` in `.github/workflows/ci.yml`.

When you want to keep Medusa’s coverage-guided artifacts, set `MEDUSA_CORPUS_DIR` or use the smoke target:

```bash
cd contracts/evm

# Persist one harness locally
MEDUSA_CORPUS_DIR=artifacts/medusa-local \
  just medusa test/fuzz/invariants/LCC01.sol LCC01 medusa.json -- --test-limit 50 --seq-len 5

# Persist a short representative smoke bundle
just medusa-coverage-smoke
```

The runner writes each harness to a contract-scoped directory:

- `<dir>/<ContractName>/.medusa-artifact-hash`
- `<dir>/<ContractName>/call_sequences/*.json`
- `<dir>/<ContractName>/test_results/`

CI sets `MEDUSA_CORPUS_DIR=artifacts/medusa-ci` and uploads that directory as a workflow artifact so the Medusa path
keeps a reviewable artifact trail alongside the Forge coverage PR comment.

### Troubleshooting

- If you see `error: missing --file or --contract`, it means `scripts/medusa.sh` was invoked without required args.
  As a workaround (and for debugging), you can call the runner directly:

```bash
cd contracts/evm
FOUNDRY_PROFILE=medusa FOUNDRY_OUT_DIR=out-medusa \
  sh ./scripts/medusa.sh --file test/fuzz/invariants/LCCBacking01.sol --contract LCCBacking01
```

- If you want Medusa artifacts to stay under the repo, prefer `MEDUSA_CORPUS_DIR=artifacts/...` rather than a
  relative `--corpus-dir` passed directly to the CLI. The wrapper normalises the path before it hands Medusa a
  temporary config.

## Checklist

The **source of truth** for protocol invariants is `contracts/evm/INVARIANTS.md`.

This README is a coverage tracker for:

- which `INVARIANTS.md` items are covered by the Medusa-run harnesses in this directory, and
- which invariants are still missing (and what the next priorities are).

### Coverage (from `INVARIANTS.md`)

This table is keyed by **canonical** invariant IDs from `INVARIANTS.md`. It is the main "what's done / what's next"
view.

- **Needs property?**: "Yes" means we should prefer a property-based test (Medusa and/or invariant-style Foundry)
  because manual inspection is unreliable.
- **Status**: "Covered" means there is at least one non-trivial check; "Partial" means the invariant is exercised but
  not comprehensively (or only in a narrow harness assumption).

| Invariant (`INVARIANTS.md`) | Priority | Needs property? | Status                | Evidence (Medusa/Foundry)                                                                                                                      | Notes                                                                                                     |
| --------------------------- | -------- | --------------- | --------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| **LCC-BACKING-01**          | **P1**   | Yes             | **Covered**           | `invariants/LCCBacking01.sol` → `fuzz_lcc_backing_01_*` (10 properties)                                                                     | Full domain accounting: supply, reserves, queues, wrapWith conservation, commitment gate.                 |
| **LCC-01**                  | **P2**   | Yes             | **Covered**           | `invariants/LCC01.sol` → `fuzz_lcc_01_*` (7 properties)                                                                                     | Transfer gating: user-to-user blocked, endpoint/exempt routes allowed, approved transfers.                |
| **LCC-02**                  | **P1**   | Yes             | **Covered**           | `invariants/LCC02.sol` → `fuzz_lcc_02_*` (3 properties)                                                                                     | Queue annul semantics on protocol transfer, bucket-sum invariant.                                         |
| **LCC-03**                  | **P1**   | Yes             | **Covered**           | `invariants/LCC03.sol` → `fuzz_lcc_03_sync_windows_hold`, `fuzz_lcc_03_revert_guards_hold` + `test/MarketFactory.t.sol::{testFuzz_prepareMarketLiquidity_revertsWhenDifferentCurrencyInFlight,test_prepareMarketLiquidity_sameLccSync_restoresAfterNestedErc20Sync,test_prepareMarketLiquidity_sameLccSync_nativeUnderlying_clearsAndRestores}` | Medusa ingress-window checks now track sync and revert surfaces independently, plus direct MarketFactory nested-sync/restore path evidence. |
| **HUB-01**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB01.sol` → `fuzz_hub_01_*` (12 properties)                                                                                    | Native + ERC20 wrap 1:1, supply/reserve model, balance coverage, guard checks.                            |
| **HUB-02**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB02.sol` → `fuzz_hub_02_*` (6 properties)                                                                                     | Queue/unwrap decomposition, total-queued model, guard checks.                                             |
| **HUB-03**                  | **P2**   | Yes             | **Covered**           | `invariants/HUB03.sol` → `fuzz_hub_03_*` (3 properties)                                                                                     | Issuer gating: invalid LCC reverts, non-issuer reverts, valid issuer succeeds.                            |
| **HUB-04**                  | **P3**   | Yes             | **Covered**           | `invariants/HUB04.sol` → `fuzz_hub_04_*` (3 properties)                                                                                     | Same-factory constraint on pair operations, cross-factory and non-LCC rejection.                          |
| **HUB-05**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB05.sol` → `fuzz_hub_05_*` (4 properties)                                                                                     | Reserve never exceeds actual balance, confirmTake accounting.                                             |
| **HUB-06**                  | **P1**   | Yes             | **Covered**           | `invariants/HUB06.sol` → `fuzz_hub_06_*` (5 properties)                                                                                     | Issue/cancel domain accounting, prepareSettle decrements, guard checks.                                   |
| **SIG-01**                  | **P3**   | Yes             | **Covered**           | `invariants/SIG01_02.sol` → `fuzz_sig_01_*` (3 properties)                                                                                  | Nonce monotonicity, valid signal succeeds, stale nonce reverts.                                           |
| **SIG-02**                  | **P3**   | Yes             | **Covered**           | `invariants/SIG01_02.sol` → `fuzz_sig_02_*` (2 properties)                                                                                  | Invalid proof reverts / returns false.                                                                    |
| **COMMIT-01**               | **P1**   | Yes             | **Covered**           | `invariants/COMMIT01.sol` → `fuzz_commit_01_gate_correct`                                                                                   | Issuance gate: issuedUsd <= settledUsd + signalUsd.                                                       |
| **COMMIT-02**               | **P1**   | Yes             | **Covered**           | `invariants/COMMIT02.sol` → `fuzz_commit_02_checkpoint_deficit_math_correct`                                                                 | Checkpoint deficit math correctness; the harness clamps liquidity into the checkpoint path's supported `int128` domain to avoid vacuous failures from unreachable states. |
| **COMMIT-03**               | **P3**   | Yes             | **Covered**           | `invariants/COMMIT03.sol` → `fuzz_commit_03_*` (4 properties)                                                                               | Advancer binding: renewal, hijack prevention, rotation.                                                   |
| **COV-01**                  | **P1**   | Yes             | **Covered**           | `invariants/COV01.sol` → `fuzz_cov_01_burn_base_bounded`                                                                                    | `_applyBurnBase` maths bounds.                                                                            |
| **COV-02**                  | **P1**   | Yes             | **Covered** (Hybrid)  | `invariants/COV02.sol` + `test/VTSOrchestratorInvariantRegressions.t.sol::test_vts01_cov02_directDecrease_matchesPokeThenDecrease_afterGrowthAccrual` | Medusa fixture plus real MM/orchestrator-path settle-before-modify equivalence check. |
| **COV-03**                  | **P1**   | Yes             | **Covered**           | `invariants/COV03.sol` → `fuzz_cov_03_conditional_index_increment`                                                                           | Conditional index increments under zero-principal cases.                                                  |
| **COV-04**                  | **P1**   | Yes             | **Covered** (Hybrid)  | `invariants/COV04.sol` + `test/VTSOrchestratorInvariantRegressions.t.sol::test_cov04_splitDecrease_monotonicFeeShareBurn_andIndexProgress`     | Utility-level remainder maths plus orchestrator-path CSI burn/index monotonicity under split decreases. |
| **FEE-01**                  | **P1**   | Yes             | **Covered**           | `invariants/FEE01.sol` → `fuzz_fee_01_queue_vs_pot`, `fuzz_fee_01_materialise_updates_pot_only`                                          | Queue-vs-materialised fee pot accounting; each action resets CSI epoch/factor baseline (single Medusa instance).                                                                 |
| **FEE-02**                  | **P1**   | Yes             | **Covered**           | `invariants/FEE02.sol` → `fuzz_fee_02_no_bonus_on_creation`                                                                                 | New positions don't receive fee-sharing bonuses on creation.                                               |
| **VTS-02**                  | **P1**   | Yes             | **Covered**           | `invariants/VTS02.sol` → `fuzz_vts_02_flip_identity`                                                                                         | Tick-cross "outside flip" preserves inside-growth queryability.                                            |
| **VTS-03**                  | **P1**   | Yes             | **Covered** (Hybrid)  | `invariants/VTS03.sol` → `fuzz_vts_03_segment_growth_accounting`, `fuzz_vts_03_aux_flip_identity` + `test/VTSOrchestratorInvariantRegressions.t.sol::{test_vts03_swapThenSettle_mutatesPositionAccounting_zeroForOne,test_vts03_swapThenSettle_mutatesPositionAccounting_oneForZero}` | VTSSwapLib internals plus orchestrator-path swap settlement accounting mutation checks; segment and flip vacuity are tracked independently. |
| **DELTA-01**                | **P1**   | Yes             | **Covered**           | `invariants/DELTA01.sol` → `fuzz_delta_01_nonzero_deltas_revert`                                                                             | Deltas must net to zero per unlock/batch.                                                                 |
| **DELTA-02**                | **P2**   | No              | **Covered** (Foundry) | `test/DeltaDesignStatements.t.sol` → `test_delta02_router_residue_is_fcfs_dust`                                                                 | Real `MMPositionManager` `SYNC`/`TAKE` path proves router residue is FCFS dust for the next caller.      |
| **DELTA-03**                | **P2**   | No              | **Covered** (Foundry) | `test/DeltaDesignStatements.t.sol` → `test_delta03_planned_cancel_is_path_scoped_and_immediately_consumed`                                     | Real MM decrease flow exercises `planCancelWithQueue` adjacency and immediate transfer-path consumption.  |
| **SETTLE-01**               | **P1**   | Yes             | **Covered**           | `invariants/SETTLE01.sol` → `fuzz_settle_01_withdraw_reverts_when_rfs_open`, `fuzz_settle_01_aux_withdraw_succeeds_when_rfs_closed`     | Real `onMMSettle -> _settleActive` path; open-RFS withdrawals revert with the production gate reason, and closed-RFS withdrawals are tracked independently to avoid cross-branch vacuity. |
| **MKT-05**                  | **P1**   | Yes             | **Covered** (Hybrid)  | `invariants/MKT05.sol` + `test/ProxyHook.t.sol::{testFuzz_swap_exactOutput_*_revertsWhenRequestedExceedsImmediateLiquidity,test_proxySwap_exactInput_keepsProxySlot0Unchanged,test_proxySwap_exactOutput_keepsProxySlot0Unchanged,test_proxySwap_exactInput_oneForZero_keepsProxySlot0Unchanged,test_proxySwap_exactOutput_oneForZero_keepsProxySlot0Unchanged}` | Foundry regressions remain authoritative for strict exact-output hardening and proxy-curve neutralisation; the fuzz harness is retained as a lightweight cancellation/drift check. |
| **SETTLE-02**               | **P2**   | Yes             | **Covered**           | `invariants/SETTLE02.sol` → `fuzz_settle_02_seizing_clamps_hold`, `fuzz_settle_02_smoke`                                                 | Real `onMMSettle -> _settleSeizing` path; fuzzes positive-cap and zero-cap seizure branches, asserting returned clamp deltas and withdrawal settlement effects. |
| **SEIZE-01**                | **P2**   | Yes             | **Covered**           | `invariants/SEIZE01_02.sol` → `fuzz_seize_01_token_lane_scoped_and_aggregated`                                                              | Includes bypass bps, token-age gates, threshold lanes, and mixed-lane grace masking checks; vacuity is tracked independently from `SEIZE-02` actions. |
| **SEIZE-02**                | **P3**   | Yes             | **Covered**           | `invariants/SEIZE01_02.sol` → `fuzz_seize_02_valid_verifier_required`                                                                        | Verifier-active + token-allowlist enforcement, invalid token index, and closed-lane extension reverts; vacuity is tracked independently from `SEIZE-01` actions. |
| **SEIZE-03**                | **P3**   | Yes             | **Covered**           | `invariants/SEIZE03_04.sol` → `fuzz_seize_03_no_lcc_issue_during_seizure`                                                                    | Uses `VTSPositionLib.touchPosition` path; MM seizing increase/new-position attempts revert as required.   |
| **SEIZE-04**                | **P3**   | Yes             | **Covered**           | `invariants/SEIZE03_04.sol` → `fuzz_seize_04_commit_identity_fixed`                                                                          | Uses `VTSPositionLib.touchPosition` path; mismatched commit IDs revert before MM processing.             |
| **PAUSE-01**                | **P3**   | Yes             | **Covered** (Hybrid)  | `invariants/PAUSE01.sol` → `fuzz_pause_01_proc_swap_guards_hold`, `fuzz_pause_01_active_settle_guard_holds`, `fuzz_pause_01_inactive_settle_guard_holds` + `test/VTSOrchestratorInvariantRegressions.t.sol::test_pause01_mmModify_revertsWhenPaused_andSucceedsAfterUnpause` | Guard-level harness now cycles deterministically through unpaused, pool-paused, and global-paused states for each semantic surface, plus direct MM/orchestrator enforcement and unpause recovery path. |
| **VTS-01**                  | **P3**   | Yes             | **Covered** (Hybrid)  | `invariants/VTS01.sol` + `test/VTSOrchestratorInvariantRegressions.t.sol::test_vts01_cov02_directDecrease_matchesPokeThenDecrease_afterGrowthAccrual` | Shared settle-before-modify property now backed by dedicated orchestrator regression evidence. |
| **AUTH-01**                 | **P3**   | Yes             | **Covered** (Foundry) | `test/AuthSeizeInvariants.t.sol` → `testFuzz_auth01_nonApprovedCannotSettleWhenNotSeizing`                                                     | Real `_settle` path rejects non-owner/non-approved callers when not seizing.                             |
| **AUTH-01A**                | **P3**   | Yes             | **Covered** (Foundry) | `test/AuthSeizeInvariants.t.sol` → `test_auth01a_seizeContext_samePositionOnlyInBatch`, `test_auth01a_seizeContext_clearedAtBatchEnd`         | Real seize path enforces same-position scope and confirms transient seizure context is cleared after batch end. |
| **AUTH-02**                 | **P3**   | Yes             | **Covered** (Foundry) | `test/AuthSeizeInvariants.t.sol` → `test_auth02_transferFromBlockedWhenPoolManagerUnlocked`                                                    | Real `MMPositionManager.transferFrom` path enforces `onlyIfPoolManagerLocked`.                           |
| **MKT-06**                  | **P2**   | No              | **Covered**           | `invariants/MKT03_06.sol` + `test/MarketFactory.t.sol::testFuzz_createMarket_corePairOrderingMatchesStored`                                    | Canonical pair ordering validated in Medusa model plus MarketFactory stored-pair fuzz checks.            |
| **MKT-01**                  | P3       | No              | **Covered**           | `invariants/MKT01_02.sol` → `fuzz_mkt_01_proxy_rejects_add_liquidity`                                                                        | `ProxyHook._beforeAddLiquidity` rejects with `AddLiquidityThroughHookNotAllowed` selector.               |
| **MKT-02**                  | P3       | No              | **Covered**           | `invariants/MKT01_02.sol` → `fuzz_mkt_02_core_pool_key_write_once`                                                                           | `setCorePoolKey` is write-once even when a different second key is attempted.                            |
| **MKT-03**                  | P3       | No              | **Covered**           | `invariants/MKT03_06.sol` → `fuzz_mkt_03_core_pool_unique` + `test/MarketFactory.t.sol::testFuzz_createMarket_revertsWhenCorePoolAlreadyExists` | Medusa model plus MarketFactory duplicate-core reversion fuzz check.                                  |
| **MKT-04**                  | P3       | No              | **Covered**           | `invariants/MKT04_04A.sol` → `fuzz_mkt_04_factory_and_issuer_gating`                                                                         | Factory/issuer matrix extended to issue, cancel, cancelWithQueue, prepareSettle, and confirmTake guards. |
| **MKT-04A**                 | **P3**   | No              | **Covered**           | `invariants/MKT04_04A.sol` → `fuzz_mkt_04a_bound_lifecycle`                                                                                  | Bound-role lifecycle enforces immutable EXEMPT/DEX transitions.                                           |

## Coverage map (invariant -> harness -> property)

All harnesses live in **`invariants/`**.

| Invariant               | Harness                  | Properties                                                                                              |
| ----------------------- | ------------------------ | ------------------------------------------------------------------------------------------------------- |
| LCC-BACKING-01          | `LCCBacking01.sol`       | `fuzz_lcc_backing_01_no_unauthorised_mint`, `fuzz_lcc_backing_01_no_unauthorised_burn`, `fuzz_lcc_backing_01_total_supply_matches_model`, `fuzz_lcc_backing_01_direct_reserve_matches_wrapped`, `fuzz_lcc_backing_01_holder_balances_match_model`, `fuzz_lcc_backing_01_reserve_tuple_matches_model`, `fuzz_lcc_backing_01_settle_queue_matches_model`, `fuzz_lcc_backing_01_wrapwith_conserves_backing`, `fuzz_lcc_backing_01_commitment_gate_consistent`, `fuzz_lcc_backing_01_commitment_gate_boundary` |
| LCC-01                  | `LCC01.sol`              | `fuzz_lcc_01_user_to_user_blocked`, `fuzz_lcc_01_approved_user_to_user_blocked`, `fuzz_lcc_01_user_to_endpoint_allowed`, `fuzz_lcc_01_user_to_exempt_allowed`, `fuzz_lcc_01_endpoint_to_user_allowed`, `fuzz_lcc_01_endpoint_to_endpoint_allowed`, `fuzz_lcc_01_approved_user_to_endpoint_allowed` |
| LCC-02                  | `LCC02.sol`              | `fuzz_lcc_02_bucket_sum_equals_balance`, `fuzz_lcc_02_queue_matches_model`, `fuzz_lcc_02_transfer_annuls_queue_correctly` |
| HUB-01                  | `HUB01.sol`              | `fuzz_hub_01_direct_supply_native_matches_model`, `fuzz_hub_01_direct_supply_erc20_matches_model`, `fuzz_hub_01_reserve_native_matches_model`, `fuzz_hub_01_reserve_erc20_matches_model`, `fuzz_hub_01_total_supply_native_matches_model`, `fuzz_hub_01_total_supply_erc20_matches_model`, `fuzz_hub_01_hub_eth_balance_covers_native_reserve`, `fuzz_hub_01_hub_erc20_balance_covers_erc20_reserve`, `fuzz_hub_01_native_wrap_is_one_to_one`, `fuzz_hub_01_erc20_wrap_is_one_to_one`, `fuzz_hub_01_native_guard_rejects_mismatch`, `fuzz_hub_01_erc20_guard_rejects_value` |
| HUB-02                  | `HUB02.sol`              | `fuzz_hub_02_holder_queue_matches_model`, `fuzz_hub_02_total_queued_matches_model`, `fuzz_hub_02_zero_amount_reverts`, `fuzz_hub_02_over_balance_reverts`, `fuzz_hub_02_unwrap_decomposition_holds`, `fuzz_hub_02_balance_decreases_by_paidout` |
| HUB-03                  | `HUB03.sol`              | `fuzz_hub_03_invalid_lcc_always_reverts`, `fuzz_hub_03_non_issuer_always_reverts`, `fuzz_hub_03_valid_issuer_succeeds` |
| HUB-04                  | `HUB04.sol`              | `fuzz_hub_04_same_market_resolves`, `fuzz_hub_04_cross_factory_reverts`, `fuzz_hub_04_non_lcc_reverts` |
| HUB-05                  | `HUB05.sol`              | `fuzz_hub_05_erc20_reserve_never_exceeds_balance`, `fuzz_hub_05_native_reserve_never_exceeds_balance`, `fuzz_hub_05_valid_take_increments_correctly`, `fuzz_hub_05_over_balance_take_reverts` |
| HUB-06                  | `HUB06.sol`              | `fuzz_hub_06_direct_supply_matches_model`, `fuzz_hub_06_reserve_direct_matches_model`, `fuzz_hub_06_prepare_settle_decrements_both`, `fuzz_hub_06_zero_amount_reverts`, `fuzz_hub_06_over_limit_reverts` |
| SIG-01                  | `SIG01_02.sol`           | `fuzz_sig_01_nonce_never_decreases`, `fuzz_sig_01_valid_signal_succeeds`, `fuzz_sig_01_stale_nonce_reverts` |
| SIG-02                  | `SIG01_02.sol`           | `fuzz_sig_02_invalid_proof_reverts`, `fuzz_sig_02_invalid_proof_returns_false` |
| COMMIT-01               | `COMMIT01.sol`           | `fuzz_commit_01_gate_correct` |
| COMMIT-02               | `COMMIT02.sol`           | `fuzz_commit_02_checkpoint_deficit_math_correct` |
| COMMIT-03               | `COMMIT03.sol`           | `fuzz_commit_03_valid_renewal_succeeds`, `fuzz_commit_03_owner_hijack_reverts`, `fuzz_commit_03_non_advancer_reverts`, `fuzz_commit_03_rotation_respects_new_advancer` |
| COV-01                  | `COV01.sol`              | `fuzz_cov_01_burn_base_bounded` |
| COV-02                  | `COV02.sol`              | `fuzz_cov_02_settle_before_modify` |
| COV-03                  | `COV03.sol`              | `fuzz_cov_03_conditional_index_increment` |
| COV-04                  | `COV04.sol`              | `fuzz_cov_04_carry_lt_liquidity`, `fuzz_cov_04_split_equals_single`, `fuzz_cov_04_accumulated_matches_single`, `fuzz_cov_04_zero_fees_preserves_carry` |
| FEE-01                  | `FEE01.sol`              | `fuzz_fee_01_queue_vs_pot`, `fuzz_fee_01_materialise_updates_pot_only` |
| FEE-02                  | `FEE02.sol`              | `fuzz_fee_02_no_bonus_on_creation` |
| VTS-02                  | `VTS02.sol`              | `fuzz_vts_02_flip_identity` |
| VTS-03                  | `VTS03.sol`              | `fuzz_vts_03_segment_growth_accounting`, `fuzz_vts_03_aux_flip_identity` |
| DELTA-01                | `DELTA01.sol`            | `fuzz_delta_01_nonzero_deltas_revert` |
| DELTA-02                | `../DeltaDesignStatements.t.sol` | `test_delta02_router_residue_is_fcfs_dust` |
| DELTA-03                | `../DeltaDesignStatements.t.sol` | `test_delta03_planned_cancel_is_path_scoped_and_immediately_consumed` |
| SETTLE-01               | `SETTLE01.sol`           | `fuzz_settle_01_withdraw_reverts_when_rfs_open`, `fuzz_settle_01_aux_withdraw_succeeds_when_rfs_closed` |
| SETTLE-02               | `SETTLE02.sol`           | `fuzz_settle_02_seizing_clamps_hold`, `fuzz_settle_02_smoke` |
| LCC-03                  | `LCC03.sol`              | `fuzz_lcc_03_sync_windows_hold`, `fuzz_lcc_03_revert_guards_hold` |
| VTS-01                  | `VTS01.sol`              | `fuzz_vts_01_settle_growths_before_modify` |
| SEIZE-01                | `SEIZE01_02.sol`         | `fuzz_seize_01_token_lane_scoped_and_aggregated` |
| SEIZE-02                | `SEIZE01_02.sol`         | `fuzz_seize_02_valid_verifier_required` |
| SEIZE-03                | `SEIZE03_04.sol`         | `fuzz_seize_03_no_lcc_issue_during_seizure` |
| SEIZE-04                | `SEIZE03_04.sol`         | `fuzz_seize_04_commit_identity_fixed` |
| AUTH-01                 | `../AuthSeizeInvariants.t.sol` | `testFuzz_auth01_nonApprovedCannotSettleWhenNotSeizing` |
| AUTH-01A                | `../AuthSeizeInvariants.t.sol` | `test_auth01a_seizeContext_samePositionOnlyInBatch`, `test_auth01a_seizeContext_clearedAtBatchEnd` |
| AUTH-02                 | `../AuthSeizeInvariants.t.sol` | `test_auth02_transferFromBlockedWhenPoolManagerUnlocked` |
| PAUSE-01                | `PAUSE01.sol`            | `fuzz_pause_01_proc_swap_guards_hold`, `fuzz_pause_01_active_settle_guard_holds`, `fuzz_pause_01_inactive_settle_guard_holds` |
| MKT-01                  | `MKT01_02.sol`           | `fuzz_mkt_01_proxy_rejects_add_liquidity` |
| MKT-02                  | `MKT01_02.sol`           | `fuzz_mkt_02_core_pool_key_write_once` |
| MKT-03                  | `MKT03_06.sol`           | `fuzz_mkt_03_core_pool_unique` |
| MKT-06                  | `MKT03_06.sol`           | `fuzz_mkt_06_core_order_canonical` |
| MKT-04                  | `MKT04_04A.sol`          | `fuzz_mkt_04_factory_and_issuer_gating` |
| MKT-04A                 | `MKT04_04A.sol`          | `fuzz_mkt_04a_bound_lifecycle` |
| MKT-05                  | `../ProxyHook.t.sol`     | `testFuzz_swap_exactOutput_*_revertsWhenRequestedExceedsImmediateLiquidity`, `test_proxySwap_exactInput_keepsProxySlot0Unchanged`, `test_proxySwap_exactOutput_keepsProxySlot0Unchanged`, `test_proxySwap_exactInput_oneForZero_keepsProxySlot0Unchanged`, `test_proxySwap_exactOutput_oneForZero_keepsProxySlot0Unchanged` |
