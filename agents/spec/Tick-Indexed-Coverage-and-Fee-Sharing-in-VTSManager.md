# Tick-Indexed Coverage and Fee-Sharing Mechanics in VTSManager — Research Document

## Introduction

The VTSManager contract is integral to the Fiet Protocol, overseeing Value-to-Signal (VTS) calculations, position settlements, and fee-sharing mechanisms for liquidity positions. It employs a tick-indexed growth accounting system, akin to that in Uniswap v3, to attribute coverage usage and fees equitably across in-range positions. Coverage mechanisms track proactive settlements that support outflows, such as those occurring during Liquidity Commitment Certificate (LCC) unwraps. Meanwhile, fee-sharing penalises positions that incur deficits through slashes and rewards contributors via bonuses drawn from a shared pot. The primary objectives are to ensure fair attribution of obligations and rewards based on actual contributions to coverage, prevent positions from benefiting from their own penalties, and materialise adjustments during liquidity modification hooks.

## Tick-Indexed Coverage Mechanics

Coverage accrual in VTSManager utilises a growth-per-unit accounting approach, distributing usage proportionally among in-range positions that provide proactive backing. This system ensures that only actively contributing positions bear the load of outflows, with growth metrics updated dynamically.

Global growth (G), outside-tick growth (O_i), and inside-position snapshots (I_r) are maintained to track coverage usage. Upon an unwrap outflow U_A for token A, if in-range liquidity L > 0, the global growth increment is calculated as:

$$
\delta G = \frac{U_A \cdot Q128}{L}
$$

The global G_A is then updated by adding \delta G. If no in-range liquidity exists, the amount is deferred to a residual R_A, which is applied upon the next tick activation when liquidity becomes available.

During position settlement, usage deltas are computed and checkpointed. For a position r, the delta cov is derived from growth differences scaled by liquidity. If cov > 0 and a deficit D_r exists, a fee slash is triggered on the exercised portion, defined by burnBase = min(cEff, D), where cEff = min(cov, D + S) and S is the position's settled liquidity.

Tick crosses flip outside values and apply any residuals if L > 0 post-cross, ensuring accurate attribution as the price moves.

This mechanism attributes coverage solely to active positions with proactive settlements, promoting efficient liquidity provision.

## Fee-Sharing Dynamics

Fee-sharing in VTSManager slashes fees from positions responsible for deficits, as determined by coverage usage, and redistributes these via bonuses to positions contributing settled liquidity. Slashes fund a global pot, from which bonuses are allocated based on proportional contributions, with self-exclusion to prevent reclaiming one's own penalties.

### Slash Mechanics

Slashes occur during coverage settlement when cov > 0. Fees accrued since the last snapshot are computed and normalised by the outflow window ofDelta. The burn amount is then determined as:

$$
feesBurn = fees \cdot \left( \frac{burnBase}{ofDelta} \right) \cdot \frac{bps}{10000}
$$

where burnBase = min(cEff, D), cEff = min(cov, D + S), D is the position's deficit, S is its settled liquidity, and bps is the coverage fee share basis points. The fee growth baseline is advanced to effectively burn the entitlement, and feesBurn is added to protocolFeeAccrued while being queued as a positive pending adjustment for later materialisation.

### Bonus Mechanics

Bonuses are queued upon changes to settled liquidity. The available pot excludes the position's own contributed slashes:

$$
potAvail = \max(protocolFeeAccrued - selfContrib, 0)
$$

The bonus is weighted by the position's contribution:

$$
bonus = potAvail \cdot \frac{selfS}{totalS}
$$

where selfS is the position's totalSettlementAmount, and totalS is the sum across all positions. The pot is deducted accordingly, and the bonus is queued as a negative pending adjustment, increasing the payout at materialisation.

### Netting and Materialisation

Netting combines slashes (positive) and bonuses (negative) into a signed pending adjustment per position and token. At liquidity modification hooks (afterAddLiquidity or afterRemoveLiquidity), the pending values are consumed and returned as a BalanceDelta without sign flip: positive for slashes (hook takes from LP), negative for bonuses (hook gives to LP). This delta is deducted from the caller's default delta in the Uniswap Hooks library, ensuring adjustments materialise correctly.

## Integration with Hooks and Settlements

Settlements via onMMLiquidityModify queue bonuses without altering the settlement delta, preserving separation. Liquidity modifications through _touchPosition settle growths and queue bonuses. In CoreHook, consumption occurs in the after hooks, with the net delta returned for Uniswap to apply.

This model fosters fairness by rewarding net contributors and penalising deficits, while efficiently handling coverage through tick-indexed attribution.
