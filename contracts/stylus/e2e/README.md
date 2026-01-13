# E2E Setup & Testing for Kernel 7702 Smart Wallet with Intent Policy

This package is intended to be run with **Bun**.

## Environment

Create a `.env` file with:

- `ZERODEV_RPC`
- `OWNER_PRIVATE_KEY`
- `INTENT_POLICY_ADDRESS`
- `STATE_VIEW_ADDRESS`
- `VTS_ORCHESTRATOR_ADDRESS`
- `LIQUIDITY_HUB_ADDRESS`
- `MM_POSITION_MANAGER_ADDRESS`
- `POSITION_MANAGER_ADDRESS`

## Install

```bash
bun install
```

## Test

```bash
bun test
```

## Typecheck

```bash
bun run lint
```
