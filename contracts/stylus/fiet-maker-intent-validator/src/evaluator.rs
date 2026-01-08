use crate::{
    errors::ValidationError,
    types::{
        facts::FactsProvider,
        opcodes::{Check, CompOp},
    },
};

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
