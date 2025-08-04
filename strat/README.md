# End-to-End Test Guide

This guide describes how to perform an end-to-end (E2E) test of the Fiet protocol, focusing on creating a market, adding liquidity, running the rebalancer, and triggering a rebalance through swaps.

## Prerequisites

- Ensure you have Forge, Anvil, and Cargo installed.
- Set environment variables: PRIVATE_KEY (deployer), LP_PRIVATE_KEY (liquidity provider), and optionally RPC_URL to local anvil fork RPC endpoint, and NETWORK (default: arbitrum_sepolia).
- The test assumes a forked network for local testing.

## Steps

1. **Setup Anvil Fork**
   Navigate to the `../solidity` directory and run:

   ```
   make fork
   ```

   This starts Anvil forking the specified network (e.g., arbitrum_sepolia). Keep this running in a separate terminal.

2. **Create the Dev Market**
   In the `../solidity` directory, run:

   ```
   make dev
   ```

   This deploys and initialises a new market pool between mock currencies. Note the pool details from the output.

3. **Add Liquidity**
   In the `../solidity` directory, run:

   ```
   make add-liquidity
   ```

   This adds liquidity to the core pool and mints a position. Look for the log line `Position TokenId: <TOKEN_ID>` in the output to get the NFT position token ID. You can customise amounts via env vars like UA_0_AMOUNT, UA_1_AMOUNT, RANGE_WIDTH.

4. **Run the Rebalancer**
   In the `strat` directory, run:

   ```
   cargo run -- --token-id <TOKEN_ID> --network arbitrum_sepolia --threshold 10 --range-width 100 --rpc-url http://localhost:8545
   ```

   - `--token-id`: The position ID from step 3.
   - `--threshold`: Ticks away from position bounds to trigger rebalance (default 10).
   - `--range-width`: Width of new position in ticks (default 100).
   - The rebalancer will poll every 60 seconds (adjust via --interval) and log current tick, position bounds, diffs, etc.

5. **Perform Swaps to Trigger Rebalance**
   In the `../solidity` directory, run swaps to shift the price (tick) sufficiently:

   ```
   SWAP_TYPE=0 AMOUNT=10000000000000000000 make swap  # Example: Exact input Token0 -> Token1, 10 tokens (18 decimals)
   ```

   - `SWAP_TYPE`: 0-5 for different swap types/directions (0: exactIn 0->1, 2: exactIn 1->0, etc.).
   - `AMOUNT`: Swap amount (e.g., 10e18 for 10 tokens).
   - Run multiple times or increase AMOUNT to shift the tick beyond the threshold (e.g., >10 ticks from position bounds).
   - The swap script logs before/after tick, price, liquidity deltas, and uaSupply changes in LCC tokens.
   - To shift the tick sufficiently, monitor the `tick delta` in swap logs. The pool's tick spacing is typically 60; you need to cross enough liquidity to move > threshold ticks.

## Expected Outcomes and Verification

- **Rebalancer Logs**: Watch for logs like:
  - `Current tick: X`
  - `Position ticks: lower=Y, upper=Z`
  - `Diffs: lower=A, upper=B`
  - If within bounds: `Position within bounds.`
  - When triggered: `Rebalancing triggered. Threshold: 10`
  - Details: `Current liquidity: L`, `Current sqrt_price_x96: P`, `New ticks: lower=M, upper=N`, `Old amounts: amount0=A0, amount1=A1`, `New liquidity: NL`
  - After tx: `Rebalance completed. New token ID: NEW_ID`
- **Verification**:
  - Ensure the new position is centred around the current tick with the specified range width.
  - Check that rebalanced amounts (A0, A1) match expectations with minimal loss (due to fees/rounding).
  - Verify via swap logs that uaSupply in LCC tokens adjusts correctly during swaps.
  - The rebalancer should only trigger when tick diffs > threshold, and update to new token ID.

## Notes

- Swap size required depends on pool liquidity; start small and increase to observe tick movement.
- For Australian grammar consistency, note that 'initialise' is used instead of 'initialize'.
- If issues, check anvil fork is running and env vars are set correctly.
