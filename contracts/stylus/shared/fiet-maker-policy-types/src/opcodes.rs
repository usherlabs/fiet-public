use alloc::vec::Vec;

use alloy_primitives::{Address, FixedBytes, U256};

/// Comparison operators for numeric checks.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompOp {
    Lt,
    Lte,
    Gt,
    Gte,
    Eq,
    Neq,
}

/// Opcodes supported by the v0 check program.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Opcode {
    CheckDeadline = 0x01,
    CheckNonce = 0x02,
    CheckCallBundleHash = 0x03,

    CheckTokenAmountLte = 0x11,
    CheckNativeValueLte = 0x12,
    CheckLiquidityDeltaLte = 0x13,

    CheckSlot0TickBounds = 0x20,
    CheckSlot0SqrtPriceBounds = 0x21,

    CheckRfsClosed = 0x30,
    CheckQueueLte = 0x31,
    CheckReserveGte = 0x32,
    CheckSettledGte = 0x33,
    CheckCommitmentDeficitLte = 0x34,
    CheckGracePeriodGte = 0x35,

    CheckStaticCallU256 = 0xF0,
}

/// Decoded representation of a single check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Check {
    Deadline { deadline: u64 },
    Nonce { expected: U256 },
    CallBundleHash { hash: FixedBytes<32> },

    TokenAmountLte { token: Address, max: U256 },
    NativeValueLte { max: U256 },
    LiquidityDeltaLte { max: u128 },

    Slot0TickBounds {
        pool_id: FixedBytes<32>,
        min: i32,
        max: i32,
    },
    Slot0SqrtPriceBounds {
        pool_id: FixedBytes<32>,
        min: U256,
        max: U256,
    },

    RfsClosed { position_id: FixedBytes<32> },
    QueueLte { lcc: Address, owner: Address, max: U256 },
    ReserveGte { lcc: Address, min: U256 },
    SettledGte {
        position_id: FixedBytes<32>,
        min_amount0: U256,
        min_amount1: U256,
    },
    CommitmentDeficitLte {
        position_id: FixedBytes<32>,
        max_deficit0: U256,
        max_deficit1: U256,
    },
    GracePeriodGte {
        position_id: FixedBytes<32>,
        min_seconds: u64,
    },

    StaticCallU256 {
        target: Address,
        selector: [u8; 4],
        args: Vec<u8>,
        op: CompOp,
        rhs: U256,
    },
}

impl TryFrom<u8> for Opcode {
    type Error = ();

    fn try_from(value: u8) -> Result<Self, Self::Error> {
        use Opcode::*;
        let op = match value {
            0x01 => CheckDeadline,
            0x02 => CheckNonce,
            0x03 => CheckCallBundleHash,
            0x11 => CheckTokenAmountLte,
            0x12 => CheckNativeValueLte,
            0x13 => CheckLiquidityDeltaLte,
            0x20 => CheckSlot0TickBounds,
            0x21 => CheckSlot0SqrtPriceBounds,
            0x30 => CheckRfsClosed,
            0x31 => CheckQueueLte,
            0x32 => CheckReserveGte,
            0x33 => CheckSettledGte,
            0x34 => CheckCommitmentDeficitLte,
            0x35 => CheckGracePeriodGte,
            0xF0 => CheckStaticCallU256,
            _ => return Err(()),
        };
        Ok(op)
    }
}

