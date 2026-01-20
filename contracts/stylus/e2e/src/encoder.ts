import {
  Address,
  Hex,
  hexToBytes,
  keccak256,
  pad,
  toHex,
} from "viem";
import { Check, CompOp, IntentEnvelope, Opcode } from "./types.js";

// Helpers to write big-endian integers
function beBytes(value: bigint, size: number): Uint8Array {
  const hex = pad(toHex(value), { size });
  return hexToBytes(hex);
}

function beU64(value: bigint): Uint8Array {
  return beBytes(value, 32).slice(24); // take last 8 bytes
}

function beU32(value: number): Uint8Array {
  const hex = pad(toHex(BigInt(value)), { size: 8 });
  return hexToBytes(hex).slice(4);
}

function beU16(value: number): Uint8Array {
  const hex = pad(toHex(BigInt(value)), { size: 4 });
  return hexToBytes(hex).slice(6);
}

function writeAddress(addr: Address): Uint8Array {
  return hexToBytes(pad(addr, { size: 40 }));
}

function writeB32(hex: Hex): Uint8Array {
  const padded = pad(hex, { size: 64 });
  return hexToBytes(padded);
}

function writeSelector(sel: Hex): Uint8Array {
  const padded = pad(sel, { size: 8 });
  return hexToBytes(padded).slice(28);
}

function keccakBytes(bytes: Uint8Array): Hex {
  return keccak256(bytes);
}

export function encodeProgram(checks: Check[]): Uint8Array {
  const chunks: Uint8Array[] = [];

  for (const c of checks) {
    switch (c.kind) {
      case Opcode.CheckDeadline: {
        chunks.push(new Uint8Array([Opcode.CheckDeadline]));
        chunks.push(beU64(c.deadline));
        break;
      }
      case Opcode.CheckNonce: {
        chunks.push(new Uint8Array([Opcode.CheckNonce]));
        chunks.push(beBytes(c.expected, 32));
        break;
      }
      case Opcode.CheckCallBundleHash: {
        chunks.push(new Uint8Array([Opcode.CheckCallBundleHash]));
        chunks.push(writeB32(c.hash));
        break;
      }
      case Opcode.CheckTokenAmountLte: {
        chunks.push(new Uint8Array([Opcode.CheckTokenAmountLte]));
        chunks.push(writeAddress(c.token));
        chunks.push(beBytes(c.max, 32));
        break;
      }
      case Opcode.CheckNativeValueLte: {
        chunks.push(new Uint8Array([Opcode.CheckNativeValueLte]));
        chunks.push(beBytes(c.max, 32));
        break;
      }
      case Opcode.CheckLiquidityDeltaLte: {
        chunks.push(new Uint8Array([Opcode.CheckLiquidityDeltaLte]));
        chunks.push(beBytes(c.max, 16));
        break;
      }
      case Opcode.CheckSlot0TickBounds: {
        chunks.push(new Uint8Array([Opcode.CheckSlot0TickBounds]));
        chunks.push(writeB32(c.poolId));
        chunks.push(beBytes(BigInt(c.min), 4));
        chunks.push(beBytes(BigInt(c.max), 4));
        break;
      }
      case Opcode.CheckSlot0SqrtPriceBounds: {
        chunks.push(new Uint8Array([Opcode.CheckSlot0SqrtPriceBounds]));
        chunks.push(writeB32(c.poolId));
        chunks.push(beBytes(c.min, 32));
        chunks.push(beBytes(c.max, 32));
        break;
      }
      case Opcode.CheckRfsClosed: {
        chunks.push(new Uint8Array([Opcode.CheckRfsClosed]));
        chunks.push(writeB32(c.positionId));
        break;
      }
      case Opcode.CheckQueueLte: {
        chunks.push(new Uint8Array([Opcode.CheckQueueLte]));
        chunks.push(writeAddress(c.lcc));
        chunks.push(writeAddress(c.owner));
        chunks.push(beBytes(c.max, 32));
        break;
      }
      case Opcode.CheckReserveGte: {
        chunks.push(new Uint8Array([Opcode.CheckReserveGte]));
        chunks.push(writeAddress(c.lcc));
        chunks.push(beBytes(c.min, 32));
        break;
      }
      case Opcode.CheckSettledGte: {
        chunks.push(new Uint8Array([Opcode.CheckSettledGte]));
        chunks.push(writeB32(c.positionId));
        chunks.push(beBytes(c.minAmount0, 32));
        chunks.push(beBytes(c.minAmount1, 32));
        break;
      }
      case Opcode.CheckCommitmentDeficitLte: {
        chunks.push(new Uint8Array([Opcode.CheckCommitmentDeficitLte]));
        chunks.push(writeB32(c.positionId));
        chunks.push(beBytes(c.maxDeficit0, 32));
        chunks.push(beBytes(c.maxDeficit1, 32));
        break;
      }
      case Opcode.CheckGracePeriodGte: {
        chunks.push(new Uint8Array([Opcode.CheckGracePeriodGte]));
        chunks.push(writeB32(c.positionId));
        chunks.push(beU64(c.minSeconds));
        break;
      }
      case Opcode.CheckStaticCallU256: {
        chunks.push(new Uint8Array([Opcode.CheckStaticCallU256]));
        chunks.push(writeAddress(c.target));
        chunks.push(writeSelector(c.selector));
        const argBytes = hexToBytes(c.args);
        chunks.push(beU16(argBytes.length));
        chunks.push(argBytes);
        chunks.push(new Uint8Array([c.op]));
        chunks.push(beBytes(c.rhs, 32));
        break;
      }
      default:
        throw new Error(`Unknown opcode ${(c as Check).kind}`);
    }
  }

  const total = chunks.reduce((acc, cur) => acc + cur.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}

// Encode the policy-local envelope placed into the policy signature slice.
// Layout matches `parse_policy_envelope` in the Stylus policy:
// - u16 version
// - bytes32 nonce
// - u64 deadline
// - bytes32 callBundleHash
// - u32 programLen
// - bytes programBytes
// - u16 sigLen (must be 65)
// - bytes signature (r||s||v)
export function encodeEnvelope(envelope: IntentEnvelope, signature: Uint8Array): Hex {
  const parts: Uint8Array[] = [];
  parts.push(beU16(envelope.version));
  parts.push(beBytes(envelope.nonce, 32));
  parts.push(beU64(envelope.deadline));
  parts.push(writeB32(envelope.callBundleHash));
  parts.push(beU32(envelope.programBytes.length));
  parts.push(envelope.programBytes);
  parts.push(beU16(signature.length));
  parts.push(signature);

  return toHex(concatUint8(parts));
}

/**
 * Sign the policy envelope using EIP-712 typed data.
 *
 * Purpose: the policy payload is passed in a "policy-local signature slice" by Kernel's permission pipeline.
 * That slice is not automatically bound to the account signature, so we must explicitly sign the envelope
 * to prevent payload tampering (e.g. swapping `programBytes` to a trivially passing program).
 */
export async function signEnvelope(params: {
  chainId: bigint;
  verifyingContract: Address; // intent policy contract address
  wallet: Address; // smart account address (msg.sender in policy check)
  permissionId: Hex; // bytes32 permission id
  envelope: IntentEnvelope;
  signTypedData: (args: any) => Promise<Hex>;
}): Promise<Uint8Array> {
  const { chainId, verifyingContract, wallet, permissionId, envelope, signTypedData } = params;
  const programHash = keccakBytes(envelope.programBytes);

  const signatureHex = await signTypedData({
    domain: {
      name: "Fiet Maker Intent Policy",
      version: "1",
      chainId,
      verifyingContract,
    },
    types: {
      IntentPolicyEnvelope: [
        { name: "wallet", type: "address" },
        { name: "permissionId", type: "bytes32" },
        { name: "nonce", type: "uint256" },
        { name: "deadline", type: "uint64" },
        { name: "callBundleHash", type: "bytes32" },
        { name: "programHash", type: "bytes32" },
      ],
    },
    primaryType: "IntentPolicyEnvelope",
    message: {
      wallet,
      permissionId,
      nonce: envelope.nonce,
      deadline: envelope.deadline,
      callBundleHash: envelope.callBundleHash,
      programHash,
    },
  });

  return hexToBytes(signatureHex);
}

export function concatUint8(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((acc, cur) => acc + cur.length, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.length;
  }
  return out;
}
