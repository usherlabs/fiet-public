# Value-to-Signal Model — Revision Research — @Today 17:47

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