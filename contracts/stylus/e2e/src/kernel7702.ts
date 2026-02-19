import {
  Address,
  Hex,
  concatHex,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  getAbiItem,
  getFunctionSelector,
  hexToBigInt,
  padHex,
} from "viem";

import { TestEnv, buildIntentPolicyInitData, buildSignedEnvelope } from "./setup.js";
import { Check } from "./types.js";
import { buildCallPolicyInitData } from "./policies.js";

// --- Minimal ABIs ---

export const KernelExecuteABI = [
  {
    type: "function",
    name: "execute",
    stateMutability: "payable",
    inputs: [
      { name: "execMode", type: "bytes32" },
      { name: "executionCalldata", type: "bytes" },
    ],
    outputs: [],
  },
] as const;

export const KernelViewABI = [
  ...KernelExecuteABI,
  {
    type: "function",
    name: "currentNonce",
    stateMutability: "view",
    inputs: [],
    outputs: [{ type: "uint32" }],
  },
  {
    type: "function",
    name: "validationConfig",
    stateMutability: "view",
    inputs: [{ name: "vId", type: "bytes21" }],
    outputs: [
      {
        type: "tuple",
        components: [
          { name: "nonce", type: "uint32" },
          { name: "hook", type: "address" },
        ],
      },
    ],
  },
] as const;

export const EntryPointV07ABI = [
  {
    type: "function",
    name: "getNonce",
    stateMutability: "view",
    inputs: [
      { name: "sender", type: "address" },
      { name: "key", type: "uint192" },
    ],
    outputs: [{ name: "nonce", type: "uint256" }],
  },
  {
    type: "function",
    name: "getUserOpHash",
    stateMutability: "view",
    inputs: [
      {
        name: "userOp",
        type: "tuple",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
    ],
    outputs: [{ name: "hash", type: "bytes32" }],
  },
  {
    type: "function",
    name: "handleOps",
    stateMutability: "nonpayable",
    inputs: [
      {
        name: "ops",
        type: "tuple[]",
        components: [
          { name: "sender", type: "address" },
          { name: "nonce", type: "uint256" },
          { name: "initCode", type: "bytes" },
          { name: "callData", type: "bytes" },
          { name: "accountGasLimits", type: "bytes32" },
          { name: "preVerificationGas", type: "uint256" },
          { name: "gasFees", type: "bytes32" },
          { name: "paymasterAndData", type: "bytes" },
          { name: "signature", type: "bytes" },
        ],
      },
      { name: "beneficiary", type: "address" },
    ],
    outputs: [],
  },
] as const;

// --- Kernel nonce key encoding (Kernel v3.3) ---
// `encodeAsNonceKey(mode, vType, vIdWithoutType, parallelKey)` -> uint192
// packed as bytes24: [mode:1][vType:1][vIdWithoutType:20][parallelKey:2]
function encodeNonceKey(params: {
  mode: number; // uint8
  vType: number; // uint8
  vIdWithoutType: Hex; // 20 bytes
  parallelKey?: number; // uint16
}): bigint {
  const { mode, vType, vIdWithoutType } = params;
  const parallelKey = params.parallelKey ?? 0;
  const modeHex = padHex(`0x${mode.toString(16)}`, { size: 1 });
  const typeHex = padHex(`0x${vType.toString(16)}`, { size: 1 });
  const vId20 = padHex(vIdWithoutType, { size: 20 });
  const pkHex = padHex(`0x${parallelKey.toString(16)}`, { size: 2 });
  const packed = concatHex([modeHex, typeHex, vId20, pkHex]); // 24 bytes
  return hexToBigInt(packed);
}

export function permissionId32ToPermissionId4(permissionId: Hex): Hex {
  // Kernel PermissionId is bytes4; Kernel casts to bytes32 when calling policies.
  // We enforce the convention that the bytes32 is `bytes4 || 28x00` so it round-trips cleanly.
  if (permissionId.length !== 66) throw new Error("permissionId must be bytes32 hex");
  const tail = (`0x${permissionId.slice(10)}`) as Hex;
  if (tail !== (`0x${"00".repeat(28)}` as Hex)) {
    throw new Error(
      "PERMISSION_ID must be bytes4 left-aligned (eg 0xdeadbeef0000..00) for Kernel v3.3",
    );
  }
  return (`0x${permissionId.slice(2, 10)}` as Hex);
}

export function permissionValidationId(permissionId4: Hex): Hex {
  // bytes21 validationId = bytes1(vType=0x02) || bytes20(vIdWithoutType)
  // for permission: vIdWithoutType = bytes20(permissionId4 || 16x00)
  const vType = padHex("0x02", { size: 1 });
  const vIdWithoutType20 = padHex(
    concatHex([permissionId4, `0x${"00".repeat(16)}`]),
    { size: 20 },
  );
  return concatHex([vType, vIdWithoutType20]); // 21 bytes
}

function encodeKernelExecuteSingle(params: {
  to: Address;
  value: bigint;
  data: Hex;
}): Hex {
  const { to, value, data } = params;
  const execModeZero = `0x${"00".repeat(32)}` as Hex;

  // ExecLib.encodeSingle is `abi.encodePacked(address,uint256,bytes)`
  const encodedSingle = concatHex([to, padHex(`0x${value.toString(16)}`, { size: 32 }), data]);

  return encodeFunctionData({
    abi: KernelExecuteABI,
    functionName: "execute",
    args: [execModeZero, encodedSingle],
  });
}

function encodePolicyDataBytes22(params: {
  skipUserOp: boolean;
  skipSignature: boolean;
  module: Address;
}): Hex {
  // Kernel encodes PolicyData as bytes22: [PassFlag:2][address:20]
  // PassFlag bits: 0x0001 SKIP_USEROP, 0x0002 SKIP_SIGNATURE
  const flag =
    (params.skipUserOp ? 0x0001 : 0) | (params.skipSignature ? 0x0002 : 0);
  const flagHex = padHex(`0x${flag.toString(16)}`, { size: 2 });
  return concatHex([flagHex, params.module]);
}

function encodePermissionEnableData(params: {
  env: TestEnv;
  permissionId32: Hex;
}): Hex {
  const { env, permissionId32 } = params;

  const callPolicyInit = buildCallPolicyInitData({
    mmPositionManager: env.mmPositionManager as Address,
    positionManager: env.positionManager as Address,
  });

  const intentInit = buildIntentPolicyInitData({
    signer: env.owner.address,
    stateView: env.stateView,
    vtsOrchestrator: env.vtsOrchestrator,
    liquidityHub: env.liquidityHub,
  });

  const callPolicyData = encodePolicyDataBytes22({
    skipUserOp: false,
    skipSignature: false,
    module: env.callPolicy as Address,
  });
  const intentPolicyData = encodePolicyDataBytes22({
    skipUserOp: false,
    skipSignature: false,
    module: env.intentPolicy as Address,
  });
  const signerData = encodePolicyDataBytes22({
    skipUserOp: false,
    skipSignature: false,
    module: env.multichainSigner as Address,
  });

  // Kernel expects each entry as `bytes22 PolicyData || initData`.
  const entries: Hex[] = [
    concatHex([callPolicyData, callPolicyInit]),
    concatHex([intentPolicyData, intentInit]),
    // MultiChainSigner init data is bytes20 owner address.
    concatHex([signerData, env.owner.address]),
  ];

  return encodeAbiParameters([{ type: "bytes[]" }], [entries]) as Hex;
}

function packPolicyAndSignerSigs(params: {
  // policy index -> sig bytes (only include indices that have a non-empty signature)
  policySigs: Array<{ index: number; sig: Hex }>;
  signerSig: Hex;
}): Hex {
  const parts: Hex[] = [];
  for (const { index, sig } of params.policySigs.sort((a, b) => a.index - b.index)) {
    if (sig === "0x") continue;
    const idx = padHex(`0x${index.toString(16)}`, { size: 1 });
    // uint64 length, big-endian
    const len = (sig.length - 2) / 2;
    const lenHex = padHex(`0x${len.toString(16)}`, { size: 8 });
    parts.push(idx, lenHex, sig);
  }
  // signer prefix
  parts.push("0xff", params.signerSig);
  return concatHex(parts);
}

async function buildPermissionUserOpSig(params: {
  env: TestEnv;
  sender: Address; // EOA address
  userOpHash: Hex;
  kernelCallData: Hex;
  intentChecks: Check[];
  intentNonce: bigint;
  intentDeadline: bigint;
}): Promise<Hex> {
  const { env } = params;

  const callBundleHash = keccak256(params.kernelCallData) as Hex;
  const intentEnvelope = await buildSignedEnvelope({
    env,
    smartAccount: params.sender,
    checks: params.intentChecks,
    callBundleHash,
    nonce: params.intentNonce,
    deadline: params.intentDeadline,
  });

  // MultiChainSigner accepts either direct `userOpHash` sig or EIP-191.
  const signerSig = (await env.owner.signMessage({
    message: { raw: params.userOpHash },
  })) as Hex;

  // CallPolicy is policy index 0, IntentPolicy is policy index 1.
  // CallPolicy is signature-less: omit index 0.
  return packPolicyAndSignerSigs({
    policySigs: [{ index: 1, sig: intentEnvelope }],
    signerSig,
  });
}

export async function buildEnableSignature(params: {
  env: TestEnv;
  sender: Address; // EOA address
  // The already-constructed UserOp (with signature empty) so we can compute userOpHash.
  userOp: any;
  permissionId32: Hex;
  // policy aggregation for the op being enabled
  intentChecks: Check[];
  intentNonce: bigint;
  intentDeadline: bigint;
  selectorData?: Hex;
}): Promise<{ signature: Hex; nonce: bigint }> {
  const { env, sender } = params;
  const permissionId4 = permissionId32ToPermissionId4(params.permissionId32);

  // Enable installs permission validation (vType=PERMISSION, mode=ENABLE).
  const enableMode = 0x01;
  const vTypePermission = 0x02;

  const vIdWithoutType = padHex(
    concatHex([permissionId4, `0x${"00".repeat(16)}`]),
    { size: 20 },
  );
  const nonceKey = encodeNonceKey({
    mode: enableMode,
    vType: vTypePermission,
    vIdWithoutType,
    parallelKey: 0,
  });

  // nonce = entrypoint.getNonce(sender, nonceKey)
  const { createPublicClient, http } = await import("viem");
  const publicClient = createPublicClient({ transport: http(env.rpcUrl) });
  const nonce = (await publicClient.readContract({
    address: env.entryPoint as Address,
    abi: EntryPointV07ABI,
    functionName: "getNonce",
    args: [sender, nonceKey],
  })) as bigint;

  // Fill nonce into userOp.
  const op = { ...params.userOp, nonce };

  // Compute userOpHash (EntryPoint does the canonical hashing).
  const userOpHash = (await publicClient.readContract({
    address: env.entryPoint as Address,
    abi: EntryPointV07ABI,
    functionName: "getUserOpHash",
    args: [op],
  })) as Hex;

  // Build the permission signature that will be used after enable installs the permission.
  const permissionUserOpSig = await buildPermissionUserOpSig({
    env,
    sender,
    userOpHash,
    kernelCallData: op.callData,
    intentChecks: params.intentChecks,
    intentNonce: params.intentNonce,
    intentDeadline: params.intentDeadline,
  });

  // Enable payload pieces
  const hook = "0x0000000000000000000000000000000000000000" as Address;
  const hookData = "0xff" as Hex; // kernel tests prefix hookData with 0xff
  const selectorData =
    params.selectorData ??
    (getFunctionSelector(
      getAbiItem({ abi: KernelExecuteABI, name: "execute" }) as any,
    ) as Hex);

  const validatorData = encodePermissionEnableData({
    env,
    permissionId32: params.permissionId32,
  });

  // Sign Enable typed data with the EOA (root validator in 7702 mode).
  // Mirrors Kernel’s Enable type hash:
  // "Enable(bytes21 validationId,uint32 nonce,address hook,bytes validatorData,bytes hookData,bytes selectorData)"
  const enableTypedSig = (await env.owner.signTypedData({
    domain: {
      name: "Kernel",
      version: "0.3.3",
      chainId: Number(env.chainId),
      verifyingContract: sender,
    },
    types: {
      Enable: [
        { name: "validationId", type: "bytes21" },
        { name: "nonce", type: "uint32" },
        { name: "hook", type: "address" },
        { name: "validatorData", type: "bytes" },
        { name: "hookData", type: "bytes" },
        { name: "selectorData", type: "bytes" },
      ],
    },
    primaryType: "Enable",
    message: {
      validationId: permissionValidationId(permissionId4),
      nonce: 1, // fresh install; Kernel7702TestBase increments from 0 -> 1 on first enable
      hook,
      validatorData,
      hookData,
      selectorData,
    },
  })) as Hex;

  // Final enable signature layout (matches Kernel7702TestBase.encodeEnableSignature):
  // abi.encodePacked(hook, abi.encode(validatorData, hookData, selectorData, enableSig, userOpSig))
  const encodedTail = encodeAbiParameters(
    [{ type: "bytes" }, { type: "bytes" }, { type: "bytes" }, { type: "bytes" }, { type: "bytes" }],
    [validatorData, hookData, selectorData, enableTypedSig, permissionUserOpSig],
  ) as Hex;

  return { signature: concatHex([hook, encodedTail]), nonce };
}

export async function buildKernelUserOpForTarget(params: {
  env: TestEnv;
  sender: Address;
  target: Address;
  data: Hex;
  // policy aggregation
  intentChecks: Check[];
  intentNonce: bigint;
  intentDeadline: bigint;
  // whether to use enable mode (first run)
  enablePermission: boolean;
}): Promise<{ userOp: any }> {
  const { env, sender, target, data } = params;

  const kernelCallData = encodeKernelExecuteSingle({
    to: target,
    value: 0n,
    data,
  });

  // Root nonce key (0) is used when validation type is ROOT/7702; enable uses a different nonce key.
  const { createPublicClient, http } = await import("viem");
  const publicClient = createPublicClient({ transport: http(env.rpcUrl) });

  const nonce =
    params.enablePermission
      ? 0n // filled later in enable helper
      : ((await publicClient.readContract({
          address: env.entryPoint as Address,
          abi: EntryPointV07ABI,
          functionName: "getNonce",
          args: [sender, 0n],
        })) as bigint);

  const baseUserOp = {
    sender,
    nonce,
    initCode: "0x",
    callData: kernelCallData,
    accountGasLimits: `0x${"00".repeat(16)}${"00".repeat(16)}` as Hex,
    preVerificationGas: 150_000n,
    gasFees: `0x${"00".repeat(16)}${"00".repeat(16)}` as Hex,
    paymasterAndData: "0x",
    signature: "0x" as Hex,
  } as const;

  if (!params.enablePermission) {
    // Permission already installed: sign with permission pipeline (policies + signer).
    const userOpHash = (await publicClient.readContract({
      address: env.entryPoint as Address,
      abi: EntryPointV07ABI,
      functionName: "getUserOpHash",
      args: [baseUserOp],
    })) as Hex;

    const sig = await buildPermissionUserOpSig({
      env,
      sender,
      userOpHash,
      kernelCallData,
      intentChecks: params.intentChecks,
      intentNonce: params.intentNonce,
      intentDeadline: params.intentDeadline,
    });

    return { userOp: { ...baseUserOp, signature: sig } };
  }

  // Enable permission (first run): build enable signature (includes permission signature for the op).
  const enableSig = await buildEnableSignature({
    env,
    sender,
    userOp: baseUserOp,
    permissionId32: env.permissionId,
    intentChecks: params.intentChecks,
    intentNonce: params.intentNonce,
    intentDeadline: params.intentDeadline,
    selectorData: concatHex([
      getFunctionSelector(getAbiItem({ abi: KernelExecuteABI, name: "execute" }) as any) as Hex,
    ]),
  });

  return { userOp: { ...baseUserOp, nonce: enableSig.nonce, signature: enableSig.signature } };
}

export async function signKernelDelegationAuthorization(params: {
  env: TestEnv;
  walletClient: any;
}): Promise<any> {
  const { env, walletClient } = params;

  // Prefer viem's prepare/sign helpers if present (handles correct authorisation nonce).
  if (typeof walletClient.prepareAuthorization === "function" && typeof walletClient.signAuthorization === "function") {
    const request = await walletClient.prepareAuthorization({
      contractAddress: env.kernelImplementation as Address,
    });
    return await walletClient.signAuthorization(request);
  }

  // Fallback: sign with nonce=0 (works for fresh devnets).
  const anyOwner = env.owner as any;
  if (typeof anyOwner.signAuthorization === "function") {
    return await anyOwner.signAuthorization({
      chainId: Number(env.chainId),
      nonce: 0,
      address: env.kernelImplementation as Address,
    });
  }

  throw new Error("No viem EIP-7702 authorisation signing available");
}

