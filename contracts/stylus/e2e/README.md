# E2E Setup & Testing for Kernel 7702 Smart Wallet with Intent Policy

This package is intended to be run with **Bun**.

## Environment

You usually do **not** need to hand-write this file: `just e2e_write_env` (or `just bootstrap`) generates `contracts/stylus/e2e/.env` from the deployment manifests under `contracts/stylus/deployments/`.

If you _do_ want to create a `.env` manually, it must include:

- `RPC_URL`
- `OWNER_PRIVATE_KEY`
- `INTENT_POLICY_ADDRESS`
- `PERMISSION_ID` (**bytes32** encoding of Kernel `PermissionId` **bytes4**, left-aligned and zero-padded)
- `STATE_VIEW_ADDRESS`
- `VTS_ORCHESTRATOR_ADDRESS`
- `LIQUIDITY_HUB_ADDRESS`
- `MM_POSITION_MANAGER_ADDRESS`
- `POSITION_MANAGER_ADDRESS`
- `ENTRYPOINT_ADDRESS`
- `KERNEL_IMPLEMENTATION_ADDRESS` (7702 delegation target)
- `MULTICHAIN_SIGNER_ADDRESS`
- `CALL_POLICY_ADDRESS` (audited Kernel CallPolicy)

## Install

```bash
bun install
```

## Test

```bash
bun test
```

## Nitro devnet bootstrap (local)

From `protocol/contracts/stylus/`:

```bash
# 1) Start your Nitro node in a separate terminal, then set:
export RPC_URL="http://127.0.0.1:8547"
export CHAIN_ID="..."                 # your Nitro chain id
export PRIVATE_KEY="0x..."            # bytes32 for Foundry (EVM infra + Kernel deploy)
export OWNER_PRIVATE_KEY="0x..."      # used by the TS harness
export PERMISSION_ID="0x..."          # bytes32 encoding of bytes4 permission id (see below)

# 2) Bootstrap infra + Kernel + deploy policy + write e2e/.env
just bootstrap

# 3) Run tests
just e2e_test
```

## Arbitrum Sepolia (notes)

- `EntryPoint v0.7` is typically available at the canonical address; when deploying Kernel modules for Sepolia, set `USE_CANONICAL_ENTRYPOINT=true`.
- If you want separate deployment manifests per network, override the paths used by `just`:
  - `KERNEL_DEPLOYMENTS_PATH=deployments/kernel.sepolia.json`
  - `INFRA_DEPLOYMENTS_PATH=...` / `STYLUS_DEPLOYMENTS_PATH=...` as appropriate for your Sepolia setup

## Typecheck

```bash
bun run lint
```
