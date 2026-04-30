// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.26;

/// @title AbstractHubReactiveBridge
/// @author Fiet Protocol
/// @notice Documents the **ReactVM isolation model** for `HubRSC` and the required pipeline from observation to canonical state.
///
/// ## Two execution contexts
///
/// Reactive deploys two logical faces of the same contract bytecode:
///
/// 1. **Top-level Reactive Network contract** (`vm == false` in `AbstractReactive.detectVm`):
///    - Holds **canonical** storage: pending queues, dispatch budgets, recipient balances, subscriptions, deduplication bitmaps.
///    - Receives **callback-proxy** deliveries that apply canonical updates (`applyCanonicalProtocolLog`).
///
/// 2. **ReactVM instance** (`vm == true`):
///    - Executes `react(IReactive.LogRecord)` when subscribed logs match.
///    - **Must not** assume that storage writes performed here persist on the canonical deployment.
///    - The only supported side effect from the VM path is **`emit Callback(...)`** to the reactive callback infrastructure,
///      which then invokes the canonical contract on the Reactive chain with the encoded log payload.
///
/// ## Required pipeline (state channel)
///
/// ```text
/// protocol log -> react() [vmOnly] -> emit Callback(reactChainId, hub, gas, abi.encodeCall(applyCanonicalProtocolLog, (log)))
///     -> callback proxy -> applyCanonicalProtocolLog [onlyReactiveCallbackProxy] -> _syncObservedSystemDebt + _handle*
/// ```
///
/// Any new intake that mutates hub mirror state must follow this pipeline (or an equivalent callback-gated path).
///
/// ## Errors
///
/// These errors are referenced from `HubRSC` / `HubRSCStorage` when enforcing the bridge.
library AbstractHubReactiveBridge {
    /// @notice Caller is not the configured reactive-network callback proxy.
    error UnauthorizedReactiveCallback();
    /// @notice `reactiveCallbackProxy` was configured as zero address.
    error InvalidReactiveCallbackProxy();
}
