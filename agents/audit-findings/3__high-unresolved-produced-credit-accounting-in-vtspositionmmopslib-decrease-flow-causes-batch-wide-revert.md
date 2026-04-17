[High] Unresolved produced-credit accounting in VTSPositionMMOpsLib decrease flow causes batch-wide revert

# Description

MM decrease-liquidity can add produced credit without same-batch consumption; at batch finality a strict invariant check reverts the entire MMPositionManager batch, breaking common decrease flows.

In the MM decrease path, VTSPositionMMOpsLib computes a vault-immediate settleable slice and sets requiredSettlementDelta to this amount. It then applies [_applyPositiveRequiredSettlementToOwnerAndVault](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L173), which [decreases the market vault reserve](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L213) and [records produced credit via MarketCurrencyDelta.addProduced](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/VTSPositionMMOpsLib.sol#L216), while also updating the protocol-owned (MMPositionManager) underlying delta. No matching MarketCurrencyDelta.consumeProduced is performed in the same decrease flow. At the end of the MMPositionManager batch, PositionManagerEntrypoint._afterBatch enforces [vtsOrchestrator.assertNonZeroDeltas](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L64), which calls [MarketCurrencyDelta.assertResolved](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/MarketCurrencyDelta.sol#L66-L67) and reverts if any produced credit remains non-zero. Produced is typically only consumed during [onMMSettle withdrawals (which use delta-backed withdrawals)](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/VTSLifecycleLinkedLib.sol#L548-L557) or certain deposit-from-deltas paths; these are not guaranteed to occur in the same batch and may be blocked by RFS/active-state constraints. As a result, ordinary MM decrease batches in markets with non-zero vault settleable reserve revert at batch finality, effectively breaking decrease-liquidity flows via the router in common operating conditions. This behavior is introduced/materially affected by the PR’s changes that tie decrease settlement routing to strict produced-credit accounting with batch-finality enforcement.

# Severity

**Impact Explanation:** [High] Breaks a core router operation (MM decrease-liquidity) in common conditions by reverting entire batches at finality; not a mere liveness delay but a structural failure under typical market states.

**Likelihood Explanation:** [Medium] Requires the market vault to have non-zero settleable reserve (common but not guaranteed). Users could attempt same-batch reconciliation, but it is non-standard and may be blocked by RFS/active-state constraints.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Plain MM decrease-liquidity: A vault-immediate settleable slice exists, VTSPositionMMOpsLib adds produced credit but does not consume it in the same flow. The batch reaches finality; PositionManagerEntrypoint._afterBatch -> [vtsOrchestrator.assertNonZeroDeltas](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/modules/PositionManagerEntrypoint.sol#L64) -> [MarketCurrencyDelta.assertResolved](https://github.com/usherlabs/fiet-protocol/blob/7149455e77704bd8b9cca122d8a0b4f655f1f862/contracts/evm/src/libraries/MarketCurrencyDelta.sol#L66-L67) detects leftover produced and reverts the entire batch.
#### Preconditions / Assumptions
- (a). Market vault holds non-zero in-market reserve for at least one underlying so a vault-immediate settleable slice exists during decrease-liquidity.
- (b). User executes a decrease-liquidity operation via MMPositionManager.
- (c). No subsequent same-batch onMMSettle withdrawal (or similar) consumes the produced credit before batch finality (may be disallowed by RFS/active-state).

### Scenario 2.
Mixed router batch: The locker performs unrelated actions (e.g., unwrap or add liquidity with settle-in-hook as a no-op for protocol-owned delta) and then a decrease-liquidity. The decrease adds produced credit with no matching same-batch consumption. End-of-batch invariant checking reverts the whole batch.
#### Preconditions / Assumptions
- (a). Market vault holds non-zero in-market reserve for at least one underlying so a vault-immediate settleable slice exists during the decrease.
- (b). User executes a batch including unrelated actions (e.g., unwrap, add-liquidity with settle-in-hook as a no-op for protocol-owned delta) followed by a decrease-liquidity.
- (c). No subsequent same-batch produced-credit consumption occurs before batch finality.

### Scenario 3.
Seizure decrease-liquidity: A vault-immediate settleable slice exists in seizure routing; produced is added but not consumed within the same batch. End-of-batch produced-credit invariant check fails and the batch reverts.
#### Preconditions / Assumptions
- (a). Position is eligible for seizure decrease.
- (b). Market vault holds non-zero in-market reserve for at least one underlying so a vault-immediate settleable slice exists during seizure decrease.
- (c). No subsequent same-batch produced-credit consumption occurs before batch finality.
