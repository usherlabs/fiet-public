[Informational] Unpath-bound market-only cancel on BOUND_EXEMPT ProxyHook causes Hub direct-vs-market backing misclassification

# Description

ProxyHook cancels LCC during proxy swaps by calling [LiquidityHub.cancel](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L684-L696) from a [BOUND_EXEMPT](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/MarketFactory.sol#L233-L242) address without binding the burn to the swap inflow. Because EXEMPT holders can be [pre-seeded with direct (wrapped) LCC](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LCC.sol#L214-L239) and [LiquidityHub.cancel](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L684-L696) always burns as market, cancel can destroy unrelated direct-backed tokens as if they were market-derived, leaving Hub [directSupply/direct reserves](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L476-L485) overstated while freshly received swap LCC may remain on the hook.

During proxy swaps, ProxyHook uses [LiquidityHub.cancel(lcc, address(this), amountToCancel)](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L684-L696) to burn output LCC. The hook is [BOUND_EXEMPT](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/MarketFactory.sol#L233-L242), so anyone can pre-seed it via [Non-protocol → Protocol transfers](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LCC.sol#L214-L239). [LiquidityHub.cancel](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L684-L696) always burns (direct=0, market=amount), and [LCC.burn on EXEMPT holders skips bucket bookkeeping](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LCC.sol#L175-L181). Because the burn is not tied to the exact PoolManager→ProxyHook transfer for that swap, ERC20 fungibility allows pre-seeded direct (wrapped) LCC to be burned "as market" without decrementing Hub directSupply or direct reserves. The freshly received swap LCC can remain on the hook and be routed later (e.g., [deficit leg to external recipients](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L734-L748)), leading to a persistent misclassification of Hub backing (direct vs. market). This matches neither the intended behavior nor the in-code intent comment but does not directly enable theft or DoS; it is an accounting integrity issue.

# Severity

**Impact Explanation:** [Low] The issue causes accounting integrity/misclassification (direct vs market backing) without direct principal loss, theft, or core protocol DoS.

**Likelihood Explanation:** [Low] Exploitation requires attackers to pre-seed and burn their own tokens with no direct profit (griefing), making rational exploitation unlikely despite low operational barriers.

# Exploitation

## Exploitation Scenarios:

### Scenario 1.
Full cancel (no deficit): Attacker pre-seeds ProxyHook with W direct LCC_out, then performs a proxy swap producing amountOut LCC_out where available underlying >= amountOut. ProxyHook cancels amountOut via [LiquidityHub.cancel](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L684-L696), which may effectively burn pre-seeded direct as market due to EXEMPT status and fungibility. Hub directSupply/direct reserves remain unchanged, misclassifying backing.
#### Preconditions / Assumptions
- (a). ProxyHook is BOUND_EXEMPT in the market namespace
- (b). LCC allows Non-protocol → Protocol transfers
- (c). CanonicalVault has sufficient available underlying to fully cover the swap output (no deficit)
- (d). Attacker can wrap LCC_out and transfer to ProxyHook (standard ERC20 behavior)

### Scenario 2.
Partial cancel with deficit: Attacker pre-seeds ProxyHook with W direct LCC_out, then performs a proxy swap producing amountOut LCC_out where available < amountOut. ProxyHook cancels 'available' (potentially consuming pre-seeded direct as market) and transfers the deficit LCC_out to a recipient, [queuing settlement](https://github.com/usherlabs/fiet-protocol/blob/fae0d20fe33523515109a523f8c048cd6765ecdb/contracts/evm/src/LiquidityHub.sol#L734-L748). Hub direct accounting remains overstated; minted remainder is routed to the recipient as market-derived.
#### Preconditions / Assumptions
- (a). ProxyHook is BOUND_EXEMPT in the market namespace
- (b). LCC allows Non-protocol → Protocol transfers
- (c). CanonicalVault available underlying is less than the swap output (deficit occurs)
- (d). A valid deficit recipient can be resolved by ProxyHook
- (e). Attacker can wrap LCC_out and transfer to ProxyHook (standard ERC20 behavior)

### Scenario 3.
Repeated misclassification: The attacker repeats pre-seeding and swap-cancel cycles, each time allowing pre-seeded direct LCC to be burned as market without reducing Hub directSupply/direct reserves, gradually increasing divergence between Hub accounting and actual token supply/buckets.
#### Preconditions / Assumptions
- (a). ProxyHook is BOUND_EXEMPT in the market namespace
- (b). LCC allows Non-protocol → Protocol transfers
- (c). Attacker can repeatedly wrap and transfer LCC_out to ProxyHook (standard ERC20 behavior)
- (d). Market conditions permit repeated swaps and cancels

---

## Resolution status (2026-04-23)

**Resolved** — codified exempt-held LCC as semantically market-derived in `balancesOf`, documented as **LCC-EXEMPT-01** in `contracts/evm/INVARIANTS.md`, and aligned Hub/ProxyHook documentation. See `agents/audit-resolutions/2026-04-23-plus-35_15_exempt-held-lcc-consistency-resolution.md`.
