# Unbacked Commitment Declaration

The Fiet Protocol maintains a critical invariant: all issued Liquidity Commitment Certificates (LCCs) must remain backed by verified off-chain reserves (signal) plus on-chain settled liquidity. When a commitment is proven to be unbacked—where issued LCCs exceed the sum of signal reserves and settled amounts—the protocol enables immediate intervention through the `_declareUnbackedCommitment` mechanism. This process applies commitment-scoped deficits that inflate Request for Settlement (RfS) requirements, forcing positions into an open RfS state and enabling permissionless seizure until the backing gap is closed.

## The Backing Invariant

For any commitment (represented by a commitment NFT), the protocol enforces:

$$
\text{issuedUsd} \leq \text{signalUsd} + \text{settledUsd}
$$

**Where:**

- $\text{issuedUsd}$: The total USD value of effective LCC amounts issued across all positions in the commitment, computed at the current pool price using effective token amounts.
- $\text{signalUsd}$: The USD value of verified off-chain reserves declared by the Market Maker (MM) via a LiquiditySignal proof.
- $\text{settledUsd}$: The total USD value of on-chain settled liquidity across all positions in the commitment.

This invariant ensures that every LCC represents a claim on either verified reserves or settled liquidity, maintaining 1:1 backing and preventing over-issuance relative to available backing.

## When a Commitment Becomes Unbacked

A commitment becomes unbacked when:

1. **Off-chain reserves are depleted**: The MM's verified reserves (signal) decrease below the level required to back issued LCCs, potentially due to:
   - Withdrawals from reserve accounts
   - Losses in external trading
   - Regulatory actions or account freezes
   - Operational failures

2. **On-chain settlements are insufficient**: Even if signal decreases, sufficient on-chain settlements can maintain backing. However, if settlements are withdrawn or never deposited to cover the gap, the commitment becomes unbacked.

3. **Price movements**: While effective issued amounts adjust with pool price, significant price movements can expose backing gaps if reserves are not rebalanced accordingly.

The protocol does not automatically detect unbacked commitments. Instead, third parties (advancers) can prove unbacked status by submitting a new LiquiditySignal that demonstrates reduced reserves, triggering the declaration process.

## Declaration Process

### Authorisation and Verification

The `_declareUnbackedCommitment` function can be called by any party (typically a Settlement Guarantor or monitoring bot) who can prove that a commitment is unbacked. The declaration process requires:

1. **Signal verification**: The new LiquiditySignal must be valid and verified by the VRLSignalManager, which checks cryptographic proofs and updates the MM's signal nonce.

2. **Owner consistency**: The new signal must belong to the same MM owner as the original commitment, ensuring declarations target the correct commitment.

3. **Advancer authorisation**: The caller must be the advancer specified in the new signal, and the advancer cannot be the MM owner (prevents self-declaration).

4. **No self-interest**: The caller cannot be approved or owner of the commitment NFT, preventing the MM from declaring their own commitment unbacked to avoid penalties.

### Discrepancy Calculation

Once verified, the protocol computes the backing discrepancy:

$$
D = \text{issuedUsd} - (\text{signalUsd} + \text{settledUsd})
$$

If $D \leq 0$, the commitment remains backed and the declaration reverts. Otherwise, $D$ represents the USD shortfall that must be rectified.

### Commitment Deficit Application

The discrepancy $D$ is converted to a commitment deficit expressed as basis points (BPS) of issued:

$$
\text{totalDeficitBps} = \frac{D \times 10000}{\text{issuedUsd}}
$$

This ensures the deficit BPS is always $\leq 10000$ (deficit cannot exceed issued). The total deficit BPS is then averaged across all positions in the commitment using integer division (implicit floor):

$$
\text{perPosBps} = \left\lfloor \frac{\text{totalDeficitBps}}{n} \right\rfloor
$$

Where $n$ is the number of positions in the commitment. This uniform allocation applies the same deficit BPS to both tokens (`token0` and `token1`) for each position, simplifying the implementation while ensuring proportional inflation of RfS requirements. Note that integer division means the total deficit applied may be slightly less than the calculated discrepancy due to rounding, but this is acceptable as it provides a conservative estimate.

For each position, the commitment deficit units are computed and added to any existing deficit:

$$
\text{add}_0(r) = \min\left(C_0(r), \frac{C_0(r) \times \text{perPosBps}}{10000}\right)
$$

$$
\text{add}_1(r) = \min\left(C_1(r), \frac{C_1(r) \times \text{perPosBps}}{10000}\right)
$$

$$
\text{cd}_0(r) = \text{cd}_0(r) + \text{add}_0(r)
$$

$$
\text{cd}_1(r) = \text{cd}_1(r) + \text{add}_1(r)
$$

Where $C_A(r)$ is the commitment maxima for token $A$ in position $r$, and $\text{cd}_A(r)$ represents the cumulative commitment deficit units (which may already exist from prior declarations). The deficit units added per declaration are clamped to the commitment to prevent over-inflation, but cumulative deficits can exceed a single declaration's maximum if multiple declarations occur. This additive property ensures that repeated unbacked declarations compound the pressure for rectification.

### Immediate Seizure Enablement

Upon declaration, all positions in the commitment have their RfS checkpoints forced open with grace periods immediately elapsed. This enables:

1. **Immediate seizure**: Any party can immediately seize positions by settling the required amounts, without waiting for grace periods.

2. **Permissionless intervention**: The commitment owner cannot prevent seizure by extending grace periods or closing RfS through settlements alone.

3. **Market-wide awareness**: The open RfS state signals to all participants that intervention is required, creating competitive pressure for rapid resolution.

## RfS Inflation Mechanism

Commitment deficits inflate the RfS requirement for each position, ensuring that positions remain in an open RfS state until the deficit is extinguished. The RfS calculation in `_getRFS` incorporates commitment deficits as follows:

For each token $A$ in position $r$:

1. **Base requirement**: $\text{baseReq}_A = C_A(r) \times \text{baseVTSRate}_A$

2. **Deficit requirement**: $\text{defReq}_A = \min(d_A(r), C_A(r))$ where $d_A(r)$ is the cumulative deficit from attributed outflows.

3. **Combined requirement**: $\text{req}_A = \max(\text{baseReq}_A, \text{defReq}_A)$

4. **Commitment deficit inflation**: 
   $$
   \text{req}_A = \min\left(C_A(r), \text{req}_A + \text{cd}_A(r)\right)
   $$

5. **RfS delta**: $\text{rfsDelta}_A = \text{req}_A - S_A(r)$ where $S_A(r)$ is the settled amount.

If $\text{rfsDelta}_A > 0$ for either token, the RfS is open, preventing withdrawals and requiring settlements.

This inflation ensures that even if a position has sufficient settled liquidity to cover normal deficits, the commitment deficit forces additional settlement until the backing gap is closed.

## Deficit Consumption

Commitment deficits are consumed when MMs (or intervenors) settle liquidity. In `_updateSettlement`, when a positive settlement delta is applied:

1. **Real deficit netting**: First, settlements net against cumulative deficits from attributed outflows.

2. **Commitment deficit consumption**: Then, any remaining positive delta consumes commitment deficit units:
   $$
   \text{coverCd}_A = \min(\delta, \text{cd}_A(r))
   $$
   $$
   \text{cd}_A(r) = \text{cd}_A(r) - \text{coverCd}_A
   $$

3. **Settlement growth**: Only after both deficit types are extinguished does the settlement amount increase.

This consumption order ensures that settlements directly address the backing gap before accumulating excess settled liquidity, maintaining alignment with the protocol's risk management objectives.

## Rectification Paths

Once a commitment is declared unbacked, there are several paths to restore backing:

### 1. Owner Settlement

The MM can restore backing by:

- **Increasing settlements**: Depositing additional native tokens to cover the commitment deficit, which consumes deficit units and closes RfS.
- **Renewing signal**: Submitting a new LiquiditySignal with higher reserves that restores the invariant. If the new signal proves $\text{issuedUsd} \leq \text{signalUsd} + \text{settledUsd}$, all commitment deficits are cleared via `applyCommitmentDeficit(ids, 0)`.

### 2. Position Seizure

Third parties can intervene by:

- **Settling and seizing**: Posting settlement deltas to cover the inflated RfS requirements, then seizing a portion of the position proportional to their settlement contribution.
- **Seizure rewards**: The seizing party receives:
  - Seized liquidity units sized by exposure and settlement share
  - Proportional share of settled liquidity for unwind
  - The position's underlying value

This creates strong incentives for rapid intervention, as early intervenors can acquire positions at favourable terms while restoring protocol safety.

### 3. Position Decrease/Burn

If RfS closes (through sufficient settlement), the MM can decrease or burn positions, reducing issued LCCs and restoring the invariant. However, with commitment deficits inflating RfS, this path requires significant settlement first.

## Mathematical Properties

### Deficit BPS Bounds

The commitment deficit BPS calculation ensures:

- **Upper bound**: $\text{totalDeficitBps} \leq 10000$ because $D \leq \text{issuedUsd}$ (deficit cannot exceed issued).
- **Lower bound**: $\text{totalDeficitBps} \geq 0$ by definition (only declared when $D > 0$).

### Additive Deficit Accumulation

Commitment deficits are **additive**: if a commitment is declared unbacked multiple times, each declaration adds to the existing commitment deficit units. This ensures that repeated unbacked declarations compound the pressure for rectification, preventing MMs from repeatedly allowing their commitments to become unbacked without consequence. The cumulative deficit units can exceed the commitment maxima if multiple declarations occur, though each individual declaration's addition is clamped to prevent over-inflation in a single step.

### Total Inflation Accuracy

For a single declaration, the total inflation across all positions approximates the discrepancy $D$:

$$
\sum_{r} \left(\text{add}_0(r) + \text{add}_1(r)\right) \approx D
$$

Where $\text{add}_A(r)$ represents the deficit units added in this declaration for token $A$ in position $r$. The approximation includes minor rounding from:

- Integer division when averaging BPS across positions
- Clamping to commitment maxima per position (each addition is clamped, but cumulative deficits can exceed commitment if multiple declarations occur)
- USD to token unit conversion via oracle prices

Note that due to the additive nature of commitment deficits, the cumulative total across all positions may exceed $D$ if multiple declarations occur before deficits are consumed.

### Consumption Invariant

After settlements consume commitment deficits, the remaining deficit units satisfy:

$$
\sum_{r} \left(\text{cd}_0(r) + \text{cd}_1(r)\right) \leq \sum_{i} D_i - \text{settledAmount}
$$

Where $D_i$ represents the discrepancy from declaration $i$, and $\text{settledAmount}$ is the USD value of settlements that consumed deficit units. This ensures that:

1. For a single declaration, the remaining deficit decreases monotonically as settlements are posted.
2. For multiple declarations, the cumulative deficit reflects the sum of all unrectified discrepancies, minus settlements that have consumed deficit units.
3. The deficit can exceed any single declaration's discrepancy if multiple declarations occur before consumption.

## Gas Optimisation

The implementation includes several gas optimisations:

1. **Single BPS parameter**: Instead of per-position arrays, a single `totalDeficitBps` is passed and averaged internally, reducing calldata size.

2. **Uniform application**: The same BPS is applied to both tokens, eliminating per-token price lookups and allocation calculations.

3. **Batch operations**: All positions are processed in a single call, enabling efficient batch updates.

4. **Position limit**: A `MAX_POSITIONS_PER_COMMITMENT` constant (250) prevents gas exhaustion from commitments with excessive positions.

## Security Considerations

### Self-Declaration Prevention

The declaration process prevents MMs from declaring their own commitments unbacked by:

- Requiring the caller to be the advancer (not the owner)
- Checking that the caller is not approved or owner of the commitment NFT
- Ensuring advancer ≠ owner in the signal

### Oracle Reliance

The discrepancy calculation relies on oracle prices to convert token amounts to USD. If oracles are manipulated or stale, declarations may be inaccurate. However:

- Declarations require valid signal proofs, limiting manipulation vectors
- Multiple parties can declare, creating competitive pressure for accurate declarations
- The protocol's risk management mechanisms (RfS, seizures) provide additional safety layers

### Grace Period Bypass

Forcing grace periods to elapse immediately enables rapid intervention but removes the MM's ability to self-rectify during grace. This is intentional: unbacked commitments represent a systemic risk that requires immediate attention, and the MM retains the ability to settle proactively before declaration.

## Example Scenario

Consider a commitment with:

- **Issued**: 100,000 USD (effective LCC amounts at current price)
- **Signal**: 60,000 USD (verified reserves)
- **Settled**: 30,000 USD (on-chain liquidity)
- **Backing**: 60,000 + 30,000 = 90,000 USD
- **Discrepancy**: $D = 100,000 - 90,000 = 10,000$ USD

The commitment deficit BPS is:
$$
\text{totalDeficitBps} = \frac{10,000 \times 10000}{100,000} = 1000 \text{ BPS}
$$

If the commitment has 5 positions, each position receives:
$$
\text{perPosBps} = \frac{1000}{5} = 200 \text{ BPS}
$$

For a position with commitments $C_0 = 20,000$ and $C_1 = 20,000$ (in token units), the deficit units added are:
$$
\text{add}_0 = \frac{20,000 \times 200}{10000} = 400 \text{ units}
$$
$$
\text{add}_1 = \frac{20,000 \times 200}{10000} = 400 \text{ units}
$$

If this is the first declaration, then $\text{cd}_0 = 400$ and $\text{cd}_1 = 400$. If the position already had commitment deficits from a prior declaration, these amounts are added to the existing deficits. These deficit units inflate the RfS requirement, forcing the position into an open RfS state until the commitment deficits are consumed through settlements or the signal is renewed to restore backing (which clears all commitment deficits).

## Conclusion

The unbacked commitment declaration mechanism provides a robust, permissionless way to detect and rectify backing shortfalls in the Fiet Protocol. By inflating RfS requirements through commitment deficits and enabling immediate seizure, the system creates strong incentives for rapid intervention while maintaining the critical 1:1 backing invariant. The uniform BPS allocation simplifies implementation while ensuring proportional inflation across positions, and the consumption mechanism ensures settlements directly address backing gaps before accumulating excess liquidity.
