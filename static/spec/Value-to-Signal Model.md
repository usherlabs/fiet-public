# Value-to-Signal Model

The Value-to-Signal (VTS) model governs the settlement of Verified Reserve Liquidity (VRL) in the Fiet Protocol, ensuring that Market Makers (MMs) settle liquidity only when their specific liquidity positions are directly affected by swaps in an Automated Market Maker (AMM) pool. Each MM’s position, defined within a price range $[i_l, i_u]$ as in [Uniswap v4’s Concentrated Liquidity Market Maker (CLMM) framework](https://app.uniswap.org/whitepaper-v4.pdf), maintains its own VTS ratio, calculated as the proportion of settled liquidity $S$ to committed liquidity $C$ for each token in the position.

In a Fiet Market, MMs commit VRL, represented as Liquidity Commitment Certificates (LCCs), which encapsulate both settled on-chain liquidity and verified off-chain reserves. The VTS model uses pool-wide indicators, such as swap volume over a time window, to assess demand for each token (e.g., token0 or token1) within active positions. When a swap consumes liquidity from a position’s tick range, the VTS model calculates the required settlement to ensure traders receive the full outflow amount in native tokens, not LCCs. This approach significantly minimises capital lockup, aligns with Uniswap v4’s concentrated liquidity mechanics, and supports risk management by tying settlements to specific swap activity.

The VTS model underpins Fiet’s settlement and risk management mechanisms, enabling efficient liquidity provision while maintaining market integrity by accounting for verified liquidity across systems.

## What is the Value-to-Signal Ratio?

![Screenshot 2025-07-07 at 1.18.31 am.png](Value-to-Signal%20Model%202556d8286da580bc8ad8fa0d35f93485/Screenshot_2025-07-07_at_1.18.31_am.png)

The **current Value-to-Signal ratio** ($VTS_{current}$) measures the proportion of settled liquidity to committed liquidity for each token in an MM’s position within a Fiet Market. Each position, specified by a price range, maintains separate $VTS_{current}$ ratios for `token0` and `token1`, reflecting the liquidity dynamics of the AMM pool.

As MMs and traders interact with the market via LCCs, which encapsulate both settled and committed liquidity to mirror the pool’s effective liquidity, the $VTS_{current}$ for each token in a position adjusts based on market activity:

1. Deposits of a token into the AMM pool, such as trader swaps or MM settlements, increase the corresponding $VTS_{current}$.
2. Withdrawals of a token from the AMM pool, when excess liquidity is removed, decrease the corresponding $VTS_{current}$.

LCCs held outside the market do not affect $VTS_{current}$. The $VTS_{current}$ is enforced at the market level, ensuring that adjustment settled liquidity levels align with demand for each token.

## Target Rate

A Fiet Market monitors capitalisation needs through a **target Value-to-Signal ratio** ( $VTS_{\text{target}}$ ), which dynamically adjusts to ensure:

$$
VTS_{\text{current}} \geq VTS_{\text{target}}
$$

The ( $VTS_{\text{target}}$ ) represents the required settled liquidity level to meet market demand.

At market launch, ( $VTS_{\text{target}}$ ) is set to a default base rate per token

As market conditions evolve through participant interactions, ( $VTS_{\text{target}}$ ) increases with rising demand for a token and decreases over time as demand declines. AMM accounting allows MMs to settle liquidity for one token and withdraw excess liquidity from the other token (`token0` or `token1`), as demand for one inversely affects the other, following the AMM’s symmetrical price curve.

![As liquidity increases on the Y axis, liquidity decreases on the X axis, and vice versa.](Value-to-Signal%20Model%202556d8286da580bc8ad8fa0d35f93485/pricecurve-amm.png)

As liquidity increases on the Y axis, liquidity decreases on the X axis, and vice versa.

Each MM’s VTS obligation is proportional to their committed liquidity. Larger commitments incur greater settlement requirements but allow larger withdrawals when $VTS_{\text{current}} > VTS_{\text{target}}$.

New MMs joining an imbalanced market must settle liquidity to meet both tokens’ ( $VTS_{\text{target}}$ ), at minimum collateralising their position to the base ( $VTS_{\text{target}}$ ). Existing excess liquidity is proportionally allocated to new MMs upon commitment. If prior MMs withdraw this excess before new commitments, trader swaps cover ( $VTS_{\text{target}}$ ) requirements of the new MM. MMs can time commitments based on market conditions to optimise capital management.

## Base Target Rate

The **base Value-to-Signal target ratio** ( $VTS_{\text{base}}$ ) is a fixed rate set per token at market launch, akin to a loan-to-value ratio in lending protocols. The ( $VTS_{\text{base}}$ ) establishes a minimum $VTS_{target}$ rate and ensures collateralisation, seeding the market and incentivising Settlement Guarantors to intervene if MMs fail to settle.

The ( $VTS_{\text{base}}$ ) is determined to account for:

1. Settlement time for the token (e.g., blockchain block time or bank transfer duration).
2. Asset volatility.
3. Liquidation availability across exchanges and corridors.

For example:

- ckBTC, settling in 20 minutes, may have a ( $VTS_{\text{base}}$ ) of 5%, higher than USDC at 2%, which settles faster based on blockchain block time.
- Local stablecoins (e.g., AUD) have a ( $VTS_{\text{base}}$ ) of 3.5%, reflecting bank transfer times balanced by lower volatility.

MMs, typically high-frequency traders, are expected to prepare reserves for settlement requirements in advance.

## Atomic State Updates

Every trade in a Fiet Market triggers a state update for pool-wide **Market Demand Indicators**, measuring demand for `token0` and `token1` to determine the liquidity needed to meet that demand. The target VTS rate relies on these indicators for its calculation.

Each modification of liquidity position parameters in a Fiet Market, by MMs or Direct Liquidity Providers (Direct LPs), updates the state managing these positions. For MMs, the Fiet Protocol serves as a position management facility within DEXs, associating VTS rates with each position to ensure precise distribution of obligations based on liquidity utilised by traders. Direct LPs, using default interfaces to the CLMM, including third-party smart contracts, have their positions managed with the same processes as MM positions.

Fiet prioritises integration with hook-enabled AMMs. On the AMM pool addressing a market between the LCCs (e.g., lcc-USDT/lcc-ARB) is modified through a `CoreHook`. After each trade, the `afterSwap` hook updates the state based on the trade’s impact on liquidity demand, enabling real-time adjustments to $VTS_{\text{target}}$. The `CoreHook` inherits the underlying accounting model built into the CLMM, without hook-adjusted outflows or deltas. After liquidity position modifications, the `afterAddLiquidity` or `afterRemoveLiquidity` hooks are invoked, allowing atomic updates to the protocol’s position awareness and pre-calculation of committed liquidity for each token.

Every core pool has a corresponding proxy pool modified through the `ProxyHook`. This proxy pool establishes a market between native assets (e.g., USDT/ARB) underlying the LCCs, such that traders can engage this particular market without any awareness of the LCCs and Fiet functionality under the hood. In essence, this proxy pool functions as an order proxy to the core pool, abstracting the Fiet-specific logic. The `ProxyHook` proxies trade orders to the `CoreHook` by overriding the `beforeSwapReturnDelta`, piggybacking off the core pool's delta results. Additionally, if there is insufficient liquidity in the market to meet a trade size against the proxy pool, and no `recipient` address has been provided to receive the excess LCCs which cannot be unwrapped into native tokens until an MM settles, then swap simulation caps the trade size to meet what available underlying liquidity there is. The `ProxyHook` inherits functions of a `MarketVault`, logic associated with managing “in-market” liquidity which comprises liquidity deposited via trades, settlement by MMs, or deposit by Direct LPs.

For AMMs without hook functionality, Fiet uses a standardised integration pattern, employing a `SwapRouter` to track swap dynamics and a `PositionManagerProxy` to manage positions for MMs and Direct LPs. The protocol hooks into the LCC `transfer` method to track market interactions, restricting iterations to specific smart contracts. A check tuple distinguishes actions:

- Trade: One token’s `transfer` call has `to` as the `SwapRouter` (input token), while the other has `msg.sender` as the `SwapRouter` (output token).
- LP Deposit: Both tokens’ `transfer` calls specify to as the `PositionManagerProxy`.
- LP Withdrawal: Both tokens’ `transfer` calls have `msg.sender` as the `PositionManagerProxy`.

This approach ensures accurate tracking of market activity for the VTS model while maintaining compatibility with diverse AMM architectures.

## Fixed Commitments and Dynamic Effective Liquidity

When an MM commits a total liquidity value (e.g., $1,000,000 USD-denominated VRL) to a Fiet Market pairing two tokens (e.g., ETH and USDC), this total commitment $C(r)$ for position ( $r$ ) is cloned into $C_0(r)$ and $C_1(r)$, representing the **maximum potential amounts** of `token0` and `token1` across the position’s price range.

The total commitment is fixed in value denominated in a common base currency (e.g., USD):

$$
C(r) = \frac{1}{2} \left( V_0 \cdot C_0(r) + V_1 \cdot C_1(r) \right)
$$

where $V_0$ and $V_1$ are the current market values (in the base currency) of one unit of token0 and token1, respectively. For example, in a USDC/ETH market with USDC valued at 1 USD and ETH at 2,500 USD, $V_1 = 1$ (USDC) and $V_0 = 2500$ (ETH).

LCCs, minted during commitment and deposited into the AMM, encapsulate settled and committed liquidity, functioning as effective liquidity ( $x(r), \space y(r)$ ) of the position, as described in Uniswap v3 Whitepaper (Section 2). The sum of effective liquidity in USD, ( $x(r) + y(r)$ ), equals ( $C(r)$ ) for the position.

For example, at a price where 1 ETH (`token0`) equals 2000 USDC (`token1`), a $1,000,000 commitment will establish:

- $C_0(r)$ = 500 ETH, valued at $1,000,000.
- $C_1(r)$ = 1,000,000 USDC.

The LCCs allocated to the pool (e.g., $LCC_0(r$) = 250 ETH, $LCC_1(r)$ = 500,000 USDC) depend on the current tick and price range, adjusted by prior trade activity.

Due to the AMM’s price curve dynamics, the effective liquidity $x(r), y(r)$ cannot reach the maximum potential of both tokens simultaneously. If one token’s effective liquidity reaches $C_0(r)$ or $C_1(r)$, the other token’s liquidity is completely exhausted, rendering the position out-of-range. Post-commitment, $C_0(r)$ and $C_1(r)$ remain constant unless the MM decommits or adjusts the position, while the effective liquidity ( $LCC_0(r), LCC_1(r)$ ) or ( $x(r), y(r)$ ) shifts dynamically with the current tick.

# Model

The Value-to-Signal (VTS) model is a fundamental mechanism in the Fiet Protocol, governing liquidity commitments and settlement requirements for each token in a Fiet Market. The model relies on two key metrics: the **current VTS rate** ( $VTS_{\text{current}}$ ) and the **target VTS rate** ( $VTS_{\text{target}}$ ). These metrics work together to ensure that market makers (MMs) settle liquidity in response to market demand while optimising capital efficiency. 

MMs commit VRL via LCCs, settling and withdrawing liquidity at their discretion, incentivised by the target VTS rate, while Direct LPs fully settle liquidity upfront, using Uniswap v4’s default position management. The model defines current, required, and target VTS rates per position, ensuring settlements align with swap-driven demand.

## $VTS_{\text{current}}$

The current VTS rate measures the proportion of settled liquidity to committed liquidity for a given position $r$ (with range $[i_l, i_u]$ and liquidity $L(r)$) and token $A$. It is defined as:

$$
VTS_{\text{current}}(r, A) = \frac{S_A(r)}{C_A(r)}
$$

**Where:**

- $S_A(r)$: The settled liquidity for token $A$  in position $r$, including liquidity settled by MMs (via settlements), traders (via swaps), or Direct LPs (effective liquidity provided upfront).
- $C_A(r)$: The committed liquidity for token $A$ in position $r$, representing the maximum potential amount of token $A$ across the position’s price range:
    
    $$
     C_0(r) = L(r) \cdot \left( \frac{1}{\sqrt{p(i_l)}} - \frac{1}{\sqrt{p(i_u)}} \right), \quad C_1(r) = L(r) \cdot \left( \sqrt{p(i_u)} - \sqrt{p(i_l)} \right)
    $$
    
    Where ( $p(i_l) = 1.0001^{i_l} ), \space ( p(i_u) = 1.0001^{i_u}$ ), and $L(r)$ is the liquidity parameter for position $r$.
    
- $A$: Represents the token where $A = 0$ for `token0`, e.g., ETH, and $A = 1$ for `token1`, e.g., USDC.

For all positions, $VTS_{\text{current}}(r, A) \leq 1$, as $S_A(r) \leq C_A(r)$ reflecting partial settlement based on market demand.

The rates are calculated independently for each token, therefore:

$$
VTS_{\text{current}}(r, 0) + VTS_{\text{current}}(r, 1) \le 2
$$

However, for Direct LPs, $S_A(r)$ liquidity is fixed and settled upfront. Therefore, $S_A(r)$ where position $r$ is in-range ( $i_l \leq i_c < i_u$ ) can be calculated as $S_0(r) = \Delta x$ for `token0` , $S_1(r) = \Delta y$ for `token1` , where $\Delta x, \space \Delta y$ are derived from the [Uniswap v3 Whitepaper](https://app.uniswap.org/whitepaper-v3.pdf) (Page 9, Equations 6.29, 6.30).

This ratio provides a real-time measure of the liquidity currently available in the market relative to the commitments made.

### **What is Square Root Price?**

In the context of concentrated liquidity market makers like Uniswap v3 and v4, $\sqrt{p(i)}$ and $\sqrt{P}$ are related but distinct concepts, both representing square-root prices for computational efficiency in the constant product formula.

To clarify:

- $\sqrt{p(i)}$ refers to the square-root price at a specific tick boundary $i$. Ticks are discrete points on the price curve, where the price at tick $i$ is defined as $p(i) = 1.0001^i$ (with 1.0001 being the tick spacing factor). This makes $p(i)$ the fixed square-root value at that tick's lower or upper bound, used for position ranges and liquidity calculations at boundaries.
- $\sqrt{P}$ , on the other hand, is the exact current square-root price of the pool, which can lie anywhere between the square-root prices of the current tick $i_c$ and the next tick $i_c+1$ (i.e., within $[\sqrt{p(i_c)},\space \sqrt{p(i_c + 1)}\space]$). During a swap, $P$ updates continuously as liquidity is depleted within the tick, even if no tick boundary is crossed.

This distinction allows for precise tracking of intra-tick price movements during swaps, while tick-based $\sqrt{p(i)}$ provides efficient discretisation for position bounds and bitmap storage. For example, outflow calculations in a swap use $\sqrt{P}$ for exact deltas, falling back to tick-bound $\sqrt{p(i)}$ when approximating at boundaries.

## $VTS_{\text{target}}$

The target VTS rate dynamically adjusts the required liquidity settlement based on market demand and position characteristics. It sets the target level of settled liquidity that an MM should aim to achieve for their position $r$. 

$VTS_{\text{target}}$ is a complex calculation that depends on various sub-formulas.

### Market Demand Indicators

Market demand is evaluated through pool-wide indicators. This calculation is based on activity that impacts the pool at large, and therefore functions as a parameter within each position’s target VTS rate calculation. 

The demand indicators $I_A(t)$ project future liquidity needs:

1. Total token $A$ outflow over time window ( $[t - T, t]$ ): 
    
    $$
    \Delta O_0 = \sum_{\text{swaps in } [t - T, t]} |\Delta x|, \quad \Delta O_1 = \sum_{\text{swaps in } [t - T, t]} |\Delta y|
    $$
    
    **Where:**
    
    - $t$ : Is the current time
    - $T$ : Is a fixed time in configured at market deployment
    - $\Delta x, \space \Delta y$ : Derived from the integrated CLMM
2. A **boost term** to project additional liquidity required beyond immediate demands, ensuring a smooth trader experience through pre-settled liquidity. The aim is to completely abstract interactions directly from LCCs from traders. While not completely possible, as sufficiently large trades will absorb all of the pre-settled liquidity, for the majority of trades, the boost term fulfils this goal.
    1. For `token1` in, `token0` out:
        
        $$
        B_0 = \alpha \cdot \frac{|\Delta x|}{\sum_{\text{active } r} L(r) \cdot \left| \frac{1}{\sqrt{P_{\text{after}}}} - \frac{1}{\sqrt{P_{\text{before}}}} \right|}
        $$
        
    2. For `token0` in, `token1` out:
    
    $$
    B_1 = \alpha \cdot \frac{|\Delta y|}{\sum_{\text{active } r} L(r) \cdot \left| \sqrt{P_{\text{after}}} - \sqrt{P_{\text{before}}} \right|}
    $$
    
    **Where:**
    
    - $\alpha$ : A scaling parameter (e.g., 0.1 to 2)
    - $L(r)$: Liquidity in the position
    - $\sum_{\text{active } r} L(r)$: Sum of liquidity in positions where position $r$ with range $[i_l, i_u]$ is active and directly affected during a swap, if its range intersects the swap’s tick range
        - For a swap increasing ticks (token1 in, token0 out): $i_l \le i_{c,after}$, and $i_u \gt i_{c,before}$
        - For a swap decreasing ticks (token0 in, token1 out): $i_l \leq i_{c,\text{before}}$ and $i_u > i_{c,\text{after}}$
        - This includes positions where $i_{c,before} > i_l$ and $i_{c,after} > i_u$, which are active during the swap but become out-of-range post-swap.
    - $\sqrt{P_{\text{before}}}$ : Square-root price before the swap.
    - $\sqrt{P_{\text{after}}}$ : Square-root price after the swap (updated continuously, even within ticks).
    - $\Delta x, \space \Delta y$ : Represent the total outflow for a specific token from an individual swap, allowing the term to quantify the demand intensity of each swap event in isolation.
- A **decay term** that ensures the target VTS rate returns to it’s base rate ( $VTS_{base}$ ) if demand for a token $A$ wanes:
    
    $$
    D = e^{-\lambda (t - t_{\text{last}})}
    $$
    
    **Where:** $\lambda$ is the decay rate (e.g., $\frac{\ln(2)}{3600} \approx 0.0001927$ )
    

Therefore, the Indicator is defined as: 

$$
I_0(t) = D \cdot I_0(t_{\text{last}}) + (1 - D) \cdot B_0, \quad I_1(t) = D \cdot I_1(t_{\text{last}}) + (1 - D) \cdot B_1
$$

**Where:** $I_0(t), \space I_1(t)$ are stateful indicators updated after each swap.

### Required VTS Rate ( $VTS_{required}$ )

To ensure that the $VTS_{\text{target}}$ is sufficiently liquid, such that traders receive the exact expected amount of native token per their swap activity, there must be a minimum threshold of liquidity required to be settled to at least meet the direct requirements of the swap activity. Establishing this baseline constitutes sufficient liquidity. Anything in excess covers a projection based on future demand.

The time-window required VTS rate, $VTS_{\text{required}}(t, r, A)$, measures the proportion of committed liquidity needed to cover cumulative outflows over the time window $[t - T, t]$:

1. **Sum Outflows**:
    
    $$
    \Delta O_0(r) = \sum_{\text{swaps in } [t - T, t]} |\Delta x(r)|, \quad \Delta O_1(r) = \sum_{\text{swaps in } [t - T, t]} |\Delta y(r)|
    $$
    
    **Where:**
    
    - $\Delta x(r), \Delta y(r)$: Outflow amounts for position $r$ in a swap:
        - `token1` in, `token0` out:
            
            $$
            \Delta x(r) = 
            \begin{cases} 
            L(r) \cdot \left( \frac{1}{\sqrt{P_{\text{after}}}} - \frac{1}{\sqrt{P_{\text{before}}}} \right) & \small\text{if position active in swap} \\
            0 & \small\text{otherwise}
            \end{cases}
            $$
            
        - `token0` in, `token1` out:
            
            $$
            \Delta y(r) = 
            \begin{cases} 
            L(r) \cdot \left( \sqrt{P_{\text{after}}} - \sqrt{P_{\text{before}}} \right) & \small\text{if position active in swap} \\
            0 & \small\text{otherwise}
            \end{cases}
            $$
            
        - For no exact price delta (fallback proportional allocation):
            - `token1` in, `token0` out:
                
                $$
                \Delta x(r) = \frac{\Delta y \cdot L(r)}{\sum_{\text{in-range } r} L(r)}
                $$
                
            - `token0` in, `token1` out:
                
                 
                
                $$
                \Delta y(r) = \frac{\Delta x \cdot L(r)}{\sum_{\text{in-range } r} L(r)}
                $$
                
    - $\sqrt{P_{\text{before}}}$ : The square-root price at the start of the swap's impact on position $r$ (e.g., max($\sqrt{p(i_l)}$, initial $\sqrt{P}$ within the tick)).
    - $\sqrt{P_{\text{after}}}$ : The square-root price at the end of the swap's impact (e.g., min($\sqrt{p(i_u)}$, final $\sqrt{P}$ after depletion)).
    - "Position active in swap": The position's range $[i_l,i_u]$ intersects the traversed square-root price interval during the swap.
    - Other variables as previously defined (e.g., L(r) L(r) L(r), Δy \Delta y Δy, etc.).
2. **In-Range Calculation**:
    
    $$
    VTS_{\text{required}}(t, r, A) = \min\left(1, \frac{\Delta O_A(r)}{C_A(r)}\right)
    $$
    
    where:
    
    - $A$: The token where $A = 0$ for `token0`, e.g., ETH, and $A = 1$ for `token1`, e.g., USDC.
    - $min(1, ...)$ wrapper to prevents ratios >1 in high-outflow scenarios, ensuring full settlement for position $r$ at most.

The allocation of pool-wide swap outflows ($\Delta O_A$) to position-specific outflows ( $\Delta O_A(r)$ ) is achieved by determining each position's contribution to the total outflow during individual swaps. This process relies on the concentrated liquidity mechanics, where outflows are distributed based on the liquidity $L(r)$ of each active position relative to the total liquidity in the affected price range.

For each swap, compute the outflow delta per position $r$ ( $\Delta x(r)$ or $\Delta y(r)$ ) using the position's liquidity and the square-root price change. Then, sum these deltas over the time window $[t - T, t]$ to obtain $\Delta O_A(r)$.

This ensures position-specific granularity: positions with higher $L(r)$ in the traversed range contribute more to the outflow, while inactive positions contribute zero. The pool-wide $\Delta O_A$is simply the sum across all positions, but the per-position breakdown drives the VTS calculations.

### Target Rate Definition

The target Value-to-Signal (VTS) rate, $VTS_{\text{target}}(r, A)$, determines the proportion of committed liquidity for token $A$ (where $A = 0$ for `token0`, e.g., ETH, and $A = 1$ for `token1`, e.g., USDC) that Market Makers (MMs) should settle for a position $r$ with range $[i_l, i_u]$ to meet projected market demand in a Fiet Market. The calculation differs based on whether the position is in-range ($i_l \leq i_c < i_u$) or soon to be in-range, defined as out-of-range positions close to the current tick $i_c$ that are likely to become active based on recent swap activity. 

**In-Range Positions:**

For an in-range position $r$ ($i_l \leq i_c < i_u$), the target VTS rate ensures sufficient liquidity to cover past and projected demand, using the time-window-based required VTS rate as a minimum threshold:

$$
VTS_{\text{target}}(r, A) = \min \left( 1, \max \left( VTS_{\text{required}}(t, r, A), VTS_{\text{base}, A} + I_A(t) \cdot \frac{L(r)}{\sum_{\text{in-range } r} L(r)} \right) \right)
$$

**Where:**

- $t$ : Current time.
- $A$ : Token index ($A=0$ for `token0`, $A=1$ for `token1`).
- $L(r)$ : Liquidity parameter for position $r$, defining its contribution to the pool’s liquidity (Uniswap v3 Whitepaper, Page 5, Section 6.2.1).
- $VTS_{\text{base}, A}$: Base VTS rate set at market launch (e.g., 0.02 for USDC, 0.05 for ckBTC)
- $I_A(t)$: Pool-wide market demand indicator for token $A$, capturing recent trading activity over the time window $[t−T,t]$.
- $\sum_{\text{in-range } r} L(r)$: Total liquidity of in-range positions, used to weight the demand indicator.

**Soon-to-Be In-Range Positions:**

For soon-to-be in-range positions (out-of-range but near $i_c$), allocate excess liquidity requirements across positions likely to activate, using tick-based iteration with proximity decay adjusted for recent tick velocity to prioritise closer ranges.

- For `token0`: Iterate forward over initialised ticks $i > i_c$ in the TickBitmap.
- For `token1`: Iterate backward over initialised ticks $i \leq i_c$
- For each tick $i$:
    - Define:
        
        $$
        N_A(i) = \{ r : i_l = i \} \text{ (token0)} \quad \text{or} \quad \{ r : i_u = i \} \text{ (token1)}
        $$
        
        *This defines the set of positions starting (for token0) or ending (for token1) at the current tick, grouping them for allocation.*
        
        $$
        L_i = \sum_{r \in N_A(i)} L(r)
        $$
        
        *This calculates the total liquidity of positions in the set at the current tick, used for proportional weighting.*
        
    - Initialise:
        
        $$
        E_A = \text{Excess Required Liquidity}_A \text{ (for } VTS_{\text{required}} \text{)},\newline \quad E_A = \text{Excess Liquidity}_A \text{ (for } VTS_{\text{target}} \text{)},\newline \quad N_A = \emptyset
        $$
        
        *This sets up the excess liquidity to allocate and an empty set for accumulating processed positions.*
        
    - For each $r \in N_A(i)$
        - Compute for $VTS_{\text{required}}(t, r, A)$ :
            
            $$
            VTS_{\text{potential}}(t, r, 0) = \frac{E_0}{\sum_{r' \in N_0 \cup N_0(i)} C_0(r')} \cdot \frac{L(r)}{L_i} \cdot e^{-\kappa_v |i_l - i_c|}
            $$
            
            $$
            VTS_{\text{potential}}(t, r, 1) = \frac{E_1}{\sum_{r' \in N_1 \cup N_1(i)} C_1(r')} \cdot \frac{L(r)}{L_i} \cdot e^{-\kappa_v |i_u - i_c|}
            $$
            
            *Computes a potential required VTS rate for token0 or token1, weighting excess by committed liquidity, position liquidity share, and proximity decay.*
            
        - Compute for $VTS_{\text{target}}(r, A)$
            
            $$
            VTS_{\text{potential}}(r, 0) = VTS_{\text{base}, 0} + \frac{E_0}{\sum_{r' \in N_0 \cup N_0(i)} C_0(r')} \cdot \frac{L(r)}{L_i} \cdot e^{-\kappa_v |i_l - i_c|}
            $$
            
            $$
            VTS_{\text{potential}}(r, 1) = VTS_{\text{base}, 1} + \frac{E_1}{\sum_{r' \in N_1 \cup N_1(i)} C_1(r')} \cdot \frac{L(r)}{L_i} \cdot e^{-\kappa_v |i_u - i_c|}
            $$
            
            *This computes a potential target VTS rate for token0 or token1, adding the base rate to the weighted excess allocation with decay.*
            
        - For both:
            - If $VTS_{\text{potential}}(t, r, A) \leq 1$ or $VTS_{\text{potential}}(r, A) \leq 1$:
                - Set $VTS_{\text{required}}(t, r, A) = VTS_{\text{potential}}(t, r, A)$ or $VTS_{\text{target}}(r, A) = VTS_{\text{potential}}(r, A)$
                - Update $E_A = E_A - VTS_{\text{required/target}}(r, A) \cdot C_A(r)$.
                
                *This assigns the potential rate if within bounds and reduces excess by the allocated amount.*
                
            - If $VTS_{\text{potential}}(t, r, A) > 1$ or $VTS_{\text{potential}}(r, A) > 1$  :
                - Set $VTS_{\text{required}}(t, r, A) = 1$ or $VTS_{\text{target}}(r, A) = 1$.
                - Update $E_A = E_A - C_A(r)$.
                
                *This caps the rate at full settlement if potential exceeds 1 and reduces excess by the full commitment.*
                
            - Add $N_A(i)$ to $N_A$.
                
                *This accumulates the processed position set for the next iteration's summation.*
                
        - Stop when $E_A \leq 0$ or no more initialised ticks.
            
            *This halts allocation once excess is depleted or all relevant ticks are covered.*
            
    - Parameters: $\kappa_v = 0.01 \cdot v$ (proximity decay factor, where $v$ is recent tick velocity, e.g., average ticks crossed per swap over the last hour).
        
        *This adjusts the decay based on market volatility to prioritise nearer positions in active conditions.*
        

**Breakdown of Symbols:**

Consider the $VTS_{\text{potential}}(t, r, 1)$. The expression calculates the total committed liquidity (for token1, in this case) across a combined set of liquidity positions. It sums the maximum commitment values $C_1(r')$ for all positions $r'$ that belong to the union of two sets: the accumulated set of previously processed positions $N_1$ and the set of positions at the current tick ( $N_1(i)$ ). This total is then used to normalise or weight the allocation of excess liquidity requirements in the VTS model, ensuring settlements are proportional to the commitments of nearby positions likely to become active soon.

In the Fiet Protocol, this supports market makers in facilitating liquidity by dynamically adjusting settlement obligations based on anticipated demand, particularly for positions near the current price tick in concentrated liquidity market makers (CLMMs) like Uniswap v3 or v4.

Here is a step-by-step explanation of the symbols in the expression $\sum_{r' \in N_1 \cup N_1(i)}$ :

- $\sum$: This is the summation operator (sigma). It indicates that you add up the values of the term that follows (in this case, implicitly $C_1(r′)$ or a similar quantity) for every element in the specified set.
- $r′$ : This is a dummy variable (often called an index or iterator). It represents each individual liquidity position in the set being summed over. The prime ($'$) distinguishes it from the main position $r$ in the broader formula. In the Fiet context, $r′$ iterates over positions similar to $r$, which are bounded price ranges where market makers commit liquidity.
- $\in$: This symbol means "is an element of" or "belongs to." It specifies that $r′$ must be a member of the set that follows.
- $N_1$: This is the accumulated set of positions for token1. It starts as an empty set ($N_1=\emptyset$) and grows by adding groups of positions ( $N_1(i)$ ) as the algorithm iterates over ticks. Positions in $N_1$ are those that have already been processed in previous ticks during the allocation.
- $\cup$: This is the set union operator. It combines two sets into one, including all unique elements from both without duplicates. Here, it merges the accumulated positions $N_1$ with the current tick's positions $N_1(i)$.
- $N_1(i)$: This is the set of positions for token1 that end at the specific tick $i$ (defined as $N_1(i)={r:i_u=i}$, where $i_u$ is the upper tick bound of position $r$). The subscript "$1$" indicates token1, and ($i$) denotes the current tick being evaluated in the iteration.

For completeness, while not part of the summation itself, the summed term (e.g., $C_1(r')$ ) refers to the maximum committed liquidity for token1 in position $r′$, calculated as $C_1(r') = L(r') \cdot (\sqrt{p(i_u)} - \sqrt{p(i_l)})$, where $L(r′)$ is the liquidity parameter, and $\sqrt{p(\cdot)}$ is the square-root price at the tick bounds.

This notation draws from standard set theory and summation in mathematical modelling, adapted to the Fiet Protocol's approach to liquidity commitments in CLMMs.