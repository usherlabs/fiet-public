# Live Reactive Demo

`scripts/live-demo.sh` is an operator harness for existing Fiet and Reactive deployments. It does not run, emulate, or integrate with a Maker service.

## Maker Dependency

The live demo depends on an external Maker system to provide one of:

- an active `COMMIT_ID` owned by `MM_PRIVATE_KEY`, with enough remaining validity for the run; or
- a fresh ABI-encoded `LIQUIDITY_SIGNAL_HEX` accepted by `MMPositionManager`.

`COMMIT_ID` is the preferred mode because it reuses a live Maker commitment. The create script reads `commitOf(COMMIT_ID)`, verifies the commitment owner matches `vm.addr(MM_PRIVATE_KEY)`, requires `expiresAt > block.timestamp + COMMIT_MIN_VALIDITY_SECONDS`, and mints the next position at `positionCount`.

Fresh-commit fallback remains available for manual testing by omitting `COMMIT_ID` and supplying `LIQUIDITY_SIGNAL_HEX`. The repository does not generate that signal in this harness.

## What The Harness Does

The harness:

- creates or extends one MM position;
- runs a recipient-signed exact-input swap intended to create queued settlement;
- settles the MM position for the required positive RFS amount;
- polls `LiquidityHub` and `HubRSC` state until queued settlement decreases.

The harness does not subscribe to Maker APIs, request proofs, refresh expiring commitments, rebalance Maker inventory, or manage Maker operational state. Those steps must happen outside this demo before the script is run.
