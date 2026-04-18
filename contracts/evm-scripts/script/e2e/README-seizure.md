# Seizure E2E (`Seizure.s.sol`)

Forge script exercising the **guarantor seizure** path (`SEIZE_POSITION` → `SETTLE_POSITION_FROM_DELTAS` → `TAKE` ×2) on freshly deployed markets, mirroring the behaviour covered in `contracts/evm/test/marketmaker/MMPositionActionsImpl.t.sol`.

## Environment

| Variable | Role |
|----------|------|
| `PRIVATE_KEY` | Deployer; also used as the swap **taker** for deficit-inducing swaps. |
| `LP_PRIVATE_KEY` | Market maker (commitment NFT **owner**). Must **not** equal the guarantor key. |
| `GUARANTOR_PRIVATE_KEY` | Optional. Third-party address that seizes positions. If unset, the script uses `LP2_PRIVATE_KEY`, then `LP3_PRIVATE_KEY` (same pattern as `MMCoverage.s.sol`). |
| `LP2_PRIVATE_KEY` / `LP3_PRIVATE_KEY` | Used as guarantor when `GUARANTOR_PRIVATE_KEY` is not set (try LP2 first, then LP3). |

Standard `NETWORK` / `rpc_url` / `FOUNDRY_PROFILE=deploy` expectations match other `script/e2e` scripts (see project `justfile`).

## Scenarios (single `run()`)

1. **Single position** — one MM range; stress swap; checkpoint; grace warp; guarantor seizure; liquidity decreases; guarantor receives LCC; **AUTH-01A** check (`NotApproved` on a follow-on `SETTLE` in a new batch).
2. **Two positions, same commit** — sequential seizures on indices `0` and `1`.
3. **Four positions** — three extra `MINT_POSITION` bands on the same NFT; `checkpoint(..., withCommitment=true)` on each index (commitment-deficit visibility); seizure on index `0`.

## Run

```bash
# from contracts/evm-scripts (see repo justfile for NETWORK/RPC)
just e2e-seizure
```

Equivalent:

```bash
FOUNDRY_PROFILE=deploy forge script script/e2e/Seizure.s.sol:SeizureE2E --rpc-url "$RPC_URL" -vvv
```

Helpers live in [`base/MME2EBase.sol`](./base/MME2EBase.sol) (`_openSeizeWindowForPosition`, `_guarantorSeizeSettleFromDeltasAndTake`, `_mintAdditionalMmPosition`, etc.).
