# Post-single-hub validation plan

TASK-38 validates the TASK-40 single-contract `HubRSC` runtime after `SpokeRSC` and `HubCallback` were removed from the active architecture.

## Validation lanes

| Lane | Purpose | Command or trigger | Secrets |
| --- | --- | --- | --- |
| Deterministic local simulation | Required local and CI supporting coverage for `HubRSC` behavior using Foundry mocks and direct `react()` calls. This is not the full Lasna pseudo-e2e proof. | `just local-simulation` from `contracts/reactive` | None |
| Lasna/Reactive Network pseudo-e2e smoke | Optional operator/deployment validation against live Reactive infrastructure. | PRs with relevant `contracts/reactive/src/**`, `contracts/reactive/scripts/**`, `contracts/reactive/test/e2e.sh`, or `.github/workflows/reactive-e2e.yml` changes and `reactive-e2e` label; manual Reactive Validation workflow with `run_smoke=true`; or `just e2e` with live env | Funded key such as `REACTIVE_CI_PRIVATE_KEY`, live RPC URLs, funded kREACT |

Deterministic local simulation must remain the default validation lane. Lasna pseudo-e2e smoke validation can fail for funding, RPC, or Reactive Network availability reasons and must not be required to prove local regressions.

## Live wallet model

The live Lasna smoke lane does not derive a per-run ephemeral wallet in the current single-HubRSC model. It uses one funded CI/operator key, exposed as `REACTIVE_CI_PRIVATE_KEY` and passed to the harness as `PRIVATE_KEY`, for all live-smoke signing:

- deploy `MockLiquidityHub`, `BatchProcessSettlement`, and `HubRSC`;
- derive the expected `HUB_RVM_ID` callback origin from the same key;
- register and fund test recipients on HubRSC; and
- emit the mock protocol-chain queue and liquidity events.

This is intentional for the single-HubRSC Lasna smoke lane because the receiver authorization and HubRSC RVM id are tied to the deploying key for the run. Per-run ephemeral recipient addresses may still be supplied through `RECIPIENT_ONE` and `RECIPIENT_TWO`, but the funded master key remains the signer. Deterministic local simulation must not use `REACTIVE_CI_PRIVATE_KEY` or any live key.

## Scenario matrix

| Scenario | Deterministic local simulation coverage |
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

- `contracts/reactive/test/hub/HubRSC.PseudoE2E.t.sol`: deterministic local simulation suite.
- `contracts/reactive/Justfile`: `local-simulation` developer command plus the compatibility `pseudo-e2e` alias.
- `.github/workflows/e2e.yml`: existing core contract fork E2E lane.
- `.github/workflows/reactive-e2e.yml`: standalone Reactive workflow containing deterministic local simulation and the label/path gated Lasna pseudo-e2e smoke lane.
- `contracts/reactive/README.md`, `CAVEATS.md`, and `env.sample`: lane separation and live-secret guidance.
- `contracts/reactive/test/e2e.sh`: remains a live harness path, polls HubRSC/receiver state, and is not deterministic CI coverage.
