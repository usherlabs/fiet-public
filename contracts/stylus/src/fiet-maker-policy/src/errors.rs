/// Errors during program decoding.
#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    UnknownOpcode(u8),
    Truncated,
    TooManyChecks,
}

/// Errors during fact acquisition.
pub use fiet_maker_policy_types::FactsError;

/// Errors during validation/evaluation.
#[derive(Debug, PartialEq, Eq)]
pub enum ValidationError {
    UnsupportedCheck,
    DeadlineExpired,
    NonceMismatch,
    CallBundleMismatch,
    TokenNotAllowed,
    TokenAmountExceeded,
    NativeValueExceeded,
    LiquidityDeltaExceeded,
    TickOutOfBounds,
    PriceOutOfBounds,
    RfsNotClosed,
    QueueExceeded,
    ReserveTooLow,
    StaticCallFailed,
}

