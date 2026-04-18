# Medusa fuzz migration

This directory now treats `test/fuzz/FuzzEntry.sol` as the supported Medusa composition root.

The older per-harness Medusa path based on linked-library CREATE2 preparation is no longer the supported workflow.
Those harnesses remain in-tree only as migration backlog and are tracked explicitly below.

## Supported path

Medusa now runs against a concrete target model:

- `contracts/evm/medusa.json` and `contracts/evm/medusa.deep.json` both target `FuzzEntry`
- `contracts/evm/scripts/medusa.sh` reads the config target directly instead of patching in ad hoc file/contract pairs
- `[profile.medusa]` in `contracts/evm/foundry.toml` is scoped to the `FuzzEntry` smoke target and no longer carries
  the legacy hard-linked library map for the supported workflow

From `contracts/evm/`:

```bash
just fuzz
just fuzz-deep
just fuzz-invariants
just medusa-entry
just medusa-mmq-01

MEDUSA_CORPUS_DIR=artifacts/medusa-local \
  just medusa-entry -- --test-limit 50 --seq-len 5
```

The runner writes coverage-guided artifacts to `<MEDUSA_CORPUS_DIR>/<TargetContract>/...`, so the supported path now
stores artifacts under `FuzzEntry/` instead of per-legacy-harness directories.

## Migration checklist

Completion for this migration is evaluated only by the checklist below.

Status meanings:

- `Migrated`: now composed into `FuzzEntry` and part of the supported Medusa path
- `Deferred`: still legacy-linked or otherwise not yet moved into `FuzzEntry`

| Surface | Status | Current location | Notes |
| ------- | ------ | ---------------- | ----- |
| Fuzz composition root | Migrated | `FuzzEntry.sol` | Supported Medusa target. |
| Shared helper utilities | Migrated | `FuzzHelper.sol` | Shared by composed modules. |
| MMQ-01 queue custody guard | Migrated | `FuzzMMQ01.sol` | Runtime `new` composition; no CREATE2 linker prep. |
| VTS wrapper scaffold | Deferred | `FuzzVTSPosition.sol`, `lib/` | Placeholder only; runtime wrappers still need to be implemented. |
| LCC-BACKING-01 | Deferred | `invariants/LCCBacking01.sol` | Still imports `FuzzLinkedLibs`. |
| LCC-01 | Deferred | `invariants/LCC01.sol` | Still imports `FuzzLinkedLibs`. |
| LCC-02 | Deferred | `invariants/LCC02.sol` | Still imports `FuzzLinkedLibs`. |
| LCC-03 | Deferred | `invariants/LCC03.sol` | Not yet refactored into a FuzzEntry module. |
| HUB-01 | Deferred | `invariants/HUB01.sol` | Still imports `FuzzLinkedLibs`. |
| HUB-02 | Deferred | `invariants/HUB02.sol` | Still imports `FuzzLinkedLibs`. |
| HUB-03 | Deferred | `invariants/HUB03.sol` | Still imports `FuzzLinkedLibs`. |
| HUB-04 | Deferred | `invariants/HUB04.sol` | Still imports `FuzzLinkedLibs`. |
| HUB-05 | Deferred | `invariants/HUB05.sol` | Still imports `FuzzLinkedLibs`. |
| HUB-06 | Deferred | `invariants/HUB06.sol` | Not yet refactored into a FuzzEntry module. |
| SIG-01 / SIG-02 | Deferred | `invariants/SIG01_02.sol` | Not yet refactored into a FuzzEntry module. |
| COMMIT-01 | Deferred | `invariants/COMMIT01.sol` | Still imports `FuzzLinkedLibs`. |
| COMMIT-02 | Deferred | `invariants/COMMIT02.sol` | Still imports `FuzzLinkedLibs`. |
| COMMIT-03 | Deferred | `invariants/COMMIT03.sol` | Still imports `FuzzLinkedLibs`. |
| COV-01 | Deferred | `invariants/COV01.sol` | Not yet refactored into a FuzzEntry module. |
| COV-02 | Deferred | `invariants/COV02.sol` | Hybrid evidence still lives outside FuzzEntry. |
| COV-03 | Deferred | `invariants/COV03.sol` | Still imports `FuzzLinkedLibs`. |
| COV-04 | Deferred | `invariants/COV04.sol` | Hybrid evidence still lives outside FuzzEntry. |
| FEE-01 | Deferred | `invariants/FEE01.sol` | Not yet refactored into a FuzzEntry module. |
| FEE-02 | Deferred | `invariants/FEE02.sol` | Not yet refactored into a FuzzEntry module. |
| VTS-01 | Deferred | `invariants/VTS01.sol` | Depends on deferred VTS wrapper migration. |
| VTS-02 | Deferred | `invariants/VTS02.sol` | Depends on deferred VTS wrapper migration. |
| VTS-03 | Deferred | `invariants/VTS03.sol` | Depends on deferred VTS wrapper migration. |
| DELTA-01 | Deferred | `invariants/DELTA01.sol` | Not yet refactored into a FuzzEntry module. |
| SETTLE-01 | Deferred | `invariants/SETTLE01.sol` | Still imports `FuzzLinkedLibs`. |
| SETTLE-02 | Deferred | `invariants/SETTLE02.sol` | Still imports `FuzzLinkedLibs`. |
| SEIZE-01 / SEIZE-02 | Deferred | `invariants/SEIZE01_02.sol` | Not yet refactored into a FuzzEntry module. |
| SEIZE-03 / SEIZE-04 | Deferred | `invariants/SEIZE03_04.sol` | Still imports `FuzzLinkedLibs`. |
| PAUSE-01 | Deferred | `invariants/PAUSE01.sol` | Not yet refactored into a FuzzEntry module. |
| MKT-01 / MKT-02 | Deferred | `invariants/MKT01_02.sol` | Not yet refactored into a FuzzEntry module. |
| MKT-03 / MKT-06 | Deferred | `invariants/MKT03_06.sol` | Not yet refactored into a FuzzEntry module. |
| MKT-04 / MKT-04A | Deferred | `invariants/MKT04_04A.sol` | Still imports `FuzzLinkedLibs`. |
| MKT-05 | Deferred | `invariants/MKT05.sol` | Foundry regressions remain authoritative; not yet composed into `FuzzEntry`. |
| AUTH-01 / AUTH-01A / AUTH-02 | Deferred | `invariants/AUTH01_01A_02.sol` | Not yet refactored into a FuzzEntry module. |
| Legacy wrap regression | Deferred | `LiquidityHubWrapWithFuzzTest.sol` | Still uses linked-library CREATE2 salts. |
| Legacy queue netting regression | Deferred | `LiquidityHubWrapWithQueueFuzzTest.sol` | Still uses linked-library CREATE2 salts. |
| Legacy confirmTake regression | Deferred | `LiquidityHubConfirmTakeCallbackFuzzTest.sol` | Still uses linked-library CREATE2 salts. |

## Echidna and linked-library remnants

Removed from the supported workflow:

- empty/generic Medusa target selection
- ad hoc `--file` / `--contract` harness selection in the repo-supported runner path
- linked-library prepare assumptions in the supported `just fuzz`, `just fuzz-deep`, and `just medusa-coverage-smoke`
  commands

Still present, but explicitly deferred:

- `test/fuzz/base/FuzzLinkedLibs.sol`
- linked-library CREATE2 salts such as `echidna.*` in legacy harness constructors
- legacy invariant and regression harness files that still rely on deterministic linked-library deployment

Those deferred remnants are intentionally kept out of the default Medusa path until each surface is migrated into a
`FuzzEntry` module.
