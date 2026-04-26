# Post-single-hub validation plan

TASK-38 validates the TASK-40 single-contract `HubRSC` runtime after `SpokeRSC` and `HubCallback` were removed from the active architecture.

## Validation lanes

| Lane | Purpose | Command or trigger | Secrets |
| --- | --- | --- | --- |
| Deterministic pseudo-e2e | Required local and CI coverage for `HubRSC` behavior using Foundry mocks and direct `react()` calls. | `just pseudo-e2e` from `contracts/reactive` | None |
| Live Lasna smoke | Optional operator/deployment validation against live Reactive infrastructure. | PRs with relevant `contracts/reactive/src/**`, `contracts/reactive/scripts/**`, `contracts/reactive/test/e2e.sh`, or `.github/workflows/reactive-e2e.yml` changes and `reactive-e2e` label; manual Reactive E2E workflow with `run_smoke=true`; or `just e2e` with live env | Funded key such as `REACTIVE_CI_PRIVATE_KEY`, live RPC URLs, funded kREACT |

Deterministic pseudo-e2e must remain the default validation lane. Live smoke validation can fail for funding, RPC, or Reactive Network availability reasons and must not be required to prove local regressions.

## Live wallet model

The live Lasna smoke lane does not derive a per-run ephemeral wallet in the current single-HubRSC model. It uses one funded CI/operator key, exposed as `REACTIVE_CI_PRIVATE_KEY` and passed to the harness as `PRIVATE_KEY`, for all live-smoke signing:

- deploy `MockLiquidityHub`, `BatchProcessSettlement`, and `HubRSC`;
- derive the expected `HUB_RVM_ID` callback origin from the same key;
- register and fund test recipients on HubRSC; and
- emit the mock protocol-chain queue and liquidity events.

This is intentional for the single-HubRSC smoke lane because the receiver authorization and HubRSC RVM id are tied to the deploying key for the run. Per-run ephemeral recipient addresses may still be supplied through `RECIPIENT_ONE` and `RECIPIENT_TWO`, but the funded master key remains the signer. Deterministic pseudo-e2e must not use `REACTIVE_CI_PRIVATE_KEY` or any live key.

## Scenario matrix

| Scenario | Deterministic coverage |
| --- | --- |
| Unregistered recipient | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ERecipientRegistrationAndFundingMatrix` |
| Registered but underfunded recipient | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ERecipientRegistrationAndFundingMatrix` |
| Active funded recipient | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ERecipientRegistrationAndFundingMatrix` |
| Debit on matching lifecycle events | `HubRSC.PseudoE2E.t.sol::test_pseudoE2EDebitDepletionPauseAndTopUpRecovery` |
| Debit on processing / callback reconciliation | `HubRSC.PseudoE2E.t.sol::test_pseudoE2EDebitDepletionPauseAndTopUpRecovery` |
| Depletion pause | `HubRSC.PseudoE2E.t.sol::test_pseudoE2EDebitDepletionPauseAndTopUpRecovery` |
| Top-up / reactivation recovery | `HubRSC.PseudoE2E.t.sol::test_pseudoE2EDebitDepletionPauseAndTopUpRecovery` |
| Bounded dispatch / self-continuation | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ESingleHubRoutingRetryAndCustodianRecipientMatrix` |
| Retry blocking | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ESingleHubRoutingRetryAndCustodianRecipientMatrix` |
| Terminal failure quarantine | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ETerminalFailureQuarantinesCustodianRecipient` |
| FIFO debt attribution | `HubRSC.RecipientFunding.t.sol` FIFO debt-context tests |
| Duplicate log dedupe | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ESingleHubRoutingRetryAndCustodianRecipientMatrix` |
| Shared-underlying routing / backfill | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ESingleHubRoutingRetryAndCustodianRecipientMatrix` |
| MM/custodian recipient shape | `HubRSC.PseudoE2E.t.sol::test_pseudoE2ESingleHubRoutingRetryAndCustodianRecipientMatrix` |

## Surfaces updated

- `contracts/reactive/test/hub/HubRSC.PseudoE2E.t.sol`: deterministic pseudo-e2e suite.
- `contracts/reactive/Justfile`: `pseudo-e2e` developer command.
- `.github/workflows/ci.yml`: deterministic pseudo-e2e CI job without live secrets.
- `.github/workflows/e2e.yml`: existing core contract fork E2E lane.
- `.github/workflows/reactive-e2e.yml`: label/path gated Reactive live smoke lane.
- `contracts/reactive/README.md`, `CAVEATS.md`, and `env.sample`: lane separation and live-secret guidance.
- `contracts/reactive/test/e2e.sh`: remains a live harness path, polls HubRSC/receiver state, and is not deterministic CI coverage.
