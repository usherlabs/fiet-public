---
name: Queue Settlement Hardening
overview: Align queue and settlement logic with the design thesis that queue ownership may be decoupled from immediate LCC custody, while settlement-time checks remain the canonical enforcement point for present settleability. Update code comments and spec documentation so the rationale is explicit and consistent across `LiquidityHub`, `LiquidityHubLib`, and MM flows.
todos:
  - id: map-code-edits
    content: Update `LiquidityHub`, `LiquidityHubLib`, `LCC`, and bound-setting paths to reflect the queue-validity vs settlement-time-settleability model with explicit rationale comments.
    status: completed
  - id: refresh-tests
    content: Add or update queue/settlement and MM tests so retriable settlement reverts and bound-transition protections are covered.
    status: completed
  - id: write-spec-doc
    content: Create `agents/spec/Settlement Queue Semantics.md` and cross-reference it from existing spec docs.
    status: completed
isProject: false
---

# Queue And Settlement Hardening Plan

## Objective

Implement the queue/settlement design thesis consistently across code and documentation:

- queue creation should reject structurally invalid queue owners,
- `_queueSettlement()` should remain an accounting primitive,
- `queueForTransferRecipient()` should keep strict recipient-serviceability checks because that path assumes the recipient already holds the backing LCC,
- `processSettlementFor()` should remain the runtime enforcement point for whether a queued claim is presently settleable,
- settlement reverts for not-yet-reconciled reserves/custody should be treated as retriable, not as a need for in-function fallback.

## Targeted Code Changes

- Update [contracts/evm/src/LiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/LiquidityHub.sol):
  - keep `_assertQueueRecipientServiceable(...)` attached to `queueForTransferRecipient()` only;
  - ensure `_queueSettlement(...)` is documented as pure accounting, with comments explaining why it deliberately does not assert current holder backing;
  - review `_unwrap(...)`, `cancelWithQueue(...)`, `_cancelWithQueue(...)`, `planCancelWithQueue(...)`, and `executePlannedCancel(...)` comments so they explain that queue validity is distinct from present settleability;
  - add/retain minimal queue-owner validity guards only for structurally impossible recipients (for example zero address), if that matches the chosen policy.
- Update [contracts/evm/src/libraries/LiquidityHubLib.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/libraries/LiquidityHubLib.sol):
  - document `queueSettlement(...)` as storage accounting only;
  - document `processSettlementLogic(...)` as the canonical settlement-time enforcement point for current reserves and current recipient backing;
  - add explicit comments around external-recipient settlement using `marketDerived` balance and why a revert means “not yet settleable”.
- Update [contracts/evm/src/LCC.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/LCC.sol):
  - add explanatory comments near `balancesOf(...)` and transfer hooks clarifying how bucket/exempt state affects external settlement serviceability;
  - ensure comments tie `annulSettlementBeforeTransfer(...)` to preserving queue/backing integrity rather than settlement validity.
- Update bound-transition enforcement in [contracts/evm/src/LiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/LiquidityHub.sol) and, if needed, [contracts/evm/src/modules/BoundRegistry.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/modules/BoundRegistry.sol):
  - prevent an address from becoming exempt while it still owns queued settlement for an LCC/factory scope;
  - document this as protection against creating permanently non-settleable queues via later role changes.
- Review interface docs in [contracts/evm/src/interfaces/IMinimalLiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/IMinimalLiquidityHub.sol) and [contracts/evm/src/interfaces/ILiquidityHub.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/src/interfaces/ILiquidityHub.sol):
  - align NatSpec with the new design language so unwrap/queue APIs describe queue validity vs settlement-time settleability correctly.

## Tests To Add Or Update

- Update/add `LiquidityHub` tests to cover:
  - queue accounting paths remaining allowed when queue ownership is intentionally decoupled from current holder backing;
  - `queueForTransferRecipient()` still rejecting non-serviceable recipients;
  - `processSettlementFor()` reverting for valid-but-not-yet-settleable queues and succeeding after the relevant reserve/custody reconciliation;
  - bound-level changes to exempt status reverting while queued settlement exists.
- Update/add MM-oriented tests in [contracts/evm/test/MMPositionManager.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/MMPositionManager.t.sol):
  - preserve the queue-owner/custody-decoupling flow via `queueCustodian.release(...)` then `processSettlementFor(...)`;
  - verify comments/spec assumptions match exercised behaviour.
- Review queue/settlement tests in [contracts/evm/test/LiquidityHub.settlement.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/LiquidityHub.settlement.t.sol), [contracts/evm/test/LiquidityHub.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/LiquidityHub.t.sol), and [contracts/evm/test/libraries/LiquidityHubLib.t.sol](/Users/ryansoury/dev/fiet/protocol/contracts/evm/test/libraries/LiquidityHubLib.t.sol) for outdated assumptions.

## Documentation Work

- Create a canonical design note in `agents/spec`, preferably [agents/spec/Settlement Queue Semantics.md](/Users/ryansoury/dev/fiet/protocol/agents/spec/Settlement Queue Semantics.md), with:
  - `Overview`
  - `Design Goals`
  - `Core Invariants`
  - `Queue Validity vs Present Settleability`
  - `Queue-Producing Paths`
  - `Settlement Paths`
  - `Bound-Level Constraints`
  - `MM Custody-Reconciliation Flow`
  - `Security Considerations`
  - `Related Modules`
- Cross-reference the decision from existing specs where helpful, especially [agents/spec/LiquidityHub.md](/Users/ryansoury/dev/fiet/protocol/agents/spec/LiquidityHub.md), [agents/spec/MMPositionManager.md](/Users/ryansoury/dev/fiet/protocol/agents/spec/MMPositionManager.md), and [agents/spec/Settlements.md](/Users/ryansoury/dev/fiet/protocol/agents/spec/Settlements.md).

## Implementation Notes

Use explicit comments in edited code to capture the thesis in-place, especially around:

- why `_queueSettlement()` does not assert current serviceability,
- why `queueForTransferRecipient()` does,
- why `processSettlementFor()` is allowed to revert for queues that are valid but not yet executable,
- why exempt-transition guards exist.

Key snippets to preserve semantically while clarifying intent:

```solidity
function queueForTransferRecipient(address lcc, address recipient, uint256 amount) external
```

This path should keep strict serviceability validation because it assumes the transferred recipient is already the eventual burn source.

```solidity
function _queueSettlement(address lcc, address recipient, uint256 amount) internal
```

This should stay an accounting helper with comments explaining that queue ownership may intentionally differ from current custody.

```solidity
function processSettlementLogic(LiquidityHubStorage storage s, address lcc, address recipient, uint256 maxAmount) internal
```

This should remain the definitive runtime check for reserves and recipient-backed settleability.
