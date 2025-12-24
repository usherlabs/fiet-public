## Protocol invariants (tests must respect)

### Coverage bound: `incrementCoverage()` cannot exceed realised amounts

In this protocol, `incrementCoverage()` is invoked via **LCC unwrap** (`contracts/evm/src/LCC.sol` → LiquidityHub/Factory → `VTSOrchestrator.incrementCoverage`).

Because unwrap is backed by **actual liquidity inside the AMM**, coverage is **economically bounded**:

- **Coverage cannot exceed what is actually available/realised in the system** for that token at that time.
- In particular, tests must **not** assume `incrementCoverage(amount)` can be arbitrarily larger than:
  - realised swap-driven outflows/deficits over the relevant interval, or
  - the amount made available via unwind/unwrap of liquidity.

Practical test implication:

- When writing DICE/CISE/CSI tests, ensure `incrementCoverage(...)` is sized to something plausibly obtainable from prior swaps/unwraps in the scenario (otherwise burns/bonuses may correctly be 0 and spend indices won’t advance).
