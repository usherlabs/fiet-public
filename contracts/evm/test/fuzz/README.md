# Medusa fuzz migration

`test/fuzz/FuzzEntry.sol` is the repo-owned Medusa composition root. The supported workflow now runs Medusa against
that concrete target model rather than against per-harness CREATE2-prepared linked-library deployments.

## Supported path

Medusa now runs through a composed runtime tree:

- `contracts/evm/medusa.json` and `contracts/evm/medusa.deep.json` target `FuzzEntry`
- `contracts/evm/scripts/medusa.sh` reads the target contract from config instead of patching in ad hoc harness pairs
- `[profile.medusa]` in `contracts/evm/foundry.toml` is scoped to the supported `FuzzEntry` path
- `FuzzEntry` composes `FuzzMMQ01`, `FuzzHubLCC`, `FuzzMMSettle`, and `FuzzVTSPosition`

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

The runner writes coverage-guided artifacts to `<MEDUSA_CORPUS_DIR>/<TargetContract>/...`, so the supported path stores
artifacts under `FuzzEntry/`.

## Migration checklist

Completion for this migration is evaluated only by the checklist below.

Status meanings:

- `Migrated`: composed into `FuzzEntry` and part of the supported Medusa path
- `Blocked`: not yet composed because there is still a concrete technical dependency to remove

| Surface | Status | Current location | Notes |
| ------- | ------ | ---------------- | ----- |
| Fuzz composition root | Migrated | `FuzzEntry.sol` | Supported Medusa target. |
| Shared helper utilities | Migrated | `FuzzHelper.sol` | Shared by composed modules. |
| MMQ-01 queue custody guard | Migrated | `FuzzMMQ01.sol` | Runtime `new` composition; no CREATE2 linker prep. |
| Hub / LCC composed module | Migrated | `FuzzHubLCC.sol` | `FuzzEntry` now composes the Hub, LCC, wrap, and confirmTake regression harnesses directly. |
| Hub fuzz adapter | Migrated | `harnesses/FuzzLiquidityHub.sol` | Fuzz-only adapter inlines the former linked-library call surfaces so Hub/LCC harnesses no longer need deterministic library deployment. |
| HUB-01 | Migrated | `FuzzHubLCC.sol`, `invariants/HUB01.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| HUB-02 | Migrated | `FuzzHubLCC.sol`, `invariants/HUB02.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| HUB-03 | Migrated | `FuzzHubLCC.sol`, `invariants/HUB03.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| HUB-04 | Migrated | `FuzzHubLCC.sol`, `invariants/HUB04.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| HUB-05 | Migrated | `FuzzHubLCC.sol`, `invariants/HUB05.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| HUB-06 | Migrated | `FuzzHubLCC.sol`, `invariants/HUB06.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| LCC-BACKING-01 | Migrated | `FuzzHubLCC.sol`, `invariants/LCCBacking01.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| LCC-01 | Migrated | `FuzzHubLCC.sol`, `invariants/LCC01.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| LCC-02 | Migrated | `FuzzHubLCC.sol`, `invariants/LCC02.sol` | Runs through `FuzzLiquidityHub`; no CREATE2 prep remains. |
| LCC-03 | Migrated | `FuzzHubLCC.sol`, `invariants/LCC03.sol` | Composed into `FuzzEntry` alongside the other LCC surfaces. |
| MKT-04 / MKT-04A | Migrated | `FuzzHubLCC.sol`, `invariants/MKT04_04A.sol` | Shares the same inlined Hub adapter path as the Hub invariants. |
| Wrap regression | Migrated | `FuzzHubLCC.sol`, `LiquidityHubWrapWithFuzzTest.sol` | Composed into `FuzzEntry`; no linked-library salts remain. |
| Queue netting regression | Migrated | `FuzzHubLCC.sol`, `LiquidityHubWrapWithQueueFuzzTest.sol` | Composed into `FuzzEntry`; no linked-library salts remain. |
| confirmTake regression | Migrated | `FuzzHubLCC.sol`, `LiquidityHubConfirmTakeCallbackFuzzTest.sol` | Composed into `FuzzEntry`; no linked-library salts remain. |
| MM-settle composed module | Migrated | `FuzzMMSettle.sol` | `FuzzEntry` now composes the repo-owned settle harnesses directly. |
| SETTLE-01 | Migrated | `FuzzMMSettle.sol`, `invariants/SETTLE01.sol` | Old helper deployment removed; harness now runs directly under the composed Medusa path. |
| SETTLE-02 | Migrated | `FuzzMMSettle.sol`, `invariants/SETTLE02.sol` | Old helper deployment removed; harness now runs directly under the composed Medusa path. |
| VTS composed module | Migrated | `FuzzVTSPosition.sol` | `FuzzEntry` composes the repo-owned COMMIT / COV / SEIZE child harnesses directly. |
| COMMIT-01 | Migrated | `FuzzVTSPosition.sol`, `invariants/COMMIT01.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COMMIT-02 | Migrated | `FuzzVTSPosition.sol`, `invariants/COMMIT02.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COMMIT-03 | Migrated | `FuzzVTSPosition.sol`, `invariants/COMMIT03.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COV-03 | Migrated | `FuzzVTSPosition.sol`, `invariants/COV03.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| SEIZE-03 / SEIZE-04 | Migrated | `FuzzVTSPosition.sol`, `invariants/SEIZE03_04.sol` | Composed into `FuzzEntry`; the harness now uses only the inlined touch-position path. |
| SIG-01 / SIG-02 | Blocked | `invariants/SIG01_02.sol` | Not yet refactored into a `FuzzEntry` module. |
| COV-01 | Blocked | `invariants/COV01.sol` | Not yet refactored into a `FuzzEntry` module. |
| COV-02 | Blocked | `invariants/COV02.sol` | Hybrid evidence still lives outside `FuzzEntry`. |
| COV-04 | Blocked | `invariants/COV04.sol` | Hybrid evidence still lives outside `FuzzEntry`. |
| FEE-01 | Blocked | `invariants/FEE01.sol` | Not yet refactored into a `FuzzEntry` module. |
| FEE-02 | Blocked | `invariants/FEE02.sol` | Not yet refactored into a `FuzzEntry` module. |
| VTS-01 | Blocked | `invariants/VTS01.sol` | Depends on the remaining VTS wrapper migration. |
| VTS-02 | Blocked | `invariants/VTS02.sol` | Depends on the remaining VTS wrapper migration. |
| VTS-03 | Blocked | `invariants/VTS03.sol` | Depends on the remaining VTS wrapper migration. |
| DELTA-01 | Blocked | `invariants/DELTA01.sol` | Not yet refactored into a `FuzzEntry` module. |
| SEIZE-01 / SEIZE-02 | Blocked | `invariants/SEIZE01_02.sol` | Not yet refactored into a `FuzzEntry` module. |
| PAUSE-01 | Blocked | `invariants/PAUSE01.sol` | Not yet refactored into a `FuzzEntry` module. |
| MKT-01 / MKT-02 | Blocked | `invariants/MKT01_02.sol` | Not yet refactored into a `FuzzEntry` module. |
| MKT-03 / MKT-06 | Blocked | `invariants/MKT03_06.sol` | Not yet refactored into a `FuzzEntry` module. |
| MKT-05 | Blocked | `invariants/MKT05.sol` | Foundry regressions remain authoritative; not yet composed into `FuzzEntry`. |
| AUTH-01 / AUTH-01A / AUTH-02 | Blocked | `invariants/AUTH01_01A_02.sol` | Not yet refactored into a `FuzzEntry` module. |

## Removed remnants

Removed from the repo-owned supported path:

- empty or generic Medusa target selection
- ad hoc `--file` / `--contract` harness selection in the default runner path
- linked-library CREATE2 prepare and validation assumptions in the supported `just fuzz`, `just fuzz-deep`, and
  `just medusa-entry` flows
- the old linked-library deployment helper
- repo-owned CREATE2 salt wiring from the migrated Hub/LCC and MM-settle harnesses

Remaining migration debt is now the blocked checklist above. Those surfaces are not part of the full migration claim
until they are composed into `FuzzEntry`.
