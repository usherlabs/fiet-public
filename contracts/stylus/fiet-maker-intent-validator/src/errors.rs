use stylus_sdk::alloy_primitives::Address;

/// Errors during program decoding.
#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    UnknownOpcode(u8),
    Truncated,
    TooManyChecks,
}

/// Errors during fact acquisition.
#[derive(Debug, PartialEq, Eq)]
pub enum FactsError {
    ForbiddenCall { target: Address, selector: [u8; 4] },
    CallFailed,
    MalformedReturn,
}

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

