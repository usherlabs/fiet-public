import { Address, Hex } from "viem";

export enum CompOp {
  Lt = 0,
  Lte = 1,
  Gt = 2,
  Gte = 3,
  Eq = 4,
  Neq = 5,
}

export enum Opcode {
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

  CheckStaticCallU256 = 0xf0,
}

export type Check =
  | { kind: Opcode.CheckDeadline; deadline: bigint }
  | { kind: Opcode.CheckNonce; expected: bigint }
  | { kind: Opcode.CheckCallBundleHash; hash: Hex }
  | { kind: Opcode.CheckTokenAmountLte; token: Address; max: bigint }
  | { kind: Opcode.CheckNativeValueLte; max: bigint }
  | { kind: Opcode.CheckLiquidityDeltaLte; max: bigint }
  | { kind: Opcode.CheckSlot0TickBounds; poolId: Hex; min: number; max: number }
  | { kind: Opcode.CheckSlot0SqrtPriceBounds; poolId: Hex; min: bigint; max: bigint }
  | { kind: Opcode.CheckRfsClosed; positionId: Hex }
  | { kind: Opcode.CheckQueueLte; lcc: Address; owner: Address; max: bigint }
  | { kind: Opcode.CheckReserveGte; lcc: Address; min: bigint }
  | { kind: Opcode.CheckSettledGte; positionId: Hex; minAmount0: bigint; minAmount1: bigint }
  | { kind: Opcode.CheckCommitmentDeficitLte; positionId: Hex; maxDeficit0: bigint; maxDeficit1: bigint }
  | { kind: Opcode.CheckGracePeriodGte; positionId: Hex; minSeconds: bigint }
  | { kind: Opcode.CheckStaticCallU256; target: Address; selector: Hex; args: Hex; op: CompOp; rhs: bigint };

export interface IntentEnvelope {
  version: number;
  nonce: bigint;
  deadline: bigint;
  callBundleHash: Hex;
  programBytes: Uint8Array;
}

