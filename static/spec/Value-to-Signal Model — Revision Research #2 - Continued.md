# Value-to-Signal Model — Revision Research #2: Continued — @Yesterday 20:48

Continuation of [Value-to-Signal Model — Revision Research #2 — 24 September 2025 17:47 ](https://www.notion.so/Value-to-Signal-Model-Revision-Research-2-2786d8286da580ff9286d24a698cc223?pvs=21) 

---

The current $VTS_{required}$, as defined by the proportion of outstanding Liquidity Commitment Certificates (LCCs) relative to committed liquidity, effectively captures baseline requirements only in cases of outright insufficiency. However, when pool-wide settled liquidity ($S_A$) covers the shortfall for an in-range position during unwraps or proxy swaps, the position does not accrue a deficit, which could lead to imbalances. Proactive market makers who settle excess might subsidise less diligent ones, undermining incentives for all positions to maintain adequate settlements. Introducing an obligation in these cases—essentially treating the coverage as a "loan" from the protocol—ensures equity: the in-range position owes back the amount used from elsewhere, raising its VTS_required until repaid. This would not affect market makers who settle sufficiently in advance, as their positions would not draw on the pool-wide buffer.
This adjustment enhances the protocol's risk management (Fiet Technical Specification, page 2), as it ties obligations directly to position utilisation during swaps, regardless of the liquidity source. It also supports seamless native asset delivery in the Proxy Pool, where traders expect immediate outflows without LCC fallback, while maintaining demand-driven settlements.

To implement the obligation (let's call it a "coverage debt"), in-range positions with insufficient settled liquidity $S_A(r_i)$ must cover their proportional share of the outflow $\Delta O_A(r_i)$. If $S_A(r_i) < \Delta O_A(r_i)$, sum the position's $D_A(r_i)$ with the shortfall, even if pool-wide $S_A$ covers it. The protocol then "repays" itself by decrementing the global $S_A$, ensuring the debt is attributed precisely without double-counting.

Guarantors can intervene if debts persist, claiming positions as per the specification.

---

The genius of this is that we cannot enter into a territory where there’s insufficient liquidity. All outflows are a result of inflows.

However, we must ensure that withdrawals are only available to the MM if RfS is closed — otherwise, could result in withdrawing liquidity from inflows allocated to their position before settling for the counterparty asset that was covered by protocol-level liquidity.

Believe this is the case now.

In order to facilitate these withdrawals, we must allocate the inflows proportionally to their settled liquidity.

Therefore, $S_A(r)$ is not just tracked per their settlements but also as a result of $\Delta O_{in,A}$

Rather than associating to $S_A(r)$, we can modify the $VTS_{current}$ to accomodate this. 

---

$\Delta O_A$ refers to the pool-wide outflows of native tokens from the protocol, encompassing both swap-related outflows (where traders receive native assets via the Proxy Pool's unwrapping mechanism) and direct settlement outflows (e.g., LCC unwraps by holders). This distinction is important, as swap outflows in the Core Pool involve LCCs, but the Proxy Pool proxies these to deliver native tokens, potentially triggering outflows from the protocol's settled liquidity. Liquidity outflows represent the actual transfer of native assets to users, which may occur asynchronously from swaps if sufficient settled liquidity is available. Thus, ΔOA \Delta O_A ΔOA captures the net effect of these outflows over the time window, ensuring the Value-to-Signal model reflects real demand on the protocol's reserves.

Traders' deposits (inflows) into the Proxy Pool or Core Pool during swaps provide native tokens that can offset outflows, effectively contributing to the protocol's settled liquidity. These inflows should be apportioned to in-range market maker positions proportionally (e.g., based on their liquidity weight $w(r_i) = \frac{L(r_i)}{\sum L(r')}$, as these positions facilitate the swap at the current tick. This allocation would increase the position-specific settled liquidity $S_A(r_i)$, reflecting the trader's contribution to covering obligations. For example, an inflow of token A could be attributed as $\Delta I_A(r_i) = w(r_i) \cdot \Delta I_A$, where $\Delta I_A$  is the pool-wide inflow over the window.

To incorporate inflows into VTS_current (the current settled rate, $\text{VTS}_{\text{current}}(r_i, A) = \frac{S_A(r_i)}{C_A(r_i)}$, update $S_A(r_i)$ to include apportioned inflows:

$$
S_A(r_i) = S_A(r_i)_{\text{old}} + w(r_i) \cdot \Delta I_A - \text{attributed outflows}
$$

This maintains balance, as outflows (including those covered by pool-wide liquidity) are attributed as debts, while inflows credit the position.

$VTS_{required}$ attributes coverage debt retroactively via ring buffer events, accruing to D_A(r) for in-range positions with shortfalls, even if pool-wide liquidity covers the outflow. During calculations, process the buffer to compute

$$
D_A(r) = D_A(r)_{\text{old}} + \sum_{\text{events where r in-range}} \max\left(0, \Delta O_A(r) - S_A(r)_{\text{event}}\right)
$$

Where:

- $\Delta O_A(r) = w(r) \cdot \Delta O_A^{\text{event}}$ is the apportioned outflow per event.
- $S_A(r)_{\text{event}}$ is reconstructed from settlement logs.

Then:

$$
\text{VTS}_{\text{required}}(r, A) = \min\left(1, \frac{D_A(r)}{C_A(r)}\right)
$$

This model is efficient, with attributions on-demand, ensuring market makers settle debts while traders receive immediate liquidity.

---

### Simplification of the VTS equations

$$
VTS_{current}(r, A) = \frac{S_A(r) + \Delta I_A(r)}{C_A(r)}
$$

$$
VTS_{required}(r, A) = \min\left(1, \frac{D_A(r) + \max\left(0, \Delta O_A(r) - S_A(r)\right)}{C_A(r)}\right)
$$

Where:

- $S_A(r)$ is the settled liquidity for token $A$ in position $r$.
- $\Delta I_A(r) = w(r) \cdot \Delta I_A$ is the apportioned inflow for token $A$ over the window.
- $D_A(r)$ is the existing deficit for token $A$ in position $r$.
- $\Delta O_A(r) = w(r) \cdot \Delta O_A$ is the apportioned outflow for token $A$ over the window.
- $C_A(r)$ is the committed liquidity for token $A$ in position $r$.
- $w(r) = \frac{L(r)}{\sum L(r')}$ is the liquidity weight over active positions $r′$.