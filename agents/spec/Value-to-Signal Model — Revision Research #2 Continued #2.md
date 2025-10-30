# Value-to-Signal Model — Revision Research #2: Continued #2 — @Yesterday 10:44

Continued from [Value-to-Signal Model — Revision Research #2: Continued — 2 October 2025 20:48 ](https://www.notion.so/Value-to-Signal-Model-Revision-Research-2-Continued-2806d8286da58016a831f47737cc0aa1?pvs=21) and [Notes to Self: VTS Revision #2](https://www.notion.so/Notes-to-Self-VTS-Revision-2-2816d8286da580c2a69ae4f682951096?pvs=21) 

---

## Overview

The Value-to-Signal (VTS) model forms a core component of the Fiet Protocol's risk management framework, as outlined in the Fiet Technical Specification (Pre-Whitepaper), Version 1.1. It dynamically adjusts the liquidity requirements for market makers facilitating markets within the protocol. By calculating settlement rates based on market demand and position-specific obligations, the VTS model ensures that committed liquidity aligns with actual trader activity, thereby supporting capital efficiency and reliable settlements.

This specification formalises the VTS model based on research conducted to date, including revisions to address limitations in time-bound calculations and to incorporate precise attribution mechanisms. It focuses on two key metrics: VTS_required, which establishes the baseline settlement rate to cover outstanding obligations, and VTS_current, which reflects the current settled rate for a position. These metrics draw inspiration from concentrated liquidity mechanics in Uniswap v3, particularly fee accrual (Sections 6.2.2, 6.3, and 6.4 of the Uniswap v3 Core paper), and attribution concepts from ColorTrace, adapted for the Fiet Protocol's use of Liquidity Commitment Certificates (LCCs) and on-demand settlements.

The model assumes a concentrated liquidity automated market maker (AMM) structure, where positions (r) are bounded by lower (i_l) and upper (i_u) ticks, and liquidity (L(r)) is provided within these ranges. Market makers commit liquidity (C_A(r)) for token A, verified via zkTLS proofs, without initial locking. Swaps generate outflows (ΔO_A) and inflows (ΔI_A) to the MarketVault, with LCCs issued only for user deposits or market maker commitments (as clarified in Revision Research #2).

## Research Background

Initial research, as documented in the Value-to-Signal Model — Revision Research (dated Wednesday 17:47) and continued in Revision Research #2 (dated Thursday 20:48), identified limitations in the original VTS_required formulation. The time-window-based approach (proportion of committed liquidity to cover outflows over T) failed to account for delayed LCC redemptions, potentially leading to deficits when demand waned. A shift to a deficit-based model was proposed, tracking outstanding LCCs (Deficit_A) apportioned by historical contributions.

Further refinements addressed equity among market makers: proactive settlements should not subsidise others, leading to the concept of "coverage debt" where shortfalls accrue as deficits even if pool-wide liquidity covers outflows. Clarifications emphasised that LCCs are issued only for deposits or commitments, and ΔO_A/ΔI_A represent flows to the MarketVault. Attribution challenges—such as approximating via liquidity weights (w(r_i)) skipping out-of-range shifts—were resolved through tick-indexed growth mechanisms, ensuring precise, gas-efficient calculations without per-swap storage or iteration.

This research aligns with Fiet's non-custodial design, where traders retain asset control, and Settlement Guarantors intervene for persistent deficits, claiming positions to maintain continuity.

## Mathematical Models

### VTS_required

$VTS_{required}(r, A)$ defines the minimum settlement rate for position r and token A, ensuring coverage of outstanding obligations (deficits) relative to committed liquidity. Deficits accrue when apportioned outflows exceed settled liquidity, regardless of pool-wide availability, to enforce position-specific accountability.

$$
\text{VTS}_{\text{required}}(r, A) = \min\left(1, \frac{D_A(r)}{C_A(r)}\right)
$$

Where:

- $D_A(r)$: Cumulative deficit for position $r$ and token $A$, representing unsettled outflows attributed while in-range.
- $C_A(r)$: Committed maxima for token $A$ in position $r$, verified via zkTLS.

Deficits accumulate as:

$$
D_A(r) = D_A(r)_{\text{old}} + \Delta D_A(r)
$$

Where $Delta D_A(r)$ is the incremental deficit since the last position update, computed via the tick-indexed mechanism (detailed in Implementation Approaches).

### VTS_current

$VTS_{current}(r, A)$ represents the current settled rate, incorporating market maker settlements and attributed inflows from counterparty tokens during swaps.

$$
\text{VTS}_{\text{current}}(r, A) = \frac{S_A(r)}{C_A(r)}
$$

Where:

- $(S_A(r)$: Settled liquidity for position r and token A, updated as:
    
    $$
    S_A(r) = S_A(r)_{\text{old}} + \Delta I_A(r)
    $$
    
- $\Delta I_A(r)$: Incremental inflows attributed since the last update, computed via the tick-indexed inflow growth mechanism.

Withdrawals are permitted only if $S_A(r) > D_A(r)$ and other protocol conditions are met, preventing removal of liquidity needed for settlements.

## Implementation Approaches

The VTS model leverages Uniswap v3-inspired tick-indexed growth for efficient attribution, ensuring O(1) complexity for queries and updates. This adapts fee accrual logic to track deficits and inflows per liquidity unit while positions are in-range, without requiring per-swap storage.

### Deficit Attribution: Tick-Indexed Deficit Growth

To attribute outflows precisely:

- **Global State (per Pool, per Token $A$)**: `deficitGrowthGlobal_A` (`uint256`, fixed-point), accumulating unsettled outflows per in-range liquidity unit.
- **Tick State (per Tick $i$, per Token $A$)**: `deficitGrowthOutside_A` (`uint256`), tracking outside growth.
- **Position State (per $r$)**: `deficitGrowthInsideLast_A` (`uint256`), last inside growth.

**Update Logic**:

1. On swap with outflow ΔO_A:
    
    $$
    \Delta \text{deficit} = \frac{\Delta O_A}{L_{\text{current}}}
    $$
    
    $$
    \text{deficitGrowthGlobal}_A += \Delta \text{deficit}
    $$
    
    $L_{current}$ is in-range liquidity at swap start.
    
2. On tick cross (i):
    
    $$
    \text{deficitGrowthOutside}_A(i) = \text{deficitGrowthGlobal}_A - \text{deficitGrowthOutside}_A(i) 
    $$
    
3. On position update (r with i_l, i_u):
    
    $$
    \text{deficitInside}_A = \text{deficitGrowthGlobal}_A - \text{deficitGrowthOutside}_A(i_l) - \text{deficitGrowthOutside}_A(i_u)
    $$
    
    $$
    \Delta D_A(r) = (\text{deficitInside}_A - \text{deficitGrowthInsideLast}_A(r)) \times L(r)
    $$
    
    Add to $D_A(r)$; update $\text{deficitGrowthInsideLast}_A(r) = \text{deficitInside}_A$.
    

This ensures deficits accrue only during in-range periods, handling mid-swap shifts.

### Inflow Allocation: Tick-Indexed Inflow Growth

Symmetrically for inflows:

- **Global State**: inflowGrowthGlobal_A.
- **Tick State**: inflowGrowthOutside_A.
- **Position State**: inflowGrowthInsideLast_A.

**Update Logic**:

1. On swap with inflow $ΔI_A$:
    
    $$
    \Delta \text{inflow} = \frac{\Delta I_A}{L_{\text{current}}}
    $$
    
    $$
    \text{inflowGrowthGlobal}_A += \Delta \text{inflow}
    $$
    
2. On tick cross: Flip $\text{inflowGrowthOutside}_A(i)$ as above.
3. On position update:
    
    $$
    \text{inflowInside}_A = \text{inflowGrowthGlobal}_A - \text{inflowGrowthOutside}_A(i_l) - \text{inflowGrowthOutside}_A(i_u)
    $$
    
    $$
    \Delta I_A(r) = (\text{inflowInside}_A - \text{inflowGrowthInsideLast}_A(r)) \times L(r)
    $$
    
    Add to $S_A(r)$; update $\text{inflowGrowthInsideLast}_A(r) = \text{inflowInside}_A$.
    

**Integration Notes**:

- Fields added to pool (growth globals), ticks (outside growth), and positions (inside last, cumulative D/S).
- Updates occur in swap (post-fee), crossTick, and position modifications.
- For out-of-range positions, no new attributions until re-entry.
- Guarantors reduce $D_A(r)$ on intervention, lowering VTS_required.

This specification provides a foundation for the VTS model, ensuring alignment with Fiet's objectives of efficient market facilitation and trader protections.