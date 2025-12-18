# Value-to-Signal Model — Revision Research — @Wednesday 17:47

# $VTS_{required}$

Your reasoning holds merit and is not incorrect. The current VTS_required, as defined in the Fiet Technical Specification (page 23), establishes a baseline by calculating the proportion of committed liquidity needed to cover outflows over a fixed time window T. This supports dynamic adjustments to meet immediate swap demands, but it does not inherently account for delayed redemptions of LCCs issued during earlier swaps. If traders hold LCCs beyond T and redeem them later—particularly in the Proxy Pool scenario where the protocol aims to deliver native tokens but falls back to LCC issuance when settled liquidity is insufficient—the model could understate settlement requirements. At that point, if market demand has waned and market makers have withdrawn excess settled liquidity (S) to align with a lowered VTS_target, a deficit may arise, potentially triggering Settlement Guarantors or disrupting redemptions.

Shifting VTS_required to a deficit-based rate, derived from outstanding LCCs (total minted minus redeemed per token) and apportioned by each position's historical contribution to outflows (e.g., cumulative ΔO_A(r) relative to pool-wide totals), would provide a more comprehensive, retroactive baseline. This ensures coverage for all pending claims, aligning with the protocol's on-demand settlement mechanics (Specification, page 2) and the new truths where traders may defer unwraps. However, this approach could reduce dynamism if not paired with mechanisms like decay terms or resets, as cumulative calculations might lead to persistently high rates even in low-demand periods. Overall, your proposal addresses a valid limitation in the time-bound model for scenarios with variable redemption timing.

---

In this revised approach, the pool-wide deficit for a token A could be tracked as the net outstanding LCCs (minted minus redeemed), denoted as Deficit_A. Each position r's share of this deficit, Deficit_A(r), would be apportioned based on its historical contribution to outflows, such as the cumulative proportion of ΔO_A(r) relative to the total outflows across all positions during the periods when LCCs were issued. 

The $VTS_{required}(r, A)$ could then be formulated as:

$$
VTS_{required}(r, A) = min(1, \frac{D_A(r)}{C_A(r)})
$$

Where C_A(r) is the committed liquidity for token A in position r. As settlements fulfil the queue (i.e., market makers deposit native tokens to enable unwraps), Deficit_A(r) decreases, allowing the rate to decay naturally. This decay would occur proportionally as redemptions are processed, preventing persistent high rates during extended low-demand periods while still covering all pending claims.

---

The inclusion of Settlement Guarantors, as detailed in the Fiet Technical Specification (page 2), offers a built-in mechanism to address prolonged settlement delays. When market makers fail to fulfil their obligations in a timely manner, Guarantors intervene by settling on their behalf, which in turn claims the corresponding liquidity provider positions. This process naturally reduces the Deficit_A(r) for the affected positions, as the outstanding LCCs are redeemed through the Guarantor's action, thereby contributing to the decay of the position-specific VTS_required rate without requiring additional explicit decay factors in all scenarios.

To integrate this into the revised model, we can formalise the update to Deficit_A(r) as follows: Upon a Guarantor intervention for a specific queue segment tied to position r and token A, Deficit_A(r) is decremented by the settled amount, leading to an immediate recalculation of $VTS_{required}(r, A) = min(1, D_A(r) / C_A(r))$. This ensures the rate reflects only remaining unsettled commitments, promoting dynamism even in cases of infrequent voluntary redemptions by market makers.

As outlined in the Fiet Technical Specification (page 2), these participants step in to fulfil settlement obligations when market makers fail to do so, claiming the associated liquidity provider positions as compensation. This mechanism mirrors the essential function of liquidators in lending protocols, ensuring reliability and incentivising timely interventions through the seizure of collateralised assets, including those tied to the base VTS rate.

Given this inherent safeguard, we can proceed without introducing supplementary decay factors or resets for Deficit_A(r). The Guarantors' interventions will serve as the primary means to address persistent deficits, naturally reducing the outstanding queue as they redeem LCCs on behalf of delinquent market makers. This aligns with the protocol's risk management principles, maintaining capital efficiency while upholding trader protections.

With this established, the revised VTS_required can rely on the queue dynamics and Guarantor backstop for decay. For instance, upon an intervention, Deficit_A(r) would be updated by subtracting the settled amount, directly lowering $VTS_{required}(r, A) = min(1, D_A(r) / C_A(r))$. In low-activity markets, where voluntary settlements may lag, the incentive structure ensures Guarantors remain vigilant, preventing indefinite accumulation.

### Implementation

1. Read from settlement queue to determine full total Deficit (D)
    1. Pool-wide Deficit_A (for token A in a market) = Sum of all queued amounts for that market across recipients (outstanding LCC awaiting redemption).
    2. maintain a running total: Add `mapping(bytes32 => uint256) public totalOutstanding`; incremented in `*addToSettlementQueue`, decremented in `_processSettlementQueue`.*
    3. Emit events on queue changes (e.g., `event QueueUpdated(bytes32 marketId, uint256 newTotal)`) for potential off-chain monitoring.
2. Apportion `Deficit_A` to each position that was responsible for the the deficit (ie. acquisition of LCC (outflow), and then unwrap (queue/deficit)).
    1. ~~Or would it be wiser to simply derive `VTS_required` based on the outflow `\delta O (r)` ?~~
    2. We return to the **ring buffer** mechanic for cross-transaction historical backtracking with exact precision — storing per swap events.
        1. Alternative to **ring buffer** is off-chain oracle/function for processing event logs.
            1. RPCs -> Prover -> Canister -> Prover -> Chain — 4c + compute
            2. RPCs -> Chainlink Function -> Chain — 3c + compute *— requires public RPC endpoints*
                1. [https://docs.chain.link/chainlink-functions/resources/service-limits](https://docs.chain.link/chainlink-functions/resources/service-limits)
        2. **Stylus for Ring Buffer**
            1. Load a larger ring buffer and rely on Stylus for compute over events.
        3. **Hybrid**
            1. Expect 2000 swaps in 12 hours — buffer is cleared on settlement, with average time window of an hour, meaning a buffer of 100 -> 512 for safety could work.
                1. 512 buffer = 100k gas (estimated) (however, Stylus offers 43% gas of Solidity based on Read + Compute), therefore Stylus could offer 2048.
            2. Fall back to approximate aggregates over an epoch
            3. Fall back further to approximate only in-range liquidity.
            4. We can include an Oracle as well… However, adds more latency, infra overhead, and cost…
                1. Forces that `VTS_required` be handled off-chain for view function, and only called on-chain for seizure/withdraw
                2. May want to maintain a cache for results — eg. last `VTS_required(r)`
                3. **I feel as there's more room for error with this approach.** We can launch with fully-on-chain approach, and optimise to include Oracles based on post-production feedback.
                4. We must make this mechanic for calculation modular… ie. A Stylus `VTSCalculator` is native to this modularity.
                5. Could be that we flush the buffer as a leaf in a map root hashes. We will not need to zkTLS many RPC endpoints if we verify Merkle Tree root hash via reconstruction on verifiable oracle compute env.

# $VTS_{target}$

$$
\text{VTS}_{\text{required}}(r, A) = \min\left(1, \frac{D_A(r)}{C_A(r)}\right)
$$

$$
\text{VTS}_{\text{excess}}(r_i, A) = \max\left(0, \frac{S_A(r_i) - D_A(r_i)}{C_A(r_i)}\right) 
$$

$$
E_A(r_i) = \min\left( S_A(r_i) - D_A(r_i), \Delta O_A(r_i) \right)
$$

$$
U_A(r_i) = \min\left(1, \frac{E_A(r_i)}{\max(\epsilon, S_A(r_i) - D_A(r_i))}\right)
$$

---

$$
\text{VTS}_{\text{target}}(r_i, A) = \text{VTS}_{\text{required}}(r_i, A) + \left(U_A \cdot \text{VTS}_{\text{excess},A} \right) \cdot w(r_i) 
$$

where: 

$$
w(r_i) = \frac{L(r_i)}{\sum_{\text{in-range } r'} L(r')}
$$

$U_A$ is an aggregate of $U_A(r_i)$

$$
 \sum_{r_i \text{ in-range}} U_A(r_i) \cdot w(r_i)
$$

or 

$$
U_A = min(1, \frac{min(S_A - D_A, \Delta O_A)}{max(\epsilon, S_A - D_A)})
$$

$VTS_{excess,A}$ is an aggregate of $VTS_{excess}(r, A)$

$$
\text{VTS}_{\text{excess},A} = \sum_{r_i \text{ in-range}} \text{VTS}_{\text{excess}}(r_i, A) \cdot w(r_i)
$$

or 

$$
VTS_{excess, A} = max(0, \frac{S_A - D_A}{C_A})
$$

where $S, D,C$ are respective aggregates over token $A$

### Formalised VTS_target

$$
\text{VTS}_{\text{target}}(r_i, A) = \text{VTS}_{\text{required}}(r_i, A) + \left( U_A \cdot \text{VTS}_{\text{excess},A} \right) \cdot w(r_i) 
$$

Where:

- $r_i$ is an in-range position $r$, such that ( $i_l \leq i_c < i_u$ )
- $\text{VTS}_{\text{required}}$ is the baseline settlement rate for position $r_i$ and token $A$, ensuring coverage of outstanding LCC deficits.
- $U_A$ is the pool-wide utilisation rate for excess settled liquidity of token A, measured over the time window [t−T,t], where ϵ is a small constant to avoid division by zero.
    
    $$
    U_A = \min\left(1, \frac{\min(S_A - D_A, \Delta O_A)}{\max(\epsilon, S_A - D_A)}\right)
    $$
    
- $VTS_{excess, A}$ is the pool-wide excess settlement rate for token A.
    
    $$
    \text{VTS}_{\text{excess},A} = \max\left(0, \frac{S_A - D_A}{C_A}\right)
    $$
    
- $w(r_i)$ is the liquidity weight of position ri, apportioning the aggregate excess term proportionally.
    
    $$
    w(r_i) = \frac{L(r_i)}{\sum_{\text{in-range } r'} L(r')}
    $$
    
- $S_A$ is the total settled liquidity for token A across in-range positions.
    
    $$
    S_A = \sum_{r_i} S_A(r_i)
    $$
    
- $D_A$ is the total outstanding LCC deficit for token A across in-range positions.
    
    $$
    D_A = \sum_{r_i} D_A(r_i)
    $$
    
- $C_A$ is the total committed liquidity for token A across in-range positions.
    
    $$
    C_A = \sum_{r_i} C_A(r_i)
    $$
    
- $\Delta O_A$ is the pool-wide outflows for token A over $[t−T,t]$:
    
    $$
    \Delta O_0 = \sum_{\text{swaps in } [t - T, t]} |\Delta x|, \quad \Delta O_1 = \sum_{\text{swaps in } [t - T, t]} |\Delta y|
    $$
    

For out-of-range positions $r$, $VTS_{target}$ falls back to $VTS_{required}$ if $D_A(r) > 0$, or $VTS_{base},A$ otherwise.

## Synthetic data analysis

Let’s simulate the behaviour of $VTS_{target}$ in the Value-to-Signal model. Here, we test theoretical assumptions without relying on real-time market conditions. The simulation assumes a Core Pool with four in-range positions facilitated by market makers, each with identical initial committed liquidity ($C_A(r_i)$ = 1000), liquidity parameter ($L(r_i)$ = 10), and deficit ($D_A(r_i)$ = 200), leading to equal weights ($w(r_i)$ = 0.25). Token A is `token0` for simplicity, with a time window $T$ of one hour and low initial outflows ($ΔO_A$  = 100).

The scenarios progress as follows:

- **Scenario 1 (Initial Baseline)**: No excess settlements; settled liquidity matches deficits ($S_A(r_i)$ = 200 each). Utilisation $U_A$ is 0, as there is no excess to consume.
- **Scenario 2 (One Market Maker Settles Excess)**: The market maker for Position 1 settles an additional 500 in native tokens, creating pool-wide excess ($S_A - D_A = 500$). Outflows remain low, resulting in partial utilisation ($U_A = 0.2$).
- **Scenario 3 (High Demand with Full Utilisation)**: Outflows increase to 600, fully consuming the excess and driving $U_A$ to 1.

### Simulation Results

**Scenario 1: Initial Baseline**

Pool-wide U_A: 0.0, VTS_excess_A: 0

---

**Scenario 2: One Market Maker Settles Excess**

Pool-wide U_A: 0.2, VTS_excess_A: 0.125

---

**Scenario 3: High Demand, Full Utilisation**

Pool-wide U_A: 1, VTS_excess_A: 0.125

---

### Analysis

In Scenario 2, when a single market maker settles excess liquidity, the pool-wide excess rate ($VTS_{excess,A}$ = 0.125) emerges, and partial utilisation ($U_A$ = 0.2) leads to a modest increase in $VTS_{target}$ across all in-range positions (by 0.00625 each). In Scenario 3, with higher demand driving utilisation to 1, $VTS_{target}$ rises further (by 0.03125 each), demonstrating how successful excess settlements by one savvy market maker can elevate the target rate for others, encouraging aligned behaviour to facilitate deeper liquidity and reduce fallback to LCC issuance in the Proxy Pool.

This behaviour promotes capital efficiency, as market makers can respond to proven demand signals without the protocol imposing fixed projections. If positions have unequal liquidity parameters, the influence of the savvy market maker would scale with their weight, amplifying the effect. This means MMs with a greater in-range position are responsible for settling if proven appropriately by those with smaller positions. This ensures the goals of the protocol in delivering good UX to traders is balanced with those of the MMs.