## ADDED Requirements

### Requirement: Fee capability state SHALL be owned by a standalone engine

The system SHALL move fee-era storage ownership out of `VTSOrchestrator` into a standalone `VTSFeeEngine` that implements `IVTSCapabilityEngine`.

#### Scenario: Engine owns fee-era storage
- **WHEN** the strict fee-isolation refactor is implemented
- **THEN** `VTSOrchestrator` SHALL no longer declare or own `VTSFeeStorage`
- **AND** `VTSFeeEngine` SHALL own the fee-era pool and position accounting previously threaded through `feeS`

#### Scenario: Orchestrator stops exposing fee ownership
- **WHEN** callers inspect the base orchestrator surface after the refactor
- **THEN** `VTSOrchestrator` SHALL not expose fee-era getters or ownership-only methods that imply it is the fee-state owner

### Requirement: Base VTS state SHALL be exposed through a read-only state library

The system SHALL provide a `VTSStateLibrary` that exposes the base `VTSStorage` fields needed by fee-era logic without re-embedding fee ownership in the orchestrator or base libraries.

#### Scenario: Fee-era code reads base denominators
- **WHEN** fee-era logic needs values such as `totalDeficitPrincipal`, `totalSettled`, `settled`, `cumulativeDeficit`, or cumulative outflow checkpoints
- **THEN** that logic SHALL read them through `VTSStateLibrary`
- **AND** SHALL not depend on direct base-storage reach-through as the primary architectural boundary

### Requirement: Coverage routing SHALL use the capability engine boundary

The system SHALL route market-liquidity coverage accounting through `IVTSCapabilityEngine` rather than through `VTSOrchestrator`.

#### Scenario: Market liquidity is exercised
- **WHEN** `MarketFactory` records coverage for exercised market liquidity
- **THEN** it SHALL call `IVTSCapabilityEngine.incrementCoverage(...)`
- **AND** SHALL not call `VTSOrchestrator.incrementCoverage(...)`

#### Scenario: Coverage implementation remains fee-owned
- **WHEN** the capability engine receives a coverage increment
- **THEN** it SHALL delegate fee-era coverage accounting to `VTSFeeLib`
- **AND** use base-state reads only through the approved base-state boundary

### Requirement: Fee lifecycle integration SHALL preserve explicit ordering

The system SHALL preserve the current ordering-sensitive fee lifecycle by exposing explicit capability hooks for the pre-deficit, post-deficit, principal-increase, and touch-position phases.

#### Scenario: Growth settlement executes
- **WHEN** a position runs growth settlement
- **THEN** the implementation SHALL preserve the current pre-deficit and post-deficit fee hook ordering around base deficit/inflow updates

#### Scenario: Position touch executes
- **WHEN** a position runs the touch-position path
- **THEN** fee-specific residual capture, snapshot, and fee-adjustment work SHALL execute through the capability engine hook boundary rather than direct fee-library calls from the base path

### Requirement: Default v1 SHALL remain quarantined unless fee capability is enabled

The strict fee-isolation refactor SHALL preserve the conservative default product line where `coverageFeeShare == 0` disables ambient fee-era behavior.

#### Scenario: Conservative default configuration is used
- **WHEN** a market uses `VTSConfigs.getDefaultConfig()` or any configuration with `coverageFeeShare == 0`
- **THEN** the capability engine SHALL not activate fee-era coverage accounting as ambient behavior
- **AND** the base/quarantine invariants documented in `INVARIANTS.md` SHALL remain the authoritative default path

#### Scenario: Fee capability is explicitly enabled
- **WHEN** a market or harness uses a non-zero `coverageFeeShare`
- **THEN** the capability engine SHALL service the fee-era lifecycle and coverage hooks defined by this change
- **AND** the annexed fee/coverage invariants SHALL remain the authoritative behavior for that path

### Requirement: Harnesses and documentation SHALL reflect the strict boundary

The system SHALL update harnesses, docs, and verification surfaces so they describe and validate the strict fee-isolation boundary instead of the replayed intermediate split.

#### Scenario: Harnesses compile against the new boundary
- **WHEN** fee/position/Medusa harnesses call into VTS lifecycle paths
- **THEN** they SHALL use the new capability-engine and state-library surfaces required by the refactor

#### Scenario: Documentation describes the new owner boundary
- **WHEN** engineers or auditors review the protocol docs after the change
- **THEN** `INVARIANTS.md`, `ANNEXED-INVARIANTS.md`, `VTS-INERT-STATE-ISOLATION.md`, and related architecture notes SHALL describe `VTSFeeEngine` as the fee owner and `VTSOrchestrator` as fee-agnostic base orchestration
