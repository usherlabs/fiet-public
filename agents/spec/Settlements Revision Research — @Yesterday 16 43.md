# Settlements: Revision Research — @Yesterday 16:43

Seizure amount calculation is not delivering as expected.

```
// TODO: we cannot clamp by the RfS, otherwise during seizures, the full settled amount up to the RfS is utilised instead of the fraction of settled liquidity relative to the amount seized.
// ? The counterargument is a seizure requires closing RfS. Therefore, seized amounts should equal settled amounts...
// If I've only settled 10% of Token A, and more RfS exposure is 30% more, then seizure at scaled allocation results in settling 30%, but being rewarded 0.26% of liquidty position if 20% timewindow passes.
// therefore, there's no incentive to seize prior to t = timeWindow...
// Closing the RfS means seizing the full position ONLY when the full time window has passed.
```

In essence, seizure amounts scaled linearly by time mean that incentives adjust as a gate…

Seizure amounts will begin to have no incentive early on, and then as time progresses, then there’s seizure immediately becomes incentivised.

The time at which this incentive activates will be based on the profits Guarantors aim to acquire relative to available competition — which surfaces the Guarantor with the lowest rate at which the settlement currency can be acquired.

If I settle 30% RfS amount, then seize 30% of the position

$$
L_s(r) = \frac{a_A(r)}{C_A(r)} \cdot L(r)
$$

This allows profit in seizure of counterparty asset settled liquidity ($VTS_{current}(r, A)$) with min $VTS_{base}(r, A)$.

However, if $a_0(r) > 0$ AND $a_1(r) > 0$, then both sides need to be settled.

However,

$$
\frac{a_A(r)}{C_A(r)} \le 1 - VTS_{base}(r, A)
$$

In the case where $a_0(r) > 0$ AND $a_1(r) > 0$, then:

$$
L_s(r) = \min\left(1, \left(\frac{a_0(r)}{C_0(r)} + \frac{a_1(r)}{C_1(r)} \right) \cdot L(r)\right)
$$

However, AMM and market mathematics will resolve such that $a_0(r)$ is inversely proportional to $a_1(r)$. 

Both params are only ever $>0$ simultaneously when markets are stable. 

Therefore, a fair heuristic is that:

$$
\frac{a_A(r)}{C_A(r)} \approx 1 - \frac{a_{|A-1|}(r)}{C_{|A-1|}(r)}
$$

The result of this is that Guarantors can utilise [Flash Loans](https://aave.com/docs/developers/flash-loans) to seize, as the seizure amounts will return in full.

---

## Seizure — Formalised

The existing seizure amount calculation does not deliver as expected.

A seizure requires closing the RfS. Therefore, seized amounts should equal settled amounts.

In essence, seizure amounts scaled linearly by time mean that incentives adjust as a gate.

Seizure amounts will begin to have no incentive early on, and then as time progresses, seizure immediately becomes incentivised.

The time at which this incentive activates will be based on the profits Guarantors aim to acquire relative to available competition — which surfaces the Guarantor with the lowest rate at which the settlement currency can be acquired.

If a Guarantor settles 30% of the RfS amount, then the Guarantor seizes 30% of the position.

The following formula determines the seized liquidity amount for a single-sided exposure.

$$
L_s(r) = \frac{a_A(r)}{C_A(r)} \cdot L(r)
$$

This formula allows profit in seizure of counterparty asset settled liquidity ($VTS_{current}(r, A)$) with a minimum of $VTS_{base}(r, A)$.

Where:

- $L_s(r)$: The seized liquidity amount for position $r$.
- $a_A(r)$: The RfS exposure for token $A$ in position $r$.
- $C_A(r)$: The committed liquidity for token $A$ in position $r$.
- $L(r)$: The total liquidity for position $r$.

However, if $a_0(r) > 0$ and $a_1(r) > 0$, then both sides need to be settled.

The following inequality ensures the exposure ratio is bounded by the base VTS.

$$
\frac{a_A(r)}{C_A(r)} \leq 1 - VTS_{base}(r, A)
$$

Where:

- $a_A(r)$: The RfS exposure for token $A$ in position $r$.
- $C_A(r)$: The committed liquidity for token $A$ in position $r$.
- $VTS_{base}(r, A)$: The base Value-to-Signal ratio for position $r$ and token $A$.

In the case where $a_0(r) > 0$ and $a_1(r) > 0$, the following formula determines the seized liquidity amount for dual-sided exposures.

$$
⁍
$$

This formula aggregates the exposure ratios across both tokens and caps the seizure at the full position liquidity.

Where:

- $L_s(r)$: The seized liquidity amount for position $r$.
- $a_0(r)$: The RfS exposure for token $0$ in position $r$.
- $C_0(r)$: The committed liquidity for token $0$ in position $r$.
- $a_1(r)$: The RfS exposure for token $1$ in position $r$.
- $C_1(r)$: The committed liquidity for token $1$ in position $r$.
- $L(r)$: The total liquidity for position $r$.

However, AMM and market mathematics will resolve such that $a_0(r)$ is inversely proportional to $a_1(r)$.

Both parameters are only ever greater than 0 simultaneously when markets are stable.

Therefore, a fair heuristic is that:

$$
⁍
$$

Where:

- $a_A(r)$: The RfS exposure for token $A$ in position $r$.
- $C_A(r)$: The committed liquidity for token $A$ in position r.
- $a_{|A-1|}(r)$: The RfS exposure for the counterparty token in position $r$.
- $C_{|A-1|}(r)$: The committed liquidity for the counterparty token in position $r$.

The result of this is that Guarantors can utilise Flash Loans to seize, as the seizure amounts will return in full.

To ensure viability for low exposures, apply a minimum threshold using $VTS_{base}$.

The following formula determines the seized liquidity amount for a single-sided exposure with a minimum threshold.

$$
L_s(r) = \max\left(VTS_{base}(r, A) \cdot L(r), \frac{a_A(r)}{C_A(r)} \cdot L(r)\right)
$$

The formula for the seized liquidity amount in the dual-sided case (when $a_0(r) > 0$ and $a_1(r) > 0$) is:

$$
⁍
$$

This formula determines the portion of the position's liquidity available for seizure by aggregating effective exposure ratios per token and capping at the full position.

Where:

- $L_s(r), L(r), a_A(r), ...$ mirror aforementioned definitions.
- $e_0$: The effective ratio for token 0.
    
    $$
    e_0 = \max\left(VTS_{base}(r, 0), \frac{a_0(r)}{C_0(r)}\right)
    $$
    
- $e_1$: The effective ratio for token 1.
    
    $$
    e_1 = \max\left(VTS_{base}(r, 1), \frac{a_1(r)}{C_1(r)}\right)
    $$
    

Grace periods can be extended by market makers proving in-progress settlements, ensuring sufficiency without additional time windows.