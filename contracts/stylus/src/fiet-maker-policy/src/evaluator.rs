use crate::{
    errors::ValidationError,
    types::{
        facts::FactsProvider,
        opcodes::{Check, CompOp},
    },
};

use stylus_sdk::alloy_primitives::U256;

/// Evaluate checks against provided facts provider.
pub fn evaluate_program<F: FactsProvider>(
    checks: &[Check],
    facts: &F,
) -> Result<(), ValidationError> {
    for check in checks {
        match check {
            Check::Deadline { deadline } => {
                if facts.block_timestamp() > *deadline {
                    return Err(ValidationError::DeadlineExpired);
                }
            }
            Check::Nonce { .. } => {
                // Nonce is enforced by caller (validator storage); skip here.
            }
            Check::CallBundleHash { .. } => {
                // Call bundle hash binding is enforced by caller.
            }
            Check::TokenAmountLte { token, max } => {
                // NOTE: requires execution-context parsing (call bundle -> token+amount). Fail closed for now.
                let _ = token;
                let _ = max;
                return Err(ValidationError::UnsupportedCheck);
            }
            Check::NativeValueLte { max } => {
                let _ = max;
                return Err(ValidationError::UnsupportedCheck);
            }
            Check::LiquidityDeltaLte { max } => {
                let _ = max;
                return Err(ValidationError::UnsupportedCheck);
            }
            Check::Slot0TickBounds { pool_id, min, max } => {
                let slot0 = facts
                    .get_slot0(*pool_id)
                    .map_err(|_| ValidationError::TickOutOfBounds)?;
                if slot0.tick < *min || slot0.tick > *max {
                    return Err(ValidationError::TickOutOfBounds);
                }
            }
            Check::Slot0SqrtPriceBounds { pool_id, min, max } => {
                let slot0 = facts
                    .get_slot0(*pool_id)
                    .map_err(|_| ValidationError::PriceOutOfBounds)?;
                if slot0.sqrt_price_x96 < *min || slot0.sqrt_price_x96 > *max {
                    return Err(ValidationError::PriceOutOfBounds);
                }
            }
            Check::RfsClosed { position_id } => {
                let closed = facts
                    .is_rfs_closed(*position_id)
                    .map_err(|_| ValidationError::RfsNotClosed)?;
                if !closed {
                    return Err(ValidationError::RfsNotClosed);
                }
            }
            Check::QueueLte { lcc, owner, max } => {
                let queued = facts
                    .queue_amount(*lcc, *owner)
                    .map_err(|_| ValidationError::QueueExceeded)?;
                if queued > *max {
                    return Err(ValidationError::QueueExceeded);
                }
            }
            Check::ReserveGte { lcc, min } => {
                let reserve = facts
                    .reserve_of(*lcc)
                    .map_err(|_| ValidationError::ReserveTooLow)?;
                if reserve < *min {
                    return Err(ValidationError::ReserveTooLow);
                }
            }
            Check::SettledGte {
                position_id,
                min_amount0,
                min_amount1,
            } => {
                let (amount0, amount1) = facts
                    .get_settled_amounts(*position_id)
                    .map_err(|_| ValidationError::StaticCallFailed)?;
                if amount0 < *min_amount0 || amount1 < *min_amount1 {
                    return Err(ValidationError::StaticCallFailed);
                }
            }
            Check::CommitmentDeficitLte {
                position_id,
                max_deficit0,
                max_deficit1,
            } => {
                let (commitment0, commitment1) = facts
                    .get_commitment_maxima(*position_id)
                    .map_err(|_| ValidationError::StaticCallFailed)?;
                let (settled0, settled1) = facts
                    .get_settled_amounts(*position_id)
                    .map_err(|_| ValidationError::StaticCallFailed)?;
                // Deficit = commitment - settled (saturating subtraction)
                let deficit0 = if commitment0 > settled0 {
                    commitment0 - settled0
                } else {
                    U256::ZERO
                };
                let deficit1 = if commitment1 > settled1 {
                    commitment1 - settled1
                } else {
                    U256::ZERO
                };
                if deficit0 > *max_deficit0 || deficit1 > *max_deficit1 {
                    return Err(ValidationError::StaticCallFailed);
                }
            }
            Check::GracePeriodGte {
                position_id,
                min_seconds,
            } => {
                // grace_period_remaining returns seconds remaining until the position becomes
                // seizable under the "normal RFS path" (earliest of the per-token grace thresholds),
                // or u64::MAX when RFS is closed.
                let remaining = facts
                    .grace_period_remaining(*position_id)
                    .map_err(|_| ValidationError::StaticCallFailed)?;
                if remaining != u64::MAX && remaining < *min_seconds {
                    return Err(ValidationError::StaticCallFailed);
                }
            }
            Check::StaticCallU256 {
                target,
                selector,
                args,
                op,
                rhs,
            } => {
                let lhs = facts
                    .staticcall_u256(*target, *selector, args)
                    .map_err(|_| ValidationError::StaticCallFailed)?;
                if !compare(lhs, *op, *rhs) {
                    return Err(ValidationError::StaticCallFailed);
                }
            }
        }
    }
    Ok(())
}

fn compare(
    lhs: stylus_sdk::alloy_primitives::U256,
    op: CompOp,
    rhs: stylus_sdk::alloy_primitives::U256,
) -> bool {
    match op {
        CompOp::Lt => lhs < rhs,
        CompOp::Lte => lhs <= rhs,
        CompOp::Gt => lhs > rhs,
        CompOp::Gte => lhs >= rhs,
        CompOp::Eq => lhs == rhs,
        CompOp::Neq => lhs != rhs,
    }
}
