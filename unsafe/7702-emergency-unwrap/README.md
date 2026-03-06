# 7702 Emergency Unwrap (Unsafe)

This folder contains an emergency-only flow for unwrapping LCC balances on networks where:

- `LiquidityHub.unwrap(...)` may pull market liquidity, and
- that path fails with `ManagerLocked()` unless executed inside `PoolManager.unlock(...)`.

The approach uses EIP-7702 so the **EOA itself** can temporarily execute unlock-callback logic in a single transaction.

## Why this exists

`PoolManager` delta-accounting operations require an active unlock session.  
For affected deployments, direct `LiquidityHub.unwrap` from an EOA can revert with:

- `ManagerLocked()`

This project performs:

1. `EOA` transaction (with `--auth <impl>`)
2. delegated call to `unlockAndUnwrap(...)`
3. `PoolManager.unlock(...)`
4. callback to `unlockCallback(...)`
5. `LiquidityHub.unwrap(...)` inside the unlock window

## Layout

- `src/Eoa7702UnlockUnwrap.sol`
- `script/Deploy7702Impl.s.sol`
- `script/Run7702Unwrap.s.sol`
- `script/TeardownDelegation.s.sol`
- `justfile`

## Required environment variables

- `ARB_MAINNET_RPC_URL`
- `LP_PRIVATE_KEY`
- `EOA` (LCC holder)
- `POOL_MANAGER`
- `LIQUIDITY_HUB`
- `LCC_ADDRESS`
- `IMPL` (deployed implementation address; used by `unwrap`)

`LP_PRIVATE_KEY` must derive to the same address as `EOA`. The execution recipes fail fast if they do not match.

Optional:

- `AMOUNT` (default `0` means unwrap full `balanceOf(EOA)`)
- `PRIVATE_KEY` or `DEPLOYER_PRIVATE_KEY` for `setup`
- `NEW_IMPL` for teardown redelegation
- `CLEAR_DELEGATION=1` to clear 7702 delegation and restore a plain EOA state
- `TEARDOWN_GAS_LIMIT` (default `100000`) for clients that under-estimate 7702 intrinsic gas

## Recipes

Run from this folder:

```bash
just help
just setup
just preview-unwrap
just unwrap
just preview-teardown
just teardown
just delegation-status
```

## Suggested dry run before mainnet

1. Start a fork:

```bash
ANVIL_FORK_URL=http://localhost:8545
```

1. Execute the unwrap path against the fork:

```bash
just fork-dry-run
```

This performs the 7702-authorised call on the fork and checks that `LCC_ADDRESS.balanceOf(EOA)` decreases afterwards.

1. On mainnet, start with a small `AMOUNT` before full unwrap.

## Safety notes

- This is intentionally in an `unsafe/` folder and should be treated as incident tooling.
- Keep the delegated implementation minimal.
- Re-delegate away from the emergency implementation immediately after success (`just teardown`).
- Use `just delegation-status` before and after teardown to confirm whether the wallet still exposes a 7702 delegation marker.
- `just preview-unwrap` remains a calldata preview only. Use `just fork-dry-run` for execution validation.
- `CLEAR_DELEGATION=1` uses `--auth 0x0000000000000000000000000000000000000000`, which EIP-7702 defines as clearing the delegated code and resetting the account to empty code.
