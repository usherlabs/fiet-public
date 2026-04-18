 # Medusa fuzz migration

`test/fuzz/FuzzEntry.sol` is the repo-owned Medusa composition root. The supported workflow now runs Medusa against
that concrete target model rather than against per-harness CREATE2-prepared linked-library deployments.

## Supported path

Medusa now runs through a composed runtime tree:

- `contracts/evm/medusa.json` and `contracts/evm/medusa.deep.json` target `FuzzEntry`
- `contracts/evm/scripts/medusa.sh` reads the target contract from config instead of patching in ad hoc harness pairs
- `[profile.medusa]` in `contracts/evm/foundry.toml` is scoped to the supported `FuzzEntry` path
- `FuzzEntry` composes `FuzzMMQ01`, `FuzzHubLCC`, `FuzzMMSettle`, `FuzzMarketAuth`, and `FuzzVTSPosition`
- `FuzzVTSPosition` inherits `FuzzVTSCoreTail` so the remaining core/accounting/VTS tail surfaces route through the
  same supported target without root-level helper plumbing

From `contracts/evm/`:

```bash
just fuzz
just fuzz-deep
just fuzz-invariants
just medusa-entry

MEDUSA_CORPUS_DIR=artifacts/medusa-local \
  just medusa-entry -- --test-limit 50 --seq-len 5
```

The runner writes coverage-guided artifacts to `<MEDUSA_CORPUS_DIR>/<TargetContract>/...`, so the supported path stores
artifacts under `FuzzEntry/`.

## Migration checklist

Completion for this migration is evaluated only by the checklist below.

Status meanings:

- `Migrated`: composed into `FuzzEntry` and part of the supported Medusa path

| Surface | Status | Current location | Notes |
| ------- | ------ | ---------------- | ----- |
| Fuzz composition root | Migrated | `FuzzEntry.sol` | Supported Medusa target. |
| Shared helper utilities | Migrated | `FuzzHelper.sol` | Shared by composed modules. |
| MMQ-01 queue custody guard | Migrated | `FuzzMMQ01.sol` | Runtime `new` composition; no CREATE2 linker prep. |
| Hub / LCC composed module | Migrated | `FuzzHubLCC.sol` | `FuzzEntry` composes the Hub, LCC, wrap, and confirmTake regressions directly. |
| Hub fuzz adapter | Migrated | `harnesses/FuzzLiquidityHub.sol` | Fuzz-only adapter inlines the former linked-library call surfaces for the Hub/LCC harnesses. |
| MM-settle composed module | Migrated | `FuzzMMSettle.sol` | `FuzzEntry` composes the repo-owned settle harnesses directly. |
| Market/auth composed module | Migrated | `FuzzMarketAuth.sol` | `FuzzEntry` composes the repo-owned signal, market, and auth harnesses directly. |
| VTS composed module | Migrated | `FuzzVTSPosition.sol` | `FuzzEntry` composes the repo-owned commit / coverage / seize harnesses directly. |
| VTS core tail composed module | Migrated | `FuzzVTSCoreTail.sol` | `FuzzVTSPosition` inherits the remaining core/accounting/VTS tail module. |
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
| SETTLE-01 | Migrated | `FuzzMMSettle.sol`, `invariants/SETTLE01.sol` | Old helper deployment removed; harness now runs directly under the composed Medusa path. |
| SETTLE-02 | Migrated | `FuzzMMSettle.sol`, `invariants/SETTLE02.sol` | Old helper deployment removed; harness now runs directly under the composed Medusa path. |
| SIG-01 / SIG-02 | Migrated | `FuzzMarketAuth.sol`, `invariants/SIG01_02.sol` | Composed into `FuzzEntry`; signal verification remains self-hosted with no linked-library prep. |
| MKT-01 / MKT-02 | Migrated | `FuzzMarketAuth.sol`, `invariants/MKT01_02.sol` | Proxy add-liquidity and core-pool-key guards now flow through the supported target. |
| MKT-03 / MKT-06 | Migrated | `FuzzMarketAuth.sol`, `invariants/MKT03_06.sol` | Registry uniqueness and canonical ordering now flow through the supported target. |
| MKT-05 | Migrated | `FuzzMarketAuth.sol`, `invariants/MKT05.sol` | The lightweight cancellation check now flows through `FuzzEntry`; Foundry remains authoritative for the stricter real-path regression evidence. |
| AUTH-01 / AUTH-01A / AUTH-02 | Migrated | `FuzzMarketAuth.sol`, `invariants/AUTH01_01A_02.sol` | The supported path now exposes the auth guards; Foundry remains authoritative for the deeper batch-scoped regression evidence. |
| COMMIT-01 | Migrated | `FuzzVTSPosition.sol`, `invariants/COMMIT01.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COMMIT-02 | Migrated | `FuzzVTSPosition.sol`, `invariants/COMMIT02.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COMMIT-03 | Migrated | `FuzzVTSPosition.sol`, `invariants/COMMIT03.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COV-01 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/COV01.sol` | Composed into `FuzzEntry` through the core tail module. |
| COV-02 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/COV02.sol` | The hook-order evidence now runs through the supported path. |
| COV-03 | Migrated | `FuzzVTSPosition.sol`, `invariants/COV03.sol` | Composed into `FuzzEntry`; no linked-library predeploy remains in the harness. |
| COV-04 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/COV04.sol` | The fee-burn remainder math harness now runs through the supported path. |
| FEE-01 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/FEE01.sol` | Composed into `FuzzEntry` through the core tail module. |
| FEE-02 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/FEE02.sol` | Composed into `FuzzEntry` through the core tail module. |
| VTS-01 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/VTS01.sol` | Composed into `FuzzEntry` through the core tail module. |
| VTS-02 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/VTS02.sol` | Composed into `FuzzEntry` through the core tail module. |
| VTS-03 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/VTS03.sol` | Composed into `FuzzEntry` through the core tail module. |
| DELTA-01 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/DELTA01.sol` | Composed into `FuzzEntry` through the core tail module. |
| SEIZE-01 / SEIZE-02 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/SEIZE01_02.sol` | Composed into `FuzzEntry` through the core tail module. |
| SEIZE-03 / SEIZE-04 | Migrated | `FuzzVTSPosition.sol`, `invariants/SEIZE03_04.sol` | Composed into `FuzzEntry`; the harness uses only the inlined touch-position path. |
| PAUSE-01 | Migrated | `FuzzVTSCoreTail.sol`, `invariants/PAUSE01.sol` | Composed into `FuzzEntry` through the core tail module. |

The checklist is now complete for the repo-owned fuzz suite.

## Removed remnants

Removed from the repo-owned supported path:

- empty or generic Medusa target selection
- ad hoc `--file` / `--contract` harness selection in the default runner path
- linked-library CREATE2 prepare and validation assumptions in the supported `just fuzz`, `just fuzz-deep`, and
  `just medusa-entry` flows
- the old linked-library deployment helper
- repo-owned CREATE2 salt wiring from the supported fuzz workflow

Current counts in `contracts/evm/test/fuzz/**/*.sol`:

- `FuzzLinkedLibs` references: `0`
- `echidna.` salt references: `0`
