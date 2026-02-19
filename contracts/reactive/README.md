# Reactive contracts

This repo contains the Reactive Network contracts that automate queued settlement processing for the Fiet protocol.

## Quick scenario

1. `LiquidityHub` emits `SettlementQueued(lcc, recipient, amount)` on the protocol chain.
2. The recipient's `SpokeRSC` picks it up and sends the settlement details to `HubCallback`.
3. `HubCallback` checks whether the recipient is mapped to the expected spoke via `setSpokeForRecipient(recipient, spoke)`.
4. If valid, `HubCallback` emits `SettlementReported`.
5. `HubRSC` picks up `SettlementReported`, validates/deduplicates, and enqueues pending settlement state.
6. When `LiquidityHub` emits `LiquidityAvailable(...)`, `HubRSC` scans the queue with bounded limits, verifies entries, and dispatches a batch callback to the receiver, which calls `LiquidityHub.processSettlementFor(...)` to process settlement and credit the recipient.

## Reactive Network Context

This project is built for the Reactive Network execution model:

- Origin-chain events are observed via subscriptions.
- Reactive contracts execute `react()` logic in ReactVM.
- Cross-chain actions are emitted as callbacks and executed on destination chains.

In this repo, the goal is automated settlement processing using a hub-spoke pattern:

- `SpokeRSC` reacts to recipient-filtered queue events.
- `HubCallback` receives spoke callbacks and emits normalized events.
- `HubRSC` aggregates pending settlements and dispatches bounded settlement batches.

## File Structure (src)

`src/` contains the core reactive contracts:

- `HubCallback.sol`  
  Receives updates from Spoke contracts, checks the recipient->spoke mapping, and emits `SettlementReported` so HubRSC can process it.

- `HubRSC.sol`  
  Main coordinator contract. Receives settlement report events from `HubCallback` and liquidity availability events from the protocol contract, then dispatches bounded settlement batches.

- `SpokeRSC.sol`  
  One contract per recipient. Listens for that recipient's `SettlementQueued` events and forwards the details to `HubCallback`.


## Testing

### End-to-end tests

Important:
- To run integration tests, fund the deployer wallet with at least `0.01` Sepolia ETH and `5` kREACT.
- You can get testnet REACT (kREACT) here: https://dev.reactive.network/education/use-cases/remix-ide-demo

Make sure your env vars are up to date, then run:

```bash
just e2e
```

### Unit tests

Run:

```bash
forge test
```

## Deployment

### Env Vars

Put these in `.env` (or pass inline per command):

```bash
PRIVATE_KEY=
# optional override used by fund-contract helper
REACTIVE_PRIVATE_KEY=
BROADCAST=true

REACTIVE_RPC=
PROTOCOL_RPC=

PROTOCOL_CALLBACK_PROXY=
REACTIVE_CALLBACK_PROXY=

PROTOCOL_CHAIN_ID=
REACTIVE_CHAIN_ID=

# used by WhitelistSpokeForRecipient.s.sol
RVM_ID=
```


### Steps to deploy

#### 1) Deploy mock LiquidityHub (protocol chain)

Specific env vars for this command:
- None (uses only the global env vars above).

Example:
```bash
just deploy-mock-liquidity-hub
```

#### 2) Deploy BatchProcessSettlement receiver (protocol chain)

Specific env vars for this command:
- `LIQUIDITY_HUB` (deployed LiquidityHub address on protocol chain)
- `RECEIVER_PREFUND_WEI` (optional)

Example:
```bash
just deploy-receiver
```

Optional override example:
```bash
RECEIVER_PREFUND_WEI=120000000000000000 just deploy-receiver
```

#### 3) Deploy HubCallback + HubRSC (reactive stack)

Specific env vars for this command:
- `LIQUIDITY_HUB` (protocol LiquidityHub address)
- `BATCH_RECEIVER` (deployed receiver address)
- `HUB_CALLBACK_VALUE` (optional)
- `HUB_RSC_VALUE` (optional)

Example:
```bash
just deploy-hub
```

Optional override example:
```bash
HUB_CALLBACK_VALUE=0.1ether HUB_RSC_VALUE=1ether just deploy-hub
```

#### 4) Deploy SpokeRSC (per recipient)

Specific env vars for this command:
- `LIQUIDITY_HUB` (protocol LiquidityHub address)
- `HUB_CALLBACK` (deployed HubCallback address)
- `RECIPIENT` (optional if passed as command argument)
- `SPOKE_VALUE` (optional)

Example:
```bash
just deploy-spoke 0xb797466544DeB18F1e19185e85400A26FC5d3E95
```

Optional override example:
```bash
SPOKE_VALUE=1ether just deploy-spoke 0xb797466544DeB18F1e19185e85400A26FC5d3E95
```

#### 5) Whitelist spoke for recipient on HubCallback

Specific env vars for this command:
- `HUB_CALLBACK` (deployed HubCallback address)
- `RECIPIENT`
- `RVM_ID` (spoke identifier/address to set for recipient)

Example:
```bash
just whitelistspokeforrecipient
```

This command calls:

```solidity
setSpokeForRecipient(recipient, spoke)
```

#### 6) Run end-to-end deployment + integration

Specific env vars for this command:
- `DEBUG` (optional): More logs are provided when the debug parameter is set to true

Example:
```bash
DEBUG=true just e2e
```


### Fund a reactive contract

Fund a callback contract and the reactive contract on the Reactive Network, the system contract and callback proxy share this fixed address:

`0x0000000000000000000000000000000000fffFfF`

Use the helper script to fund a contract:

```bash
just fund-contract <CONTRACT_ADDR> <AMOUNT_WEI>
```

Example:

```bash
just fund-contract 0x1234567890abcdef1234567890abcdef12345678 100000000000000000
```

This calls:

```bash
cast send --rpc-url $REACTIVE_RPC --private-key $REACTIVE_PRIVATE_KEY <SYSTEM_CONTRACT> "depositTo(address)" <CONTRACT_ADDR> --value <AMOUNT_WEI>
```