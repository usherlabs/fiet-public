I'll locate the v4-core pool state struct and tick crossing logic to show that `pools[poolId].liquidity` equals current active (in-range) liquidity, not the sum of all positions, and cite the exact lines. Then I'll explain succinctly.

[2 tools called]

### Why “pool liquidity” here means current in‑range liquidity

- In Uniswap v4, `pools[poolId].liquidity` is maintained as the liquidity currently active at the current tick (i.e., in‑range), not a sum of all positions ever added.
- It is only increased/decreased when a position’s range straddles the current tick, and it is updated on tick crosses during swaps.

Code references:

```218:227:/Users/ryansoury/dev/fiet/protocol/solidity/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol
            } else if (tick < tickUpper) {
                delta = toBalanceDelta(
                    SqrtPriceMath.getAmount0Delta(sqrtPriceX96, TickMath.getSqrtPriceAtTick(tickUpper), liquidityDelta)
                        .toInt128(),
                    SqrtPriceMath.getAmount1Delta(TickMath.getSqrtPriceAtTick(tickLower), sqrtPriceX96, liquidityDelta)
                        .toInt128()
                );

                self.liquidity = LiquidityMath.addDelta(self.liquidity, liquidityDelta);
            } else {
```

```242:248:/Users/ryansoury/dev/fiet/protocol/solidity/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol
        struct SwapResult {
            // the current sqrt(price)
            uint160 sqrtPriceX96;
            // the tick associated with the current price
            int24 tick;
            // the current liquidity in range
            uint128 liquidity;
        }
```

```420:443:/Users/ryansoury/dev/fiet/protocol/solidity/lib/v4-periphery/lib/v4-core/src/libraries/Pool.sol
                    int128 liquidityNet =
                        Pool.crossTick(self, step.tickNext, feeGrowthGlobal0X128, feeGrowthGlobal1X128);
                    // if we're moving leftward, we interpret liquidityNet as the opposite sign
                    // safe because liquidityNet cannot be type(int128).min
                    unchecked {
                        if (zeroForOne) liquidityNet = -liquidityNet;
                    }

                    result.liquidity = LiquidityMath.addDelta(result.liquidity, liquidityNet);
                }
            ...
        // update liquidity if it changed
        if (self.liquidity != result.liquidity) self.liquidity = result.liquidity;
```

And `StateLibrary.getLiquidity` simply reads that field:

```176:190:/Users/ryansoury/dev/fiet/protocol/solidity/lib/v4-periphery/lib/v4-core/src/libraries/StateLibrary.sol
    /**
     * @notice Retrieves total the liquidity of a pool.
     * @dev Corresponds to pools[poolId].liquidity
     */
    function getLiquidity(IPoolManager manager, PoolId poolId) internal view returns (uint128 liquidity) {
        // slot key of Pool.State value: `pools[poolId]`
        bytes32 stateSlot = _getPoolStateSlot(poolId);
        // Pool.State: `uint128 liquidity`
        bytes32 slot = bytes32(uint256(stateSlot) + LIQUIDITY_OFFSET);
        liquidity = uint128(uint256(manager.extsload(slot)));
    }
```

So, although the comment says “total liquidity of a pool”, that variable is the canonical “current in‑range liquidity”. That’s why using `getLiquidity(corePoolId)` already gives you the correct denominator for pro‑rata allocation across active positions.

- If you want to exclude Direct LPs and consider only MM‑managed positions, then yes, you’d move this to `MMPositionManager` and maintain a separate “active MM liquidity” tally; otherwise, the current approach is accurate.

- I verified the core behaviour directly in `Pool.sol` above.

- In short: your denominator is already the in‑range total; you don’t need to move it unless you want MM‑only weighting.

- Summary:
  - `pools[poolId].liquidity` tracks in‑range liquidity at current tick.
  - It updates only when positions are in range and on tick crosses.
  - `StateLibrary.getLiquidity` returns that live in‑range value.
