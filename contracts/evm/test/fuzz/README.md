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

## How this Medusa suite works

Medusa is now pointed at one concrete contract: `FuzzEntry`.

- `FuzzEntry` is the only repo-owned Medusa target. It is not itself a protocol harness; it is a composition root that
  mixes in the repo-owned fuzz modules and exposes the top-level `fuzz_*` properties Medusa should keep true.
- Each composed module (`FuzzMMQ01`, `FuzzHubLCC`, `FuzzMMSettle`, `FuzzMarketAuth`, `FuzzVTSPosition`) instantiates
  the underlying invariant harness contracts with ordinary runtime `new` calls and forwards their `action_*` and
  `fuzz_*` entrypoints.
- In practice Medusa deploys `FuzzEntry`, generates call sequences against the exposed `action_*` methods, and checks
  the exported `fuzz_*` properties after and during those sequences.
- `FuzzEntry.t.sol` is the Foundry-side smoke test for that composition root. It is not a replacement for Medusa; it
  proves the composed tree deploys and the expected top-level properties remain callable from one concrete target.

Compared to the legacy Echidna layout, the supported path no longer does per-harness selection plus deterministic
linked-library preparation. The state still lives inside Solidity harness contracts, but the workflow is now:

1. compile one target (`FuzzEntry`)
2. compose repo-owned child harnesses under that target
3. let Medusa explore the unified action/property surface

`FuzzHubLCC` is the Hub/LCC slice of that pattern. It is a Medusa-facing module, not a standalone fuzz target: it
deploys the Hub/LCC child harnesses once, forwards actions into them, and re-exports their properties so `FuzzEntry`
can present a single supported Medusa surface.

## Why `FuzzLiquidityHub` is an adapter

The Hub/LCC cluster needs one fuzz-only adapter: `test/fuzz/harnesses/FuzzLiquidityHub.sol`.

- We do not inherit `src/LiquidityHub.sol` directly because the production contract dispatches through
  `LCCFactoryLinkedLib` / `LiquidityHubLinkedLib` from non-virtual functions.
- A derived contract would therefore still execute the linked-library path we removed from the repo-owned Medusa
  workflow.
- `FuzzLiquidityHub` stays intentionally close to `src/LiquidityHub.sol` and only swaps those linked-library call sites
  to their direct library equivalents so the fuzz harnesses inherit current Hub semantics without reintroducing the old
  CREATE2 prep flow.

If the production Hub later exposes proper overridable/internal seams for those linked-library call sites, this adapter
should collapse back to inheritance rather than remain a long-lived fork.

## Coverage matrix

`contracts/evm/INVARIANTS.md` remains the source of truth for invariant definitions. The tables below answer three
questions for every invariant:

- what the priority is for ongoing review
- whether the primary evidence currently comes from `FuzzEntry`, core Foundry tests, or both
- how much of the invariant is covered, and where the authoritative regression evidence lives

### Hub / LCC / market-boundary invariants

| Invariant | Priority | Primary path | Evidence | Coverage notes |
| --------- | -------- | ------------ | -------- | -------------- |
| LCC-BACKING-01 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/LCCBacking01.sol` | Directly composed into the supported Medusa path. |
| LCC-01 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/LCC01.sol` | Direct transfer-boundary property in the composed Hub/LCC module. |
| LCC-02 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/LCC02.sol` | Bucket-accounting property runs through the supported Hub adapter path. |
| LCC-03 | P1 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/LCC03.sol` | Nested ingress-settlement ordering is exercised under the composed Medusa path. |
| HUB-01 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/HUB01.sol` | Native and ERC20 wrap flow remains a first-class Medusa property. |
| HUB-01A | P1 | Foundry | `LiquidityHub.t.sol` | `receive()` sender-gating is authoritative in production-Hub tests rather than a separate Medusa child harness. |
| HUB-02 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/HUB02.sol` | Unwrap decomposition and queue accounting remain direct Medusa properties. |
| HUB-02A | P0 | Foundry + Medusa | `LiquidityHub.t.sol`, `MMPositionManager.t.sol`, `harnesses/FuzzLiquidityHub.sol` | Endpoint-only `unwrapTo` admission is enforced in the adapter and covered more explicitly in core Foundry regressions. |
| HUB-02B | P0 | Foundry + Medusa | `LiquidityHub.t.sol`, `harnesses/FuzzLiquidityHub.sol` | Recipient serviceability is enforced in the adapter; targeted Foundry tests remain the clearest regression oracle. |
| HUB-02C | P1 | Foundry | `MMPositionManager.t.sol` | Recipient-shape changes after queueing remain covered by real-path queue/locker regressions. |
| HUB-03 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/HUB03.sol` | Invalid-LCC and issuer-only paths stay in the composed Medusa surface. |
| HUB-04 | P1 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/HUB04.sol` | Factory-consistency invariant is covered directly in Medusa. |
| HUB-05 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/HUB05.sol` | Balance-backed `confirmTake` remains a direct Medusa property. |
| HUB-06 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/HUB06.sol` | `prepareSettle` liquidity-accounting consistency remains a direct Medusa property. |
| MKT-04 | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/MKT04_04A.sol` | Factory and issuer gating remain on the supported Hub/LCC path. |
| MKT-04A | P0 | Medusa/FuzzEntry | `FuzzHubLCC.sol`, `invariants/MKT04_04A.sol` | Bound-level policy regression stays composed with the same Hub adapter path. |

### Commit / signal / VTS invariants

| Invariant | Priority | Primary path | Evidence | Coverage notes |
| --------- | -------- | ------------ | -------- | -------------- |
| COMMIT-ROLE-01 | P1 | Foundry + Medusa | `MMPositionManager.t.sol`, `FuzzVTSPosition.sol`, `invariants/COMMIT03.sol` | Role separation is exercised through renew/advancer flows; Foundry remains the clearest real-path oracle. |
| SIG-01 | P0 | Medusa/FuzzEntry | `FuzzMarketAuth.sol`, `invariants/SIG01_02.sol` | Nonce monotonicity is a direct composed Medusa property. |
| SIG-02 | P0 | Medusa/FuzzEntry | `FuzzMarketAuth.sol`, `invariants/SIG01_02.sol` | Valid/invalid proof handling remains a direct Medusa property. |
| COMMIT-00 | P0 | Foundry | `VTSOrchestrator.t.sol`, `VTSPositionLib.t.sol` | Live-liquidity/`commitmentMax` drift remains authoritative in the core VTS Foundry tests. |
| COMMIT-01 | P0 | Medusa/FuzzEntry | `FuzzVTSPosition.sol`, `invariants/COMMIT01.sol` | Backing gate stays directly fuzzed under the supported path. |
| COMMIT-02 | P0 | Medusa/FuzzEntry | `FuzzVTSPosition.sol`, `invariants/COMMIT02.sol` | Checkpoint deficit math remains directly fuzzed under the supported path. |
| COMMIT-02A | P0 | Foundry + Medusa | `invariants/COMMIT02.sol`, `VTSOrchestrator.t.sol` | Deficit formation is fuzzed; the explicit non-seizure freeze is asserted in the core orchestrator tests. |
| COMMIT-02B | P0 | Foundry + Medusa | `invariants/COMMIT02.sol`, `VTSOrchestrator.t.sol` | Deficit clearing is fuzzed; full-deactivation storage cleanup remains authoritative in Foundry. |
| COMMIT-03 | P0 | Medusa/FuzzEntry | `FuzzVTSPosition.sol`, `invariants/COMMIT03.sol` | Advancer binding and rotation remain direct Medusa properties. |
| VTS-01 | P0 | Medusa/FuzzEntry | `FuzzVTSCoreTail.sol`, `invariants/VTS01.sol` | Growth settlement before modify remains a direct Medusa property. |
| VTS-02 | P1 | Medusa/FuzzEntry | `FuzzVTSCoreTail.sol`, `invariants/VTS02.sol` | Tick flip identity remains a direct Medusa property. |
| VTS-03 | P0 | Medusa/FuzzEntry | `FuzzVTSCoreTail.sol`, `invariants/VTS03.sol` | Segment-based growth reflection remains a direct Medusa property. |

### Settle / seize / delta invariants

| Invariant | Priority | Primary path | Evidence | Coverage notes |
| --------- | -------- | ------------ | -------- | -------------- |
| SETTLE-01 | P0 | Medusa/FuzzEntry | `FuzzMMSettle.sol`, `invariants/SETTLE01.sol` | Active-position withdrawal guard is a direct composed Medusa property. |
| SETTLE-02 | P0 | Medusa/FuzzEntry | `FuzzMMSettle.sol`, `invariants/SETTLE02.sol` | Seizure settle clamps remain direct composed Medusa properties. |
| SETTLE-03 | P0 | Foundry | `MMPositionActionsImpl.t.sol`, `VTSPositionMMOpsLib.accessor.t.sol`, `harnesses/PositionManagerImplQueueCustodyHarness.sol` | Full MM decrease-routing and exported-settlement behavior remain authoritative in the real-path/core harness tests. |
| MMQ-01 | P0 | Medusa/FuzzEntry | `FuzzMMQ01.sol` | Queue-custody guard is a direct composed Medusa property. |
| SETTLE-04 | P0 | Foundry | `MMPositionManager.t.sol`, `VTSPositionMMOpsLib.accessor.t.sol` | In-hook protocol-credit clearing order remains authoritative in the core MM path tests. |
| SEIZE-01 | P0 | Medusa/FuzzEntry | `FuzzVTSCoreTail.sol`, `invariants/SEIZE01_02.sol` | Lane-scoped seizability remains a direct Medusa property. |
| SEIZE-02 | P0 | Medusa/FuzzEntry | `FuzzVTSCoreTail.sol`, `invariants/SEIZE01_02.sol` | Allowed-verifier grace extension remains a direct Medusa property. |
| SEIZE-03 | P0 | Medusa/FuzzEntry | `FuzzVTSPosition.sol`, `invariants/SEIZE03_04.sol` | No-LCC-issue seizure path remains a direct Medusa property. |
| SEIZE-04 | P0 | Medusa/FuzzEntry | `FuzzVTSPosition.sol`, `invariants/SEIZE03_04.sol` | Commit identity fixity during MM operations remains a direct Medusa property. |
| DELTA-01 | P0 | Medusa/FuzzEntry | `FuzzVTSCoreTail.sol`, `invariants/DELTA01.sol` | Batch delta netting remains a direct Medusa property. |
| DELTA-01A | P0 | Foundry | `MMPositionManager.t.sol`, `DeltaDesignStatements.t.sol` | Reserve-export and credit-backed withdrawal consumption remain authoritative in real-path design-statement tests. |
| DELTA-02 | P1 | Foundry | `DeltaDesignStatements.t.sol` | Residual-balance FCFS dust remains documented and asserted in design-statement tests. |
| DELTA-03 | P1 | Foundry | `DeltaDesignStatements.t.sol` | Planned-cancel path scoping remains documented and asserted in design-statement tests. |

### Auth / pause / market-structure invariants

| Invariant | Priority | Primary path | Evidence | Coverage notes |
| --------- | -------- | ------------ | -------- | -------------- |
| AUTH-01 | P0 | Medusa + Foundry | `FuzzMarketAuth.sol`, `invariants/AUTH01_01A_02.sol`, `AuthSeizeInvariants.t.sol` | Supported Medusa path carries the auth guards; Foundry remains the deeper batch-scoped regression oracle. |
| AUTH-01A | P0 | Medusa + Foundry | `FuzzMarketAuth.sol`, `invariants/AUTH01_01A_02.sol`, `AuthSeizeInvariants.t.sol` | Same-position and batch-scoped seizure context is exposed in Medusa and verified more deeply in Foundry. |
| AUTH-02 | P0 | Medusa + Foundry | `FuzzMarketAuth.sol`, `invariants/AUTH01_01A_02.sol`, `AuthSeizeInvariants.t.sol` | Mid-batch NFT-transfer blocking is exposed in Medusa and verified more deeply in Foundry. |
| PAUSE-01 | P0 | Medusa + Foundry | `FuzzVTSCoreTail.sol`, `invariants/PAUSE01.sol`, `VTSOrchestrator.t.sol`, `MMPositionManager.t.sol` | Pause guards remain composed into `FuzzEntry`; Foundry covers the broader paused real-path behavior. |
| MKT-01 | P0 | Medusa/FuzzEntry | `FuzzMarketAuth.sol`, `invariants/MKT01_02.sol` | Proxy add-liquidity rejection remains a direct Medusa property. |
| MKT-02 | P0 | Medusa/FuzzEntry | `FuzzMarketAuth.sol`, `invariants/MKT01_02.sol` | Core pool-key write-once guard remains a direct Medusa property. |
| MKT-03 | P1 | Medusa/FuzzEntry | `FuzzMarketAuth.sol`, `invariants/MKT03_06.sol` | Core-pool uniqueness remains a direct Medusa property. |
| MKT-05 | P0 | Medusa + Foundry | `FuzzMarketAuth.sol`, `invariants/MKT05.sol`, `ProxyHook.t.sol`, `ProxyHook.mutationHardening.t.sol` | Medusa carries the lightweight cancellation/drift property; Foundry remains authoritative for the stricter live-path regression. |
| MKT-06 | P1 | Medusa/FuzzEntry | `FuzzMarketAuth.sol`, `invariants/MKT03_06.sol` | Canonical ordering remains a direct Medusa property. |

## Migration status

The repo-owned Medusa migration is complete for the supported path:

- `FuzzEntry` is the concrete target
- repo-owned `FuzzLinkedLibs` references are `0`
- repo-owned `echidna.` salt references are `0`
- the old linked-library CREATE2 prepare/validation flow is no longer part of `just fuzz`, `just fuzz-deep`, or
  `just medusa-entry`
- fee-era invariants (`COV-01`, `COV-03`, `COV-04`, `FEE-01`, `FEE-02`) and `VTSFeeLib`-specific docs/harnesses are no
  longer part of the supported path
- `script/e2e/MMCoverage.s.sol` is intentionally retired because the fee-pot and fee-accounting orchestrator lenses no
  longer exist

Removed from the repo-owned supported path:

- empty or generic Medusa target selection
- ad hoc `--file` / `--contract` harness selection in the default runner path
- linked-library CREATE2 prepare and validation assumptions in the supported Medusa flow
- the old linked-library deployment helper
- repo-owned CREATE2 salt wiring from the supported fuzz workflow
